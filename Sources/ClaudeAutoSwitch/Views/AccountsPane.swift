import SwiftUI
import AppKit
import AutoSwitchCore
import AutoSwitchEngine

struct AccountsPane: View {
    @Environment(AppStore.self) private var store
    @State private var adding: AddAccountMode?
    @State private var expanded: Set<AccountID> = []

    var records: [AccountRecord] { store.configuration?.accounts ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(records.count == 1 ? L("1 account in the config") : L("%d accounts in the config", records.count)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu(L("Add account…")) {
                    Button(L("Claude subscription (browser sign-in)")) { adding = .oauth }
                    Button(L("Claude subscription (paste code)")) { adding = .token }
                    Button(L("Anthropic API key")) { adding = .apiKey }
                    Divider()
                    Button(L("Import from Claude Code")) { adding = .importCLI }
                    Button(L("Import from a credentials file…")) { adding = .importFile }
                }.fixedSize()
            }
            if records.isEmpty {
                Text(L("No accounts yet — add a Claude subscription, an API key, or import the one Claude Code is logged into.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                AccountCard(record: record, live: store.state?.account(record.id), expanded: expanded.contains(record.id),
                            toggle: { if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) } })
            }
            Text(L("Priority: lower is preferred; a strictly lower value preempts a healthy current account. Disabling keeps the entry but takes it out of rotation.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $adding) { mode in AddAccountSheet(mode: mode) { adding = nil } }
    }
}

struct AccountCard: View {
    @Environment(AppStore.self) private var store
    var record: AccountRecord
    var live: AccountStatus?
    var expanded: Bool
    var toggle: () -> Void
    @State private var priorityText = ""
    @State private var confirmRemove = false

    var isCurrent: Bool { live.map { $0.id == store.state?.current } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8)).foregroundStyle(isCurrent ? Color.accentColor : Color.clear)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayName(record.label)).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text([record.organization?.name, record.kind == .apiKey ? L("API key") : L("subscription")].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Chip(text: record.plan.badge)
                if let live {
                    Chip(text: healthText(live), color: healthColor(live))
                    if let b = live.blocker, b != .switchedOff { Chip(text: b.text, color: .yellow) }
                } else if !record.enabled {
                    Chip(text: L("disabled"), color: .secondary)
                } else {
                    Chip(text: L("not loaded"), color: .secondary)
                }
                Spacer()
                if !isCurrent, live != nil { Button(L("Make current")) { store.switchTo(record.id) }.controlSize(.small) }
                Button(expanded ? L("Less") : L("More")) { toggle() }.controlSize(.small)
            }
            HStack(spacing: 12) {
                Toggle(L("On"), isOn: Binding(get: { record.enabled }, set: { on in Task { await store.setEnabled(record.id, on) } })).toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 4) {
                    Text(L("Priority")).font(.system(size: 12)).fixedSize()
                    TextField(L("Priority"), text: $priorityText).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 50).multilineTextAlignment(.trailing).onSubmit(applyPriority)
                    Button(L("Top")) { Task { await store.setRank(record.id, .first) } }.controlSize(.mini).fixedSize()
                    Button(L("Bottom")) { Task { await store.setRank(record.id, .last) } }.controlSize(.mini).fixedSize()
                }
                if let live {
                    Text(live.activeSessions == 1 ? L("1 session · %d requests", live.traffic.requests) : L("%d sessions · %d requests", live.activeSessions, live.traffic.requests))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(L("Remove…")) { confirmRemove = true }.controlSize(.small)
            }
            if expanded {
                Divider()
                ForEach(SettingsCatalog.accountFields) { field in
                    FieldRow(field: field, value: SettingsCatalog.accountValue(field, in: record) ?? .null) { new in
                        Task { await store.applyAccountField(record.id, field, value: new) }
                    }
                }
                if let uuid = record.claudeAccountID {
                    Text("account \(uuid)" + (record.organization?.id.map { " · org \($0)" } ?? "")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { priorityText = String(record.rank) }
        .onChange(of: record.rank) { _, v in priorityText = String(v) }
        .confirmationDialog(L("Remove %@?", store.displayName(record.label)), isPresented: $confirmRemove) {
            Button(L("Remove"), role: .destructive) { Task { await store.removeAccount(record.id) } }
        } message: { Text(AppStore.removeAccountMessage) }
    }

    private func healthText(_ a: AccountStatus) -> String {
        if !a.enabled { return L("disabled") }
        switch a.health {
        case .ok: return L("active")
        case .coolingDown: return L("cooling down")
        case .drained: return L("spent")
        case .needsLogin: return L("needs sign-in")
        }
    }

    private func healthColor(_ a: AccountStatus) -> Color {
        if !a.enabled { return .secondary }
        switch a.health {
        case .ok: return .green
        case .coolingDown: return .yellow
        case .drained, .needsLogin: return .red
        }
    }

    private func applyPriority() {
        guard let n = Int(priorityText.trimmingCharacters(in: .whitespaces)) else { return }
        Task { await store.setRank(record.id, .number(n)) }
    }
}

// MARK: - Add account

enum AddAccountMode: String, Identifiable {
    case oauth, token, apiKey, importCLI, importFile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .oauth: return L("Claude subscription — browser sign-in")
        case .token: return L("Claude subscription — paste the code")
        case .apiKey: return L("Anthropic API key")
        case .importCLI: return L("Import from Claude Code")
        case .importFile: return L("Import from a credentials file")
        }
    }
    var help: String {
        switch self {
        case .oauth: return L("Opens your browser for the same sign-in Claude Code uses; the app waits up to two minutes for the callback.")
        case .token: return L("For when the browser cannot reach this Mac: sign in on the page that opens, then paste the code it shows (or the full URL) here.")
        case .apiKey: return L("A Console API key (billed per token). It is stored in the config file with the same 0600 permissions as the tokens.")
        case .importCLI: return L("Copies the credentials Claude Code is logged in with (macOS may show a Keychain prompt owned by `security`).")
        case .importFile: return L("Reads accessToken/refreshToken from a credentials JSON file.")
        }
    }
}

