import AppKit
import SwiftUI
import AutoSwitchCore

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(store: AppStore, section: SettingsSection = .general) {
        let hosting = NSHostingController(rootView: SettingsRootView(section: section).environment(store))
        window = NSWindow(contentViewController: hosting)
        window.title = "Claude AutoSwitch"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 560))
        window.minSize = NSSize(width: 660, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int { window.windowNumber }
}

struct SettingsRootView: View {
    @Environment(AppStore.self) private var store
    @State private var section: SettingsSection

    init(section: SettingsSection = .general) { _section = State(initialValue: section) }

    var body: some View {
        // Reading the language here re-renders the whole window on a change: every label is an `L()` call.
        let _ = store.prefs.language
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { s in
                Label(s.title, systemImage: icon(s)).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 220)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title).font(.title2.bold())
                        if let err = store.configError {
                            Banner(kind: .bad, text: L("Config could not be read: %@", err))
                        }
                        if store.isDown {
                            Banner(kind: .warn, text: L("The listener is down — edits are saved and apply as soon as it starts."))
                        }
                        pane
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .task { await store.loadConfiguration() }
    }

    private func icon(_ s: SettingsSection) -> String {
        switch s {
        case .general: return "gearshape"
        case .proxy: return "server.rack"
        case .accounts: return "person.2"
        case .rotation: return "arrow.triangle.2.circlepath"
        case .quota: return "gauge.with.dots.needle.33percent"
        case .history: return "clock.arrow.circlepath"
        case .advanced: return "slider.horizontal.3"
        }
    }

    @ViewBuilder
    // `.id` remakes the pane on a language change, so panes that read nothing else from the store still relabel.
    private var pane: some View { SettingsPaneOnly(section: section).id(store.prefs.language) }
}

/// One pane without the split view chrome (also what the snapshot mode renders).
struct SettingsPaneOnly: View {
    @Environment(AppStore.self) private var store
    let section: SettingsSection

    var body: some View {
        switch section {
        case .general: GeneralPane()
        case .proxy: ProxyPane()
        case .accounts: AccountsPane()
        case .rotation: RotationPane()
        case .quota: QuotaPane()
        case .history: HistoryPane()
        case .advanced: AdvancedPane()
        }
    }
}


// MARK: - General (app preferences)

struct GeneralPane: View {
    @Environment(AppStore.self) private var store
    @State private var launchAtLogin = false
    @State private var levelsText = "90, 95"
    @State private var notificationsBlocked = false

