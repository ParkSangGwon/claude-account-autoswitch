import SwiftUI
import AppKit
import AutoSwitchCore

struct ProxyPane: View {
    @Environment(AppStore.self) private var store
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card(L("Connection")) {
                row(L("Endpoint"), store.endpoint.label)
                row(L("State"), connectionText)
                if let l = store.state?.listener {
                    row(L("Started"), l.startedAt.map { Format.localizedDate($0, date: .abbreviated, time: .shortened) } ?? "—")
                    row(L("Upstream"), l.baseURL)
                }
                HStack {
                    Button(L("Poll now")) { store.refreshNow() }.controlSize(.small)
                    if store.isDown { Button(L("Try again")) { Task { await store.restartEngine() } }.controlSize(.small).buttonStyle(.borderedProminent) }
                    if store.isDown { Button(L("Use a free port")) { Task { await store.moveToFreePort() } }.controlSize(.small) }
                }
                if store.isDown {
                    if let holder = store.portHeldBy {
                        Text(L("%@ is listening on this port. Quit it and try again, or move this proxy to a free port — the line Claude Code uses changes with it.", holder)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L("Another program holds this port, or the address cannot be bound. Change the port below or quit the other program, then try again.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if store.nothingHasArrivedYet {
                    Banner(kind: .warn, text: L("The proxy is up but has not been asked for anything yet. Claude Code only goes through it once the line below is in the shell that runs it."))
                }
            }
            card(L("Claude Code")) {
                Text(L("Point Claude Code at the proxy: put this in your shell profile, or run it before `claude`.")).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(store.claudeCodeEnvLine).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button(copied ? L("Copied") : L("Copy")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.claudeCodeEnvLine, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    }.controlSize(.small)
                    Button(L("Open Terminal with Claude Code")) { Actions.launchClaudeCode(store) }.controlSize(.small)
                }
                Text(L("Claude Code keeps its own login; the proxy swaps in the rotating account's token on the way out. Nothing else changes.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text(L("Network")).font(.system(size: 13, weight: .semibold))
            SchemaPane(section: .proxy)
        }
    }

    private var connectionText: String {
        switch store.connection {
        case .starting: return L("starting…")
        case .up: return L("listening") + (store.lastSuccessAt.map { " · " + L("updated %@ ago", Format.duration(Date().timeIntervalSince($0))) } ?? "")
        case .down(let since, let e): return "\(e.message) (" + L("since %@", Format.localizedDate(since, date: .omitted, time: .shortened)) + ")"
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        TitledGroup(title: title, content: content)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
        }.font(.system(size: 12))
    }
}

// MARK: - Quota

struct QuotaPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let state = store.state {
                ProbeStatusView(state: state)
                Divider()
            }
            SchemaPane(section: .quota)
        }
    }
}

struct ProbeStatusView: View {
    @Environment(AppStore.self) private var store
    var state: EngineState

    var summary: String {
        let probe = state.probe
        guard probe.enabled else { return L("off (quota is read from responses; idle accounts stay unknown until rotation reaches them)") }
        var s = L("every %d s", probe.intervalSeconds)
        if let next = probe.nextRunAt, case let r = Format.countdown(next), !r.isEmpty { s += " · " + L("next in %@", r) }
        if let last = probe.lastFinishedAt { s += " · " + L("last %@ ago", Format.duration(Date().timeIntervalSince(last))) }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Probe status")).font(.system(size: 13, weight: .semibold))
            Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(state.accounts.filter { $0.kind == .subscription }) { a in
                let status = a.probe.map { $0.error == nil ? L("ok") : L("error") } ?? L("pending")
                let text = "\(store.compactName(a.label)): \(status)" + (a.probe?.error.map { " · \($0)" } ?? "")
                Text(text).font(.system(size: 11)).foregroundStyle(a.probe?.error == nil ? Color.secondary : Color.red)
            }
        }
    }
}