struct AddAccountSheet: View {
    @Environment(AppStore.self) private var store
    let mode: AddAccountMode
    var dismiss: () -> Void
    @State private var name = ""
    @State private var secret = ""
    @State private var code = ""
    @State private var path = "~/.claude/.credentials.json"
    @State private var lines: [String] = []
    @State private var running = false
    @State private var finished = false
    @State private var task: Task<Void, Never>?
    @State private var errorText: String?
    @State private var loginURL: URL?
    @State private var codeSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title).font(.headline)
            Text(mode.help).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Text(L("Name")).frame(width: 70, alignment: .trailing); TextField(L("optional — defaults to the account e-mail"), text: $name).textFieldStyle(.roundedBorder) }
            if mode == .apiKey { HStack { Text(L("API key")).frame(width: 70, alignment: .trailing); SecureField("sk-ant-api03-…", text: $secret).textFieldStyle(.roundedBorder) } }
            if mode == .importFile { HStack { Text(L("File")).frame(width: 70, alignment: .trailing); TextField("~/.claude/.credentials.json", text: $path).textFieldStyle(.roundedBorder) } }
            if mode == .token, running, !codeSent {
                HStack {
                    Text(L("Code")).frame(width: 70, alignment: .trailing)
                    TextField(L("authorization code or callback URL"), text: $code).textFieldStyle(.roundedBorder).onSubmit(sendCode)
                    Button(L("Send"), action: sendCode).controlSize(.small).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let loginURL {
                HStack { Text(loginURL.absoluteString).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled); Button(L("Open")) { NSWorkspace.shared.open(loginURL) }.controlSize(.mini) }
            }
            if !lines.isEmpty || running {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(height: 140).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: lines.count) { _, n in proxy.scrollTo(max(0, n - 1)) }
                }
            }
            if let errorText { Text(errorText).foregroundStyle(.red).font(.system(size: 12)) }
            if finished { Text(L("Done.")).foregroundStyle(Severity.calm.color).font(.system(size: 12)) }
            HStack {
                if running { ProgressView().controlSize(.small); Text(L("Running…")).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                if running { Button(L("Cancel")) { task?.cancel(); Task { await store.engine.cancelPendingLogin() } } }
                else if finished { Button(L("Close"), action: dismiss).keyboardShortcut(.defaultAction) }
                else { Button(L("Cancel"), action: dismiss); Button(L("Start")) { start() }.keyboardShortcut(.defaultAction).disabled(mode == .apiKey && secret.isEmpty) }
            }
        }
        .padding(20).frame(width: 520)
    }

    private func sendCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        codeSent = true
        Task { await store.submitLoginCode(trimmed) }
    }

    private func start() {
        running = true; lines = []; finished = false; errorText = nil; codeSent = false; loginURL = nil
        let request = AddAccountRequest(mode: mode, name: name.isEmpty ? nil : name, secret: secret.isEmpty ? nil : secret, path: (path as NSString).expandingTildeInPath)
        task = Task {
            do {
                try await store.addAccount(request) { event in
                    Task { @MainActor in
                        switch event {
                        case .line(let text): lines.append(text)
                        case .openURL(let url): loginURL = url; NSWorkspace.shared.open(url)
                        }
                    }
                }
                finished = true
                if mode == .apiKey { secret = "" }
            } catch is CancellationError {
                errorText = L("Cancelled")
            } catch let e as EngineError {
                errorText = e.message
            } catch {
                errorText = error.localizedDescription
            }
            running = false
        }
    }
}
