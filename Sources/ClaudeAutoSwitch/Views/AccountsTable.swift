import SwiftUI
import AppKit
import AutoSwitchCore

/// Per-account rows as a dense table: one column per window (session, weekly, and the
/// family weeks when any account has one), a bar with the number and reset under it.
struct AccountsTable: View {
    @Environment(AppStore.self) private var store
    var state: EngineState
    var now: Date

    static let wideCol: CGFloat = 62
    static let narrowCol: CGFloat = 40
    static let gap: CGFloat = 4
    static let menuWidth: CGFloat = 22

    /// A family column only exists when some account meters that family separately (the fleet card's rule).
    var families: [Family] { Family.allCases.filter { f in state.accounts.contains { $0.windows[f.window] != nil } } }

    /// Whatever the window columns do not need goes to the name.
    var nameWidth: CGFloat {
        let inner = StatusItemController.popoverWidth - 28 - 20 - Self.menuWidth
        let cols = 2 * Self.wideCol + CGFloat(families.count) * Self.narrowCol
        let gaps = Self.gap * CGFloat(3 + families.count)
        return max(90, inner - cols - gaps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(state.byRank) { a in
                Divider().padding(.vertical, 2)
                AccountTableRow(account: a, state: state, now: now, nameWidth: nameWidth, families: families)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: Self.gap) {
            Text(L("ACCOUNT")).frame(width: nameWidth, alignment: .leading)
            Text(L("SES")).frame(width: Self.wideCol, alignment: .leading)
            Text(L("WK")).frame(width: Self.wideCol, alignment: .leading)
            ForEach(families, id: \.self) { f in Text(f.window.tag).frame(width: Self.narrowCol, alignment: .leading) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
    }
}

struct AccountTableRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.snapshotMode) private var snapshotMode
    var account: AccountStatus
    var state: EngineState
    var now: Date
    var nameWidth: CGFloat
    var families: [Family]
    @State private var priorityText = ""
    @State private var askPriority = false
    @State private var confirmRemove = false

    var isCurrent: Bool { account.id == state.current }
    var isNext: Bool { !isCurrent && account.id == state.next }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: AccountsTable.gap) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Image(systemName: isNext ? "arrow.turn.down.right" : "arrowtriangle.right.fill").font(.system(size: 7)).foregroundStyle(isCurrent || isNext ? Color.accentColor : Color.clear)
                        Text(store.compactName(account.label)).font(.system(size: isCurrent ? 12 : 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        if let o = account.overage, o.enabled { Chip(text: "$", color: (o.usedMinor ?? 0) > 0 ? Severity.hot.color : .secondary) }
                    }
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(statusColor).lineLimit(1)
                }
                .frame(width: nameWidth, alignment: .leading)
                .help(nameHelp)

