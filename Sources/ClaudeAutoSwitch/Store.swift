import AppKit
import Observation
import AutoSwitchCore
import AutoSwitchEngine

enum Connection: Equatable {
    case starting
    case up
    case down(since: Date, error: EngineError)
}

struct Toast: Equatable {
    enum Kind { case ok, warn, error, info }
    var kind: Kind
    var text: String
    var at: Date
}

enum RankValue: Sendable, Equatable {
    case number(Int)
    case first
    case last
}

/// Single source of truth for the UI: reads the in-process engine, keeps the last state,
/// runs the alert engine, and exposes the actions the views call.
@MainActor
@Observable
final class AppStore {
    private(set) var state: EngineState?
    private(set) var previousState: EngineState?
    private(set) var connection: Connection = .starting
    private(set) var lastSuccessAt: Date?
    private(set) var endpoint: ProxyEndpoint
    let configStore: ConfigStore
    private(set) var rotatedAt: Date?
    private(set) var rotatedTo: String?
    /// The configuration as the engine holds it, for the settings screens.
    private(set) var configuration: Configuration?
    private(set) var configError: String?
    var toast: Toast?
    /// The loop switches to the fast cadence at once, not when the closed-interval sleep ends.
    var popoverOpen = false { didSet { if popoverOpen != oldValue { rescheduleLoop() } } }
    private(set) var failureStreak = 0
    /// Display names that stay unique per account (see `Explain.aliases`).
    private(set) var aliases: [String: String] = [:]
    private(set) var history = HistoryStore()
    /// The file on disk has been read. Until it has, `history` is empty because nothing was loaded,
    /// not because there is nothing — writing it then would throw away every past sample.
    private var historyLoaded = false
    /// The display is asleep or the session is locked: nobody is looking, poll rarely.
    private(set) var displayAsleep = false

    let prefs = Preferences.shared
    let engine: Engine
    private var pollTask: Task<Void, Never>?
    private var pollInFlight = false
    private var pollAgain = false
    private var appSwitchedTo: (id: AccountID, at: Date)?
    private var alertState: AlertState
    private var observers: [any NSObjectProtocol] = []
    private var historySavedAt = Date()

    nonisolated static let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Claude AutoSwitch/history.json")

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev" }

    init() {
        let store = ConfigStore(path: ConfigStore.resolvePath())
        configStore = store
        endpoint = ProxyEndpoint()
        engine = Engine(store: store, version: AppStore.appVersion)
        alertState = Preferences.shared.alertState
        Task.detached { [url = AppStore.historyURL] in
            let loaded = HistoryStore.load(from: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.history.samples.isEmpty { self.history = loaded }
                self.historyLoaded = true
            }
        }
    }

    // MARK: - lifecycle

