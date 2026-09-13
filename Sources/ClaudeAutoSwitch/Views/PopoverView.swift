import SwiftUI
import AppKit
import AutoSwitchCore

struct PopoverView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.snapshotMode) private var snapshotMode

    static let width = StatusItemController.popoverWidth

    var body: some View {
        // The language read makes a change re-render every `L()` label without a relaunch.
        let _ = store.prefs.language
        // Only the "updated Ns ago" line needs seconds; everything else counts minutes, so the
        // tree re-evaluates every 30 s (and hourly while the popover is closed) instead of every second.
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: store.popoverOpen ? 1 : 3600)) { context in header(now: context.date) }
            Divider()
            TimelineView(.periodic(from: .now, by: store.popoverOpen ? 30 : 3600)) { context in
                let now = context.date
                VStack(alignment: .leading, spacing: 10) {
                    banners
                    if let state = store.state, state.accounts.isEmpty {
                        emptyState
                    } else if let state = store.state {
                        // The accounts table is the one place every number lives; the current account is its highlighted row.
                        accounts(state, now: now)
                        // One account: the fleet is that account, already in the row above.
                        if state.accounts.count > 1 { fleetCard(state, now: now) }
                        let rows = Explain.targets(state)
                        if !rows.isEmpty { targets(rows, state: state) }
                        sessions(state, now: now)
                        journal(now: now)
                    } else {
                        Text(store.isDown ? L("The listener could not start. Change the port under Settings → Proxy, or quit the program holding it, then try again.") : L("Starting the proxy…"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    /// A running proxy with nothing to serve: the one line that tells a new install what to do next.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("No accounts yet — add a Claude subscription or an API key.")).font(.system(size: 12))
            Button(L("Open Accounts…")) {
                NSApp.sendAction(#selector(AppDelegate.showAccountsSettings), to: nil, from: nil)
            }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: header

    @ViewBuilder
    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(store.isDown ? Severity.hot.color : (store.state == nil ? Color.gray : Severity.calm.color)).frame(width: 6, height: 6)
                accountMenu
                Spacer()
                Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Refresh (⌘R)")).keyboardShortcut("r")
                Button { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Settings (⌘,)")).keyboardShortcut(",")
            }
            Text(subline(now: now)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var accountMenu: some View {
        if snapshotMode {
            HStack(spacing: 4) {
                Text(currentTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        } else {
            accountMenuControl
        }
    }

    private var accountMenuControl: some View {
        Menu {
            if let state = store.state {
                ForEach(state.byRank) { a in
                    Button {
                        store.switchTo(a.id)
                    } label: {
                        let mark = a.id == state.current ? "✓ " : (a.id == state.next && state.next != state.current ? "→ " : "   ")
                        let why = a.blocker.map { " · \($0.text)" } ?? ""
                        Text(mark + store.displayName(a.label) + why)
                    }
                }
                if state.accounts.count > 1 {
                    Divider()
                    Button(L("Next available account") + "  \(HotKeyCenter.Key.nextAccount.title)") { store.switchToNextAvailable() }
                }
            }
        } label: {
            Text(currentTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .frame(maxWidth: 240, alignment: .leading)
        .disabled(store.isDown)
        .help(store.isDown ? L("The proxy is not reachable") : L("Switch the current account"))
    }

    private var currentTitle: String {
        store.state?.currentAccount.map { store.displayName($0.label) } ?? L("No current account")
    }

    /// Freshness first: it is the part that changes.
    private func subline(now: Date) -> String {
        var parts: [String] = []
        if let t = store.lastSuccessAt { parts.append(L("updated %@ ago", Format.duration(now.timeIntervalSince(t)))) }
        if let n = store.state?.accounts.count { parts.append(n == 1 ? L("1 account") : L("%d accounts", n)) }
        parts.append(store.endpoint.label)
        if let started = store.state?.listener.startedAt { parts.append(L("up %@", Format.duration(now.timeIntervalSince(started)))) }
        return parts.joined(separator: " · ")
    }

    // MARK: banners

    /// At most three, worst first, and a banner with a button is never the one dropped.
    @ViewBuilder
    private var banners: some View {
        let items = bannerItems
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, b in b }
                if items.count > 3 {
                    Text(L("+%d more", items.count - 3)).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var bannerItems: [Banner] {
        var out: [Banner] = []
        func rank(_ b: Banner) -> Int {
            let severity = b.kind == .bad ? 0 : b.kind == .warn ? 1 : b.kind == .ok ? 2 : 3
            return severity * 2 + (b.action == nil ? 1 : 0)
        }
        if case .down(let since, let error) = store.connection {
            out.append(Banner(kind: .bad, text: L("%@ — showing data from %@ ago", error.message, Format.duration(Date().timeIntervalSince(since))), action: { store.refreshNow() }, actionTitle: L("Retry")))
        }
        if let state = store.state {
            for n in Explain.notices(state) { out.append(Banner(kind: n.severity == .bad ? .bad : .warn, text: n.text)) }
            if state.isExhausted {
                out.append(Banner(kind: .bad, text: L("No account can serve — %@.", Explain.exhaustedReason(state))))
            } else if let cur = state.currentAccount, let why = cur.blocker?.text, !state.currentMovedOn {
                // Traffic that already moved to another account is ordinary rotation (the targets row says so); this is the stuck case.
                out.append(Banner(kind: .warn, text: L("Rotation cannot use %@: %@, and no other account can take over.", store.displayName(cur.label), why)))
            }
        }
        // Stable sort: severity, then actionable first; the toast always leads because it answers what the user just did.
        out = out.enumerated().sorted { a, b in rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset }.map(\.element)
        if let toast = store.toast {
            out.insert(Banner(kind: toast.kind == .error ? .bad : toast.kind == .warn ? .warn : toast.kind == .ok ? .ok : .info, text: toast.text), at: 0)
        }
        return out
    }

    // MARK: fleet

    @ViewBuilder
    private func fleetCard(_ state: EngineState, now: Date) -> some View {
        let known = Fleet.total(state, .session)?.knownAccounts ?? 0
        let unweighed = Fleet.unweighed(state).count
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("Fleet"), trailing: L("weighted by tier · %d/%d known", known, state.accounts.count) + (unweighed == 0 ? "" : " · " + L("%d without a tier", unweighed)))
            Card {
                fleetRow(WindowKind.session.title, state, .session, now: now)
                fleetRow(WindowKind.weekly.title, state, .weekly, now: now)
                ForEach(Family.allCases, id: \.self) { f in
                    if state.accounts.contains(where: { $0.windows[f.window] != nil }) {
                        fleetRow(f.title, state, f.window, now: now)
                    }
                }
                resetStrip(state, now: now)
            }
        }
    }

    /// The fleet bar coloured by the same pace rule as an account bar.
    @ViewBuilder
    private func fleetRow(_ label: String, _ state: EngineState, _ kind: WindowKind, now: Date) -> some View {
        if let total = Fleet.total(state, kind) {
            let severity = Pace.severity(used: total.used, resetsAt: total.nextResetAt, length: kind.length, threshold: state.rotation.switchAt(kind), now: now)
            HStack(spacing: 10) {
                Text(label).font(.system(size: 11)).frame(width: 56, alignment: .leading)
                QuotaBar(ratio: total.used, severity: severity, cap: nil)
                // Wide enough for "100%" once the chip's padding is on it.
                Text("\(Format.percentInt(total.used))%").font(.system(size: 13, weight: .semibold)).monospacedDigit().fixedSize()
                    .severityChip(severity).padding(.trailing, -4)
                    .frame(width: 48, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Fleet %@ %d percent", label, Format.percentInt(total.used)))
        }
    }

    /// Every account's coming resets, soonest first: when capacity returns, and whose.
    @ViewBuilder
    private func resetStrip(_ state: EngineState, now: Date) -> some View {
        let entries = Fleet.resetTimeline(state, now: now, limit: 6)
        VStack(alignment: .leading, spacing: 3) {
            if entries.isEmpty {
                Text(L("No reset in sight")).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                // One wrapped line: "↑" marks a reset that brings an account back into rotation.
                let line = entries.map { e in
                    (e.freesCapacity ? "↑ " : "") + "\(store.compactName(e.label)) \(e.kind.tag) \(Format.countdown(e.resetsAt, now: now))"
                }.joined(separator: "  ·  ")
                Text(L("Resets:") + " " + line).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(entries.map { L("%@ · %@: %@", $0.label, $0.kind.tag, Format.resetSentence($0.resetsAt, style: .both, now: now)) + ($0.freesCapacity ? " · " + L("brings the account back into rotation") : "") }.joined(separator: "\n"))
            }
        }
    }

    // MARK: targets (which account serves which model family)

    @ViewBuilder
    private func targets(_ rows: [TargetRow], state: EngineState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: L("Routing"))
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    Circle().fill(r.target == nil ? Color.red : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(r.title).font(.system(size: 11))
                    Text("→").foregroundStyle(.secondary).font(.system(size: 11))
                    Text(state.label(r.target).map(store.compactName) ?? "—").font(.system(size: 11)).foregroundStyle(r.target == nil ? .red : .primary).lineLimit(1)
                    Spacer()
                    Text(targetNote(r, state: state)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(r.ineligible.isEmpty ? "" : L("Not eligible: %@", r.ineligible.joined(separator: ", ")))
            }
        }
    }

    private func targetNote(_ r: TargetRow, state: EngineState) -> String {
        if r.family != nil {
            let total = r.eligible.count + r.ineligible.count
            return total > 0 ? L("%d of %d eligible", r.eligible.count, total) : ""
        }
        let current = state.label(state.current).map(store.compactName) ?? ""
        if let why = r.currentBlocker?.text, !r.isCurrent { return L("current %@ is blocked: %@", current, why) }
        if r.isCurrent { return L("current") }
        return r.target == nil ? "" : L("outranks %@", current)
    }

    // MARK: accounts

    @ViewBuilder
    private func accounts(_ state: EngineState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("Accounts"), trailing: sessionsSummary(state))
            AccountsTable(state: state, now: now)
            if state.accounts.count > 1, let next = Explain.nextRequest(state, now: now) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Text(next.isCurrent ? L("Next request stays on %@", store.compactName(next.label)) : L("Next → %@", store.compactName(next.label))).font(.system(size: 11, weight: .medium))
                    Text("· " + next.reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.leading, 2)
                .help(L("The next unrouted request goes to %@.", next.label) + " " + next.reason)
            }
        }
    }

    private func sessionsSummary(_ state: EngineState) -> String {
        let mode = state.rotation.spreadSessions ? L("distributing") : L("single-account")
        return L("%d active / %d known · %@", state.activeSessionCount, state.sessions.count, mode)
    }

    // MARK: sessions

    @ViewBuilder
    private func sessions(_ state: EngineState, now: Date) -> some View {
        let active = state.sessions.filter(\.active)
        if !active.isEmpty {
            SessionsSection(items: Array(active.prefix(8)), total: active.count, state: state, now: now)
        }
    }

    // MARK: journal

    @ViewBuilder
    private func journal(now: Date) -> some View {
        let events = store.prefs.journal.latest
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: L("Rotation"), trailing: L("%d in 24 h", store.prefs.journal.count(within: 86400, now: now)))
                ForEach(events.prefix(5)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L("%@ ago", Format.duration(now.timeIntervalSince(e.at)))).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text("\(e.from.map(store.compactName) ?? "—") → \(store.compactName(e.to))").font(.system(size: 11, weight: e.manual ? .regular : .medium)).lineLimit(1)
                        Text(e.reasonText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .help(Format.localizedDate(e.at, date: .abbreviated, time: .shortened) + " · " + e.reasonText + (e.manual ? " · " + L("manual") : ""))
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button(L("Claude Code")) { Actions.launchClaudeCode(store) }.keyboardShortcut("t")
            Spacer()
            Button(L("Settings…")) { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) }
            Button(L("Quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
    }
}

/// Which Claude Code session sticks to which account: client, the pins, in-flight work.
struct SessionsSection: View {
    @Environment(AppStore.self) private var store
    var items: [SessionRecord]
    var total: Int
    var state: EngineState
    var now: Date
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionHeader(title: L("Sessions"), trailing: L("%d active", total))
                Button(expanded ? L("Hide") : L("Show")) { expanded.toggle() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if expanded {
                ForEach(items) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.client ?? String(s.id.prefix(8))).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                        Text("→ " + pinnedAccounts(s)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if s.inFlight > 0 { Chip(text: L("%d in flight", s.inFlight), color: Severity.calm.color) }
                        if s.starved > 0 { Chip(text: L("starved %d", s.starved), color: Severity.critical.color) }
                        Text(L("%@ ago", Format.duration(now.timeIntervalSince(s.lastSeen)))).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .help(L("session %@", s.id) + "\n" + L("%d requests", s.requests) + " · " + pinnedAccounts(s))
                }
                if total > items.count { Text(L("+%d more", total - items.count)).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
    }

    private func pinnedAccounts(_ s: SessionRecord) -> String {
        let names = s.pins.sorted { $0.key.rawValue < $1.key.rawValue }.compactMap { window, id -> String? in
            state.label(id).map { "\(store.compactName($0)) (\(window.tag))" }
        }
        return names.isEmpty ? L("unpinned") : names.joined(separator: ", ")
    }
}