                if account.kind == .apiKey {
                    // The column headers say session/weekly; an API key has tokens and requests instead.
                    cell(account.windows.tokens?.used, resetsAt: account.windows.metersResetAt, kind: nil, name: L("Tokens"), prefix: L("Tok "), width: AccountsTable.wideCol)
                    cell(account.windows.requests?.used, resetsAt: account.windows.metersResetAt, kind: nil, name: L("Requests"), prefix: L("Req "), width: AccountsTable.wideCol)
                    ForEach(families, id: \.self) { _ in placeholder(AccountsTable.narrowCol) }
                } else {
                    cell(account.windows[.session]?.used, resetsAt: account.windows[.session]?.resetsAt, kind: .session, name: WindowKind.session.title, width: AccountsTable.wideCol)
                    cell(account.windows[.weekly]?.used, resetsAt: account.windows[.weekly]?.resetsAt, kind: .weekly, name: WindowKind.weekly.title, width: AccountsTable.wideCol)
                    ForEach(families, id: \.self) { f in family(account.windows[f.window], kind: f.window, name: L("%@ weekly", f.title)) }
                }
                Spacer(minLength: 0)
                if !snapshotMode { rowMenu } else { Image(systemName: "ellipsis.circle").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if let b = account.blocker {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                    Text(b.text).font(.system(size: 10)).lineLimit(1)
                }
                .severityChip(b.needsPerson ? .critical : .brisk)
                .padding(.leading, nameWidth + AccountsTable.gap - 4)
            }
        }
        .padding(.vertical, 2)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.label)\(isCurrent ? ", " + L("current") : isNext ? ", " + L("next") : ""), \(subtitle)")
        .alert(L("Priority for %@", store.displayName(account.label)), isPresented: $askPriority) {
            TextField("0", text: $priorityText)
            Button(L("Set")) { if let n = Int(priorityText) { Task { await store.setRank(account.id, .number(n)) } } }
            Button(L("Cancel"), role: .cancel) {}
        } message: { Text(L("Lower is preferred. A strictly lower value preempts a healthy current account.")) }
        .confirmationDialog(L("Remove %@?", store.displayName(account.label)), isPresented: $confirmRemove) {
            Button(L("Remove"), role: .destructive) { Task { await store.removeAccount(account.id) } }
        } message: { Text(AppStore.removeAccountMessage) }
    }

    private var rowMenu: some View {
        Menu {
            if !isCurrent { Button(L("Make current")) { store.switchTo(account.id) }.disabled(store.isDown) }
            Button(account.enabled ? L("Disable") : L("Enable")) { Task { await store.setEnabled(account.id, !account.enabled) } }
            Button(L("Set priority…")) { priorityText = String(account.rank); askPriority = true }
            Button(L("Move to top")) { Task { await store.setRank(account.id, .first) } }
            Button(L("Move to bottom")) { Task { await store.setRank(account.id, .last) } }
            Divider()
            Button(L("Copy name")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(account.label, forType: .string) }
            Button(L("Remove…"), role: .destructive) { confirmRemove = true }
        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 11)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(isCurrent ? L("Actions") : L("Make current, enable/disable, priority, remove"))
    }

    @ViewBuilder
    private func cell(_ ratio: Double?, resetsAt: Date?, kind: WindowKind?, name: String, prefix: String = "", width: CGFloat) -> some View {
        let resetLong = Format.resetSentence(resetsAt, style: .both, now: now)
        VStack(alignment: .leading, spacing: 2) {
            if let ratio {
                let threshold = kind.map { state.rotation.switchAt($0) } ?? state.rotation.switchAt
                let severity = Pace.severity(used: ratio, resetsAt: resetsAt, length: kind?.length, threshold: threshold, now: now)
                QuotaBar(ratio: ratio, severity: severity, cap: nil, height: 5)
                    .frame(width: width - 6)
                // Two lines: how much is used, then when it resets, so neither crowds the other.
                // The number takes a chip as soon as the window needs attention; a thin bar alone is easy to miss.
                Text(prefix + "\(Format.percentInt(ratio))%").font(.system(size: isCurrent ? 11 : 10, weight: severity == .calm ? (isCurrent ? .semibold : .regular) : .semibold, design: .monospaced)).lineLimit(1)
                    .severityChip(severity).padding(.leading, -4)
                Text(countdown(resetsAt)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                QuotaBar(ratio: 0, severity: .calm, cap: nil, height: 5).frame(width: width - 6)
                Text(prefix + "—").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                Text(" ").font(.system(size: 10, design: .monospaced))
            }
        }
        .frame(width: width, alignment: .leading)
        .help(ratio.map { "\(name) \(Format.percent($0))" + (resetLong.isEmpty ? "" : " · " + resetLong) } ?? L("%@ unknown", name))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ratio.map { "\(name) \(Format.percent($0))" + (resetLong.isEmpty ? "" : ", " + resetLong) } ?? L("%@ unknown", name))
    }

    @ViewBuilder
    private func family(_ reading: WindowReading?, kind: WindowKind, name: String) -> some View {
        if let r = reading {
            let severity = Pace.severity(r, kind: kind, threshold: state.rotation.switchAt(kind), now: now)
            let resetLong = Format.resetSentence(r.resetsAt, style: .both, now: now)
            VStack(alignment: .leading, spacing: 2) {
                QuotaBar(ratio: r.used, severity: severity, cap: nil, height: 5)
                    .frame(width: AccountsTable.narrowCol - 6)
                Text("\(Format.percentInt(r.used))%").font(.system(size: isCurrent ? 11 : 10, weight: severity == .calm ? (isCurrent ? .semibold : .regular) : .semibold, design: .monospaced))
                    .severityChip(severity).padding(.leading, -4)
                Text(countdown(r.resetsAt)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: AccountsTable.narrowCol, alignment: .leading)
            .help("\(name) \(Format.percent(r.used)) · \(resetLong)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) \(Format.percent(r.used)), \(resetLong)")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                QuotaBar(ratio: 0, severity: .calm, cap: nil, height: 5).frame(width: AccountsTable.narrowCol - 6)
                Text(L("=wk")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                Text(" ").font(.system(size: 10, design: .monospaced))
            }
            .frame(width: AccountsTable.narrowCol, alignment: .leading)
            .help(L("%@ shares the weekly bucket", name))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("%@ shares the weekly bucket", name))
        }
    }

    private func placeholder(_ width: CGFloat) -> some View {
        Text("—").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).frame(width: width, alignment: .leading).accessibilityHidden(true)
    }

    /// The reset countdown under the percentage; a blank keeps rows the same height when none is known.
    private func countdown(_ resetsAt: Date?) -> String {
        let r = Format.countdown(resetsAt, now: now)
        return r.isEmpty ? " " : r
    }

    private var subtitle: String {
        var parts: [String] = [account.plan.badge]
        if !account.enabled { parts.append(L("disabled")) }
        else if account.health == .coolingDown, let until = account.coolingUntil {
            let r = Format.countdown(until, now: now)
            parts.append(r.isEmpty ? L("cooling down") : L("cooling down %@", r))
        } else if account.health == .needsLogin { parts.append(L("needs sign-in")) }
        else if account.health == .drained { parts.append(L("spent")) }
        if account.rank != 0 { parts.append(L("prio %d", account.rank)) }
        if account.activeSessions > 0 { parts.append(L("%d sess", account.activeSessions)) }
        if account.knownSessions > account.activeSessions { parts.append(L("%d known", account.knownSessions)) }
        return parts.joined(separator: " · ")
    }

    /// Everything that does not fit the row: the full label, the organization, the overage.
    private var nameHelp: String {
        var lines = [account.label + (account.organization?.name.map { " · \($0)" } ?? "")]
        if isNext { lines.append(L("Next: the next unrouted request goes here")) }
        if let o = account.overage, o.enabled {
            lines.append(L("Overage %@ this month", Format.money(minor: o.usedMinor ?? 0, currency: o.currency, exponent: o.exponent)))
        }
        return lines.joined(separator: "\n")
    }

    private var statusColor: Color {
        if !account.enabled { return .secondary }
        switch account.health {
        case .ok: return .secondary
        case .coolingDown: return Severity.brisk.ink
        case .drained, .needsLogin: return Severity.critical.ink
        }
    }
}