    func start() {
        Task { await startEngine() }
        rescheduleLoop(pollNow: true)
        guard observers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        })
        // Display off or session locked: stretch the cadence; back on: poll now.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.displayAsleep = true; self?.rescheduleLoop() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.displayAsleep = false; self?.rescheduleLoop(pollNow: true) }
            })
        }
    }

    /// Quitting: the engine writes what it learned and the listener closes, and both have to finish
    /// before the process goes. `NSApplication` waits for this through `applicationShouldTerminate`.
    /// The main-actor half of quitting, done synchronously so nothing is left in flight. The engine's
    /// own shutdown is awaited off this actor — see `applicationShouldTerminate`.
    func prepareForQuit() {
        pollTask?.cancel()
        guard historyLoaded else { return }
        historySavedAt = Date()
        try? history.save(to: AppStore.historyURL)
    }

    /// Load the config and bind the listener; a failure (typically the port) is the "down" state the UI shows.
    func startEngine() async {
        do {
            try await engine.start()
            endpoint = ProxyEndpoint(port: await engine.port)
            connection = .up
            failureStreak = 0
            await loadConfiguration()
            await poll()
        } catch let e as EngineError {
            NSLog("[ClaudeAutoSwitch] engine start failed: %@", e.message)
            endpoint = ProxyEndpoint(port: await engine.port)
            connection = .down(since: Date(), error: e)
        } catch let e as ConfigError {
            NSLog("[ClaudeAutoSwitch] engine start failed: %@", e.message)
            endpoint = ProxyEndpoint(port: await engine.port)
            connection = .down(since: Date(), error: .config(e.message))
            configError = e.message
        } catch {
            NSLog("[ClaudeAutoSwitch] engine start failed: %@", String(describing: error))
            endpoint = ProxyEndpoint(port: await engine.port)
            connection = .down(since: Date(), error: .listen(error.localizedDescription))
        }
    }

    func checkForUpdate() async {
        prefs.updateCheckedAt = Date()
        guard let latest = await UpdateCheck.latestVersion() else { return }
        prefs.latestSeenVersion = latest
    }

    /// Once a day is often enough for a release feed, and it costs one request.
    func checkForUpdateIfDue() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        if let last = prefs.updateCheckedAt, Date().timeIntervalSince(last) < 86_400 { return }
        await checkForUpdate()
    }

    /// The port is taken: move to one that is not, and say where it went.
    func moveToFreePort() async {
        do {
            let port = try await engine.moveToFreePort()
            endpoint = ProxyEndpoint(port: port)
            connection = .up
            failureStreak = 0
            await loadConfiguration()
            await poll()
            showToast(.ok, L("Now listening on port %d — update the line Claude Code uses.", port))
        } catch let e as EngineError {
            showToast(.error, e.message)
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    /// Who holds the configured port, when something does.
    var portHeldBy: String? {
        guard case .down(_, let error) = connection, case .portInUse(let port) = error else { return nil }
        return Actions.processHolding(port: port)
    }

    /// Listening, accounts configured, and not one request has arrived. Almost always the shell
    /// never got `ANTHROPIC_BASE_URL`, which the app cannot see and so has to ask about.
    var nothingHasArrivedYet: Bool {
        guard let s = state, s.listener.isRunning, let since = s.listener.startedAt, !s.accounts.isEmpty else { return false }
        guard s.sessions.isEmpty, s.accounts.allSatisfy({ $0.traffic.requests == 0 }) else { return false }
        return Date().timeIntervalSince(since) > 300
    }

    /// Bind again after a port change or a failed start.
    func restartEngine() async {
        await engine.stop()
        await startEngine()
    }

    /// The one line a shell needs so Claude Code talks to this proxy.
    var claudeCodeEnvLine: String { "export ANTHROPIC_BASE_URL=\(endpoint.baseURLString)" }

    /// Restart the loop so the next sleep uses the current cadence; `pollNow` also polls first.
    private func rescheduleLoop(pollNow: Bool = false) {
        guard pollTask != nil || pollNow else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var skipPoll = !pollNow
            while !Task.isCancelled {
                guard let self else { return }
                if !skipPoll { await self.poll() }
                skipPoll = false
                let delay = self.nextDelay()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func nextDelay() -> TimeInterval {
        if case .down = connection { return 10 }
        if popoverOpen { return prefs.pollOpen }
        if displayAsleep { return 300 }
        // Low Power Mode or a hot machine: half as often.
        let info = ProcessInfo.processInfo
        let eased = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        return eased ? prefs.pollClosed * 2 : prefs.pollClosed
    }

    // MARK: - polling

    /// One poll at a time: a second request while one is in flight runs once more
    /// afterwards, so a slow earlier reply can never land on top of a newer one.
    func poll() async {
        if pollInFlight { pollAgain = true; return }
        pollInFlight = true
        defer { pollInFlight = false }
        repeat {
            pollAgain = false
            await pollOnce()
        } while pollAgain
    }

    private func pollOnce() async {
        guard await engine.isRunning else {
            failureStreak += 1
            if case .down = connection {} else { connection = .down(since: Date(), error: await engine.lastError ?? .listen("stopped")) }
            evaluateAlerts()
            return
        }
        apply(await engine.state())
        // Until the first quota probe lands the engine only knows what the config says, so its choice
        // of account is provisional: a switch seen now is start-up noise, not a rotation.
        if !warmingUp { evaluateAlerts(); recordHistory() }
    }

    private var warmingUp: Bool {
        guard let state else { return false }
        return state.probe.enabled && state.probe.lastFinishedAt == nil
    }

    private func apply(_ s: EngineState) {
        previousState = state
        state = s
        failureStreak = 0
        lastSuccessAt = Date()
        let wasDown = { if case .down = connection { return true } else { return false } }()
        connection = .up
        if wasDown { showToast(.ok, L("Proxy is back")) }
        aliases = Explain.aliases(for: s.accounts.map { (label: $0.label, org: $0.organization?.name) })
        // The same ten-second window the alert engine uses for "the app did this itself".
        let justSwitchedTo = appSwitchedTo.flatMap { Date().timeIntervalSince($0.at) < 10 ? $0.id : nil }
        let previousWasProvisional = previousState.map { $0.probe.enabled && $0.probe.lastFinishedAt == nil } ?? true
        if let prev = previousState?.next, let cur = s.next, prev != cur, !previousWasProvisional {
            let manual = justSwitchedTo == cur
            let from = s.label(prev) ?? previousState?.label(prev) ?? prev.rawValue
            let to = s.label(cur) ?? cur.rawValue
            if !manual {
                rotatedAt = Date()
                rotatedTo = to
            }
            let cause: SwitchCause = manual ? .manual : (Explain.switchCause(from: prev, to: cur, state: s, previous: previousState) ?? .moved)
            prefs.journal.append(SwitchEvent(at: Date(), from: from, to: to, cause: cause))
        }
    }

    private func evaluateAlerts() {
        let inputs = AlertInputs(previous: previousState, state: state, reachable: !isDown,
                                 appSwitchedTo: appSwitchedTo.flatMap { Date().timeIntervalSince($0.at) < 10 ? $0.id : nil })
        let (alerts, newState) = AlertEngine.evaluate(inputs, state: alertState, prefs: prefs.alertPrefs)
        // Persisting is a plist rewrite through cfprefsd; every poll for weeks adds up, so only on change.
        if newState != alertState {
            alertState = newState
            prefs.alertState = newState
        }
        for a in alerts { Notifier.shared.post(maskingNames(in: a)) }
    }

    /// "Hide account e-mails" applies to notifications too: they sit on the lock screen and in Notification Center history.
    private func maskingNames(in alert: Alert) -> Alert {
        guard prefs.hidePII, let labels = state?.accounts.map(\.label) else { return alert }
        var a = alert
        for label in labels.sorted(by: { $0.count > $1.count }) {
            a.title = a.title.replacingOccurrences(of: label, with: displayName(label))
            a.body = a.body.replacingOccurrences(of: label, with: displayName(label))
        }
        return a
    }

    private func recordHistory() {
        guard let state else { return }
        let now = Date()
        if history.record(HistorySample(state: state, at: now)), now.timeIntervalSince(historySavedAt) > 300 {
            saveHistory()
        }
    }

    private func saveHistory() {
        guard historyLoaded else { return }
        historySavedAt = Date()
        let snapshot = history
        Task.detached { try? snapshot.save(to: AppStore.historyURL) }
    }

    var isDown: Bool { if case .down = connection { return true } else { return false } }

    var iconModel: IconModel {
        MenuBarState.compute(IconInputs(state: state, reachable: !isDown, lastSuccessAt: lastSuccessAt,
                                        pollInterval: popoverOpen ? prefs.pollOpen : prefs.pollClosed, rotatedAt: rotatedAt, rotatedTo: rotatedTo,
                                        pinCurrent: prefs.pinCurrent, showRemaining: prefs.showRemaining))
    }

    // MARK: - actions

    func refreshNow() { Task { await poll() } }

    func switchTo(_ id: AccountID) {
        Task {
            let outcome = await engine.switchTo(id)
            appSwitchedTo = (id, Date())
            showToast(outcome.kind == .ok ? .ok : outcome.kind == .warn ? .warn : .error, outcome.text)
            await poll()
        }
    }

    /// The hotkey: move traffic to the next account in rank order that can serve, wrapping around.
    func switchToNextAvailable() {
        guard let state, !state.accounts.isEmpty else { showToast(.warn, L("No accounts to switch between")); return }
        let ordered = state.byRank
        let start = ordered.firstIndex { $0.id == state.current } ?? -1
        for offset in 1...ordered.count {
            let candidate = ordered[(start + offset) % ordered.count]
            if candidate.blocker == nil, candidate.id != state.current {
                switchTo(candidate.id)
                return
            }
        }
        showToast(.warn, L("No other account can serve right now"))
    }

    /// Re-read the config file (edited by hand or by another tool); the result is what callers report.
    @discardableResult
    func reloadConfig() async -> Bool {
        do {
            let added = try await engine.reloadFromDisk()
            showToast(.ok, added > 0 ? L("Reloaded (+%d new)", added) : L("Reloaded"))
            try? await engine.restartIfPortChanged()
            endpoint = ProxyEndpoint(port: await engine.port)
            await loadConfiguration()
            await poll()
            return true
        } catch let e as ConfigError {
            showToast(.error, L("Reload failed: %@", e.message))
        } catch {
            showToast(.error, L("Reload failed: %@", error.localizedDescription))
        }
        return false
    }

    /// Change the configuration and report through the toast; every change applies live.
    func update(label: String, _ mutate: @escaping @Sendable (inout Configuration) throws -> Void) async {
        do {
            try await engine.update(mutate)
            showToast(.ok, L("%@ applied", label))
            try await engine.restartIfPortChanged()
            endpoint = ProxyEndpoint(port: await engine.port)
            await loadConfiguration()
            await poll()
        } catch let e as EngineError {
            showToast(.error, "\(label): \(e.message)")
        } catch let e as SettingsError {
            showToast(.error, "\(label): \(e.message)")
        } catch let e as ConfigError {
            showToast(.error, "\(label): \(e.message)")
        } catch {
            showToast(.error, "\(label): \(error.localizedDescription)")
        }
    }

    func apply(_ field: SettingField, value: JSON?) async {
        await update(label: L(field.label)) { c in try SettingsCatalog.apply(field, value: value, to: &c) }
    }

    func applyAccountField(_ id: AccountID, _ field: SettingField, value: JSON?) async {
        let label = L("%@ for %@", L(field.label), displayName(labelOf(id)))
        await update(label: label) { c in
            guard let i = c.index(of: id) else { throw SettingsError.noSuchAccount(id.rawValue) }
            try SettingsCatalog.applyAccount(field, value: value, to: &c.accounts[i])
        }
    }

    // Account actions the card and the table share, with one wording each.
    func setRank(_ id: AccountID, _ value: RankValue) async {
        let n: Int
        switch value { case .number(let x): n = x; case .first: n = -1; case .last: n = 100 }
        await update(label: L("Priority of %@", displayName(labelOf(id)))) { c in
            guard let i = c.index(of: id) else { throw SettingsError.noSuchAccount(id.rawValue) }
            c.accounts[i].rank = n
        }
    }

    /// Take an account out of rotation for a while. `nil` puts it back now. Unlike the switch, this
    /// lifts itself, so "save this one for the demo" does not depend on anyone remembering.
    func skip(_ id: AccountID, until: Date?) async {
        let name = displayName(labelOf(id))
        await update(label: until == nil ? L("Resume %@", name) : L("Skip %@", name)) { c in
            guard let i = c.index(of: id) else { throw SettingsError.noSuchAccount(id.rawValue) }
            c.accounts[i].skipUntil = until
        }
    }

    /// When the account's weekly window rolls over, or a week out if it has never reported one.
    func weeklyResetOf(_ id: AccountID) -> Date {
        state?.account(id)?.windows[.weekly]?.resetsAt ?? Date().addingTimeInterval(7 * 24 * 3600)
    }

    func setEnabled(_ id: AccountID, _ enabled: Bool) async {
        let name = displayName(labelOf(id))
        await update(label: enabled ? L("Enable %@", name) : L("Disable %@", name)) { c in
            guard let i = c.index(of: id) else { throw SettingsError.noSuchAccount(id.rawValue) }
            c.accounts[i].enabled = enabled
        }
    }

    func removeAccount(_ id: AccountID) async {
        await update(label: L("Remove %@", displayName(labelOf(id)))) { c in c.accounts.removeAll { $0.id == id } }
    }

    /// Removing takes the credential with it, which is the part that cannot be undone from here.
    static var removeAccountMessage: String { L("The account leaves the config and rotation at once, and its sign-in goes with it — putting it back means signing in again. To take it out of rotation for a while, turn it off or skip it instead.") }

    /// Sign in, paste a code, or import: the engine does the work and reports progress to the sheet.
    func addAccount(_ request: AddAccountRequest, onEvent: @escaping @Sendable (AddAccountEvent) -> Void) async throws {
        let source: AccountSource
        switch request.mode {
        case .oauth: source = .browser
        case .token: source = .pasteCode
        case .apiKey: source = .apiKey(request.secret ?? "")
        case .importCLI: source = .claudeCode
        case .importFile: source = .credentialsFile(request.path)
        }
        try await engine.addAccount(source, label: request.name) { event in
            switch event {
            case .line(let text): onEvent(.line(text))
            case .openURL(let url): onEvent(.openURL(url))
            }
        }
        await loadConfiguration()
        await poll()
    }

    func submitLoginCode(_ code: String) async { await engine.submitLoginCode(code) }

    // MARK: - configuration (settings screens)

    /// The configuration as the engine holds it; the screens update when it lands.
    /// While the file cannot be parsed the engine holds defaults, not the document — publishing
    /// those would show "no accounts" over a file that has them, so the screens get nothing instead.
    func loadConfiguration() async {
        if let failure = await engine.loadFailure {
            configuration = nil
            configError = failure.message
            return
        }
        configuration = await engine.configuration
        configError = nil
    }

    func labelOf(_ id: AccountID) -> String {
        state?.label(id) ?? configuration?.account(id)?.label ?? id.rawValue
    }

    /// Write a whole document (the raw editor): saved and applied at once.
    func replaceConfiguration(_ c: Configuration) async -> Bool {
        do {
            try await engine.replace(c)
            try await engine.restartIfPortChanged()
            endpoint = ProxyEndpoint(port: await engine.port)
            await loadConfiguration()
            await poll()
            return true
        } catch {
            showToast(.error, L("Could not write the config: %@", error.localizedDescription))
            return false
        }
    }

    /// The engine's state, the config with every secret replaced, and the app's own state, in a
    /// folder under Downloads: what a bug report needs and nothing it must not carry.
    func exportDiagnostics() async -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appending(path: "claude-autoswitch-diagnostics-\(stamp)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let state { try Diagnostics.describe(state).write(to: dir.appending(path: "state.txt"), atomically: true, encoding: .utf8) }
            if let configuration {
                let data = try Configuration.encoder().encode(Redaction.redact(configuration))
                try data.write(to: dir.appending(path: "config-redacted.json"))
            }
            var app = ["Claude AutoSwitch \(AppStore.appVersion)"]
            app.append("endpoint \(endpoint.label) · connection \(connection)")
            app.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            try app.joined(separator: "\n").write(to: dir.appending(path: "app.txt"), atomically: true, encoding: .utf8)
            // Why rotation moved is the first question a report raises, and the log is the only record.
            let journal = prefs.journal.latest.map { e in
                "\(ISO8601DateFormatter().string(from: e.at))  \(e.from.map(displayName) ?? "—") → \(displayName(e.to))"
                    + (e.manual ? "  [manual]" : "") + "  \(e.reasonText)"
            }
            try (journal.isEmpty ? "no switches recorded" : journal.joined(separator: "\n"))
                .write(to: dir.appending(path: "rotation-log.txt"), atomically: true, encoding: .utf8)
            showToast(.ok, L("Diagnostics written to Downloads"))
            return dir
        } catch {
            showToast(.error, L("Could not export diagnostics: %@", error.localizedDescription))
            return nil
        }
    }

    func showToast(_ kind: Toast.Kind, _ text: String) {
        toast = Toast(kind: kind, text: text, at: Date())
        let stamp = toast?.at
        Task {
            try? await Task.sleep(for: .seconds(kind == .error ? 12 : 6))
            if toast?.at == stamp { toast = nil }
        }
    }

    // MARK: - names

    /// The label as the user wants it shown: the full label, or a short tag with Hide PII on.
    func displayName(_ label: String) -> String {
        guard prefs.hidePII else { return label }
        return Format.tag(label) + "…"
    }

    /// The local part of an e-mail for tight spots (`alice` for `alice@example.com`), kept unique across accounts.
    func compactName(_ label: String) -> String {
        if prefs.hidePII { return displayName(label) }
        return aliases[label] ?? String(label.split(separator: "@").first ?? Substring(label))
    }
}

/// Everything the raw editor and the diagnostics export must never show.
enum Redaction {
    static let placeholder = "•••"

    static func redact(_ c: Configuration) -> Configuration {
        var out = c
        for i in out.accounts.indices {
            switch out.accounts[i].credential {
            case .oauth(let t): out.accounts[i].credential = .oauth(OAuthTokens(access: placeholder, refresh: t.refresh.map { _ in placeholder }, expiresAt: t.expiresAt))
            case .apiKey: out.accounts[i].credential = .apiKey(placeholder)
            }
        }
        return out
    }

    /// Put the on-disk secrets back where the edited document still carries the placeholder, matching accounts by id, then by label.
    static func restore(_ edited: Configuration, from disk: Configuration) -> Configuration {
        var out = edited
        for i in out.accounts.indices {
            let orig = disk.accounts.first { $0.id == out.accounts[i].id } ?? disk.accounts.first { $0.label == out.accounts[i].label }
            guard let orig else { continue }
            switch (out.accounts[i].credential, orig.credential) {
            case (.oauth(let e), .oauth(let d)):
                out.accounts[i].credential = .oauth(OAuthTokens(access: e.access == placeholder ? d.access : e.access,
                                                                refresh: e.refresh == placeholder ? d.refresh : e.refresh,
                                                                expiresAt: e.expiresAt ?? d.expiresAt))
            case (.apiKey(let e), .apiKey(let d)):
                if e == placeholder { out.accounts[i].credential = .apiKey(d) }
            default:
                break
            }
        }
        return out
    }
}

/// A plain-text account of the engine's state for a bug report.
enum Diagnostics {
    static func describe(_ s: EngineState) -> String {
        var lines: [String] = []
        lines.append("observed \(ISO8601DateFormatter().string(from: s.observedAt))")
        lines.append("listener port \(s.listener.port) · \(s.listener.baseURL) · version \(s.listener.version) · running \(s.listener.isRunning)")
        lines.append("current \(s.label(s.current) ?? "-") · next \(s.label(s.next) ?? "-")")
        lines.append("rotation switchAt \(s.rotation.switchAt) · byWindow \(s.rotation.switchAtByWindow.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")) · spread \(s.rotation.spreadSessions) · wait \(s.rotation.waitWhenExhaustedSeconds)s")
        lines.append("probe enabled \(s.probe.enabled) · every \(s.probe.intervalSeconds)s · last \(s.probe.lastFinishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")
        for a in s.accounts {
            var parts = ["account \(a.label)", a.kind.rawValue, a.plan.badge, "rank \(a.rank)", a.enabled ? "on" : "off", "health \(a.health.rawValue)"]
            if let b = a.blocker { parts.append("blocked: \(b.code)") }
            for kind in WindowKind.allCases { if let r = a.windows[kind] { parts.append("\(kind.rawValue) \(Format.percentInt(r.used))% resets \(r.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")") } }
            parts.append("sessions \(a.activeSessions)/\(a.knownSessions)")
            parts.append("requests \(a.traffic.requests) tokens \(a.traffic.totalTokens)")
            if let p = a.probe { parts.append("probe \(ISO8601DateFormatter().string(from: p.at)) \(p.error ?? "ok")") }
            lines.append(parts.joined(separator: " · "))
        }
        lines.append("sessions known \(s.sessions.count) active \(s.activeSessionCount) starvedMax \(s.starvedMax)")
        return lines.joined(separator: "\n") + "\n"
    }
}