    var body: some View {
        @Bindable var prefs = store.prefs
        VStack(alignment: .leading, spacing: 14) {
            TitledGroup(title: L("Startup")) {
                Toggle(L("Launch at login"), isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
                if Bundle.main.bundleIdentifier == nil { Text(L("Available from the app bundle (make app), not from swift run.")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            TitledGroup(title: L("Language")) {
                Picker(L("Language"), selection: Binding(get: { prefs.language ?? "" }, set: { prefs.language = $0.isEmpty ? nil : $0 })) {
                    Text(L("System (%@)", L10n.supported.first { $0.code == L10n.systemDefault() }?.name ?? "English")).tag("")
                    Divider()
                    ForEach(L10n.supported) { Text($0.name).tag($0.code) }
                }.frame(maxWidth: 300)
                if L10n.translationMissing, let missing = L10n.supported.first(where: { $0.code == prefs.language }) {
                    Text(L("The translation for %@ is not in this build; showing English.", missing.name)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            TitledGroup(title: L("Menu bar")) {
                Picker(L("Style"), selection: $prefs.iconStyle) {
                    Text(L("Bars + %")).tag(Preferences.IconStyle.barsPercent)
                    Text(L("Bars only")).tag(Preferences.IconStyle.bars)
                    Text(L("% only")).tag(Preferences.IconStyle.percent)
                    Text(L("Bars + 5h · 7d")).tag(Preferences.IconStyle.barsBoth)
                    Text(L("Quiet (text only when warning)")).tag(Preferences.IconStyle.quiet)
                }.frame(maxWidth: 360)
                Toggle(L("Show the current account instead of the fleet (its three-letter tag leads the title)"), isOn: $prefs.pinCurrent)
                Toggle(L("Show remaining instead of used"), isOn: $prefs.showRemaining)
                Toggle(L("Monochrome (follows the menu bar)"), isOn: $prefs.monochrome)
                Text(L("The icon turns orange when a bar runs ahead of its window (the same rule that colours the bars) and red at the switch threshold or when nothing can serve.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TitledGroup(title: L("Refresh")) {
                Picker(L("Refresh (popover open / closed)"), selection: $prefs.refresh) {
                    ForEach(Preferences.Refresh.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 420)
                Picker(L("Reset display"), selection: $prefs.resetStyle) { Text(L("Countdown")).tag(Format.ResetStyle.countdown); Text(L("Clock")).tag(Format.ResetStyle.clock); Text(L("Both")).tag(Format.ResetStyle.both) }.frame(maxWidth: 300)
                Toggle(L("Hide account e-mails (show short tags)"), isOn: $prefs.hidePII)
                Text(L("Polling slows to every 5 minutes while the display is off or the session is locked, and halves in Low Power Mode.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TitledGroup(title: L("Shortcuts")) {
                Toggle("\(HotKeyCenter.Key.nextAccount.title)  " + L("Switch to the next available account"), isOn: $prefs.hotkeyNextAccount)
                Toggle("\(HotKeyCenter.Key.togglePopover.title)  " + L("Show or hide the popover"), isOn: $prefs.hotkeyTogglePopover)
                let taken = HotKeyCenter.shared.unavailable.map(\.title).sorted()
                if !taken.isEmpty {
                    Banner(kind: .warn, text: L("%@ is already taken by another app, so it does nothing here. Free it there, then switch this off and on again.", taken.joined(separator: ", ")))
                }
                Text(L("Global — they work from any app. No Accessibility permission is needed.")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TitledGroup(title: L("Notifications")) {
                if notificationsBlocked {
                    Banner(kind: .warn, text: L("Notifications are turned off for this app in System Settings, so none of these arrive."),
                           action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!) },
                           actionTitle: L("Open System Settings"))
                }
                Toggle(L("Fleet 5-hour thresholds"), isOn: $prefs.alertPrefs.fleetFiveHour)
                Toggle(L("Fleet weekly thresholds"), isOn: $prefs.alertPrefs.fleetWeekly)
                HStack {
                    Text(L("Levels (%)"))
                    TextField(L("Levels"), text: $levelsText, prompt: Text("90, 95")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 120).onSubmit(commitLevels)
                    if levelsText != prefs.alertPrefs.levels.map(String.init).joined(separator: ", ") {
                        Button(L("Apply"), action: commitLevels).controlSize(.small)
                    }
                }
                Toggle(L("Rotation (the account carrying requests changed, with the reason)"), isOn: $prefs.alertPrefs.rotation)
                Toggle(L("An account left rotation (threshold, 429 hold, cap)"), isOn: $prefs.alertPrefs.accountLeft)
                Toggle(L("An account is back in rotation (window reset, hold cleared)"), isOn: $prefs.alertPrefs.accountBack)
                Toggle(L("Account needs a re-login"), isOn: $prefs.alertPrefs.accountError)
                Toggle(L("Quota probe failing for an account"), isOn: $prefs.alertPrefs.probeFailed)
                Toggle(L("No account can serve (hold)"), isOn: $prefs.alertPrefs.hold)
                Toggle(L("Proxy not responding"), isOn: $prefs.alertPrefs.proxyDown)
                Toggle(L("Proxy is back"), isOn: $prefs.alertPrefs.proxyBack)
                Toggle(L("Overage billing started"), isOn: $prefs.alertPrefs.spend)
                HStack {
                    if let until = prefs.alertPrefs.pausedUntil, until > Date() {
                        Text(L("Paused until %@", Format.localizedDate(until, date: .omitted, time: .shortened))).foregroundStyle(.secondary)
                        Button(L("Resume")) { prefs.alertPrefs.pausedUntil = nil }
                    } else {
                        Button(L("Pause for 1 hour")) { prefs.alertPrefs.pausedUntil = Date().addingTimeInterval(3600) }
                    }
                }
            }
            TitledGroup(title: L("About")) {
                Text("Claude AutoSwitch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(dev)") · MIT").font(.system(size: 12)).foregroundStyle(.secondary)
                Link(L("%@ on GitHub", "ParkSangGwon/claude-account-autoswitch"), destination: URL(string: "https://github.com/ParkSangGwon/claude-account-autoswitch")!).font(.system(size: 12))
            }
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            levelsText = store.prefs.alertPrefs.levels.map(String.init).joined(separator: ", ")
        }
        // Permission can be revoked in System Settings while the app runs, so read it on the way in.
        .task { notificationsBlocked = await Notifier.shared.isBlocked() }
    }

    private func commitLevels() {
        let levels = levelsText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...100).contains($0) }.sorted()
        guard !levels.isEmpty else {
            // Nothing usable in the field: saying so beats leaving text that was never saved.
            store.showToast(.error, L("Levels are whole percents between 1 and 100, separated by commas."))
            levelsText = store.prefs.alertPrefs.levels.map(String.init).joined(separator: ", ")
            return
        }
        store.prefs.alertPrefs.levels = levels
    }
}

import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return SMAppService.mainApp.status == .enabled
    }
    static func set(_ on: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[ClaudeAutoSwitch] launch at login: %@", error.localizedDescription)
        }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @Environment(AppStore.self) private var store
    @State private var editingRaw = false
    @State private var exportedTo: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Config file")).font(.system(size: 13, weight: .semibold))
                HStack {
                    Text(store.configStore.path.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button(L("Reveal")) { NSWorkspace.shared.activateFileViewerSelecting([store.configStore.path]) }.controlSize(.small)
                    Button(L("Reload from disk")) { Task { await store.reloadConfig() } }.controlSize(.small)
                    Button(L("Edit as JSON…")) { editingRaw = true }.controlSize(.small).disabled(store.configuration == nil)
                }
                if store.configuration == nil {
                    Text(L("The editor stays closed while the file cannot be read: it would open on an empty document, and saving that would replace the accounts the file still holds. Reveal the file, fix it in a text editor, then reload.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L("Hand-editable JSON. The editor shows secrets as %@ and puts them back on save; the file is written atomically with 0600 permissions and applied at once.", Redaction.placeholder)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .sheet(isPresented: $editingRaw) { RawConfigEditor { editingRaw = false } }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Diagnostics")).font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(L("Export diagnostics…")) { Task { exportedTo = await store.exportDiagnostics() } }.controlSize(.small)
                    if let exportedTo { Button(L("Reveal")) { NSWorkspace.shared.activateFileViewerSelecting([exportedTo]) }.controlSize(.small) }
                }
                Text(L("Writes the engine's state, the config with every secret replaced and the app's state to a folder in Downloads — what a bug report needs, without tokens.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Environment variables")).font(.system(size: 13, weight: .semibold))
                Text(L("CLAUDE_AUTOSWITCH_CONFIG moves the config file (set it before launching the app). Nothing else is read from the environment."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Rotation (schema + the rotation log)

struct RotationPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SchemaPane(section: .rotation)
            RotationLogView()
        }
    }
}

/// Every switch the app saw, newest first, with the engine's reason.
struct RotationLogView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let events = store.prefs.journal.latest
        TitledGroup(title: L("Rotation log")) {
            if events.isEmpty {
                Text(L("No rotation observed yet. Entries are recorded while the app runs (the proxy itself keeps no history).")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(L("%d in the last 24 h · %d kept", store.prefs.journal.count(within: 86400), events.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(events) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Format.localizedDate(e.at, date: .abbreviated, time: .shortened)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text("\(e.from.map(store.displayName) ?? "—") → \(store.displayName(e.to))").font(.system(size: 12, weight: e.manual ? .regular : .medium))
                        if e.manual { Chip(text: L("manual")) }
                        Text(e.reasonText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                Button(L("Clear log")) { store.prefs.journal = Journal() }.controlSize(.small)
            }
        }
    }
}

// MARK: - Logging (schema + who consumed what)

struct RawConfigEditor: View {
    @Environment(AppStore.self) private var store
    var dismiss: () -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false
    @State private var disk: Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Edit %@", store.configStore.path.lastPathComponent)).font(.headline)
            Text(L("Secrets show as %@; leave them and they are kept. The proxy applies the document after the save.", Redaction.placeholder)).font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(minWidth: 640, minHeight: 420)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
            HStack {
                Spacer()
                Button(L("Cancel"), action: dismiss)
                Button(saving ? L("Saving…") : L("Save")) { save() }.keyboardShortcut(.defaultAction).disabled(saving || disk == nil)
            }
        }
        .padding(20)
        .onAppear(perform: load)
    }

    private func load() {
        guard let c = store.configuration else { error = L("Could not read the config: %@", store.configError ?? "-"); return }
        disk = c
        if let data = try? Configuration.encoder().encode(Redaction.redact(c)) { text = String(decoding: data, as: UTF8.self) }
    }

    private func save() {
        guard let disk else { return }
        let parsed: Configuration
        do { parsed = try Configuration.decoder().decode(Configuration.self, from: Data(text.utf8)) } catch { self.error = L("Not valid JSON: %@", String(describing: error)); return }
        let restored = Redaction.restore(parsed, from: disk)
        saving = true
        error = nil
        Task {
            let ok = await store.replaceConfiguration(restored)
            saving = false
            if ok { dismiss() } else { error = L("The proxy did not reload the new config; see the message above.") }
        }
    }
}
