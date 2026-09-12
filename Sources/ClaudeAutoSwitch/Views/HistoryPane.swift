import SwiftUI
import AutoSwitchCore

/// Seven days of what the app saw: a fleet sparkline and a state strip per account.
struct HistoryPane: View {
    @Environment(AppStore.self) private var store
    @State private var window: TimeInterval = 24 * 3600

    var body: some View {
        let now = Date()
        let since = now.addingTimeInterval(-window)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker(L("Window"), selection: $window) {
                    Text(L("6 h")).tag(6 * 3600.0)
                    Text(L("24 h")).tag(24 * 3600.0)
                    Text(L("7 d")).tag(7 * 24 * 3600.0)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                Text(L("%d samples · one a minute while the app runs", store.history.samples.count)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TitledGroup(title: L("Fleet")) {
                sparkline(title: L("Session (5-hour)"), points: store.history.series(since: since, until: now) { $0.fleetSession }, since: since, until: now)
                sparkline(title: L("Weekly"), points: store.history.series(since: since, until: now) { $0.fleetWeekly }, since: since, until: now)
            }
            TitledGroup(title: L("Accounts")) {
                let labels = store.history.accountLabels
                if labels.isEmpty {
                    Text(L("Nothing recorded yet — samples start with the first successful poll.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(labels, id: \.self) { label in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(store.compactName(label)).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(summary(label, since: since, until: now)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        HistoryStrip(segments: store.history.segments(account: label, since: since, until: now), since: since, until: now)
                            .frame(height: 12)
                        sparkline(title: nil, points: store.history.series(since: since, until: now) { $0.accounts[label]?.session }, since: since, until: now, height: 28)
                    }
                }
                HStack(spacing: 10) {
                    legend(L("in rotation"), .calm); legend(L("cooling down / capped"), .brisk); legend(L("over threshold"), .hot); legend(L("needs sign-in / spent"), .critical); legend(L("turned off"), nil); legend(L("app not running"), nil, hatched: true)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(L("Kept locally in ~/Library/Application Support/Claude AutoSwitch/history.json for seven days; the proxy itself only knows the present.")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func summary(_ label: String, since: Date, until: Date) -> String {
        let segs = store.history.segments(account: label, since: since, until: until)
        let total = segs.reduce(0.0) { $0 + $1.to.timeIntervalSince($1.from) }
        guard total > 0 else { return "" }
        let out = segs.filter { $0.state != "ok" && $0.state != "absent" }.reduce(0.0) { $0 + $1.to.timeIntervalSince($1.from) }
        return out > 0 ? L("out of rotation %@ of %@", Format.duration(out), Format.duration(total)) : L("in rotation the whole time")
    }

    @ViewBuilder
    private func sparkline(title: String?, points: [(Date, Double)], since: Date, until: Date, height: CGFloat = 44) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title { Text(title).font(.system(size: 11)).foregroundStyle(.secondary) }
            Sparkline(points: points, since: since, until: until).frame(height: height)
        }
    }

    private func legend(_ label: String, _ severity: Severity?, hatched: Bool = false) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(severity.map { $0.color } ?? Color.secondary.opacity(hatched ? 0.15 : 0.4)).frame(width: 10, height: 8)
            Text(label)
        }
    }
}

/// Runs of an account's state over the window, drawn as one coloured bar.
struct HistoryStrip: View {
    var segments: [HistorySegment]
    var since: Date
    var until: Date

    var body: some View {
        Canvas { ctx, size in
            let span = max(1, until.timeIntervalSince(since))
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.primary.opacity(0.06)))
            for s in segments {
                let x0 = size.width * CGFloat(max(0, s.from.timeIntervalSince(since)) / span)
                let x1 = size.width * CGFloat(min(span, s.to.timeIntervalSince(since)) / span)
                guard x1 > x0 else { continue }
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(HistoryStrip.color(for: s.state)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityLabel(segments.map { "\(HistoryStrip.title(for: $0.state)) \(Format.duration($0.to.timeIntervalSince($0.from)))" }.joined(separator: ", "))
    }

    static func title(for state: String) -> String {
        switch state {
        case "ok": return L("in rotation")
        case "cooling": return L("cooling down")
        case "capped", "metered": return L("capped")
        case "full", "refused": return L("over threshold")
        case "login": return L("needs sign-in")
        case "drained": return L("spent")
        case "off": return L("turned off")
        case "absent": return L("app not running")
        default: return state
        }
    }

    static func color(for state: String) -> Color {
        switch state {
        case "ok": return Severity.calm.color
        case "cooling", "capped", "metered": return Severity.brisk.color
        case "full", "refused": return Severity.hot.color
        case "login", "drained": return Severity.critical.color
        case "absent": return Color.secondary.opacity(0.15)
        default: return Color.secondary.opacity(0.4)
        }
    }
}

/// Utilization over time: an area with the last point emphasised and 50/100 % guides.
struct Sparkline: View {
    var points: [(Date, Double)]
    var since: Date
    var until: Date

    var body: some View {
        Canvas { ctx, size in
            let span = max(1, until.timeIntervalSince(since))
            for guide in [0.5, 1.0] {
                let y = size.height * CGFloat(1 - guide)
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(.primary.opacity(0.08)), lineWidth: 0.5)
            }
            guard points.count >= 2 else {
                if let p = points.first {
                    let x = size.width * CGFloat(p.0.timeIntervalSince(since) / span)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 2, y: size.height * CGFloat(1 - min(1, max(0, p.1))) - 2, width: 4, height: 4)), with: .color(Severity.calm.color))
                }
                return
            }
            func pt(_ p: (Date, Double)) -> CGPoint {
                CGPoint(x: size.width * CGFloat(p.0.timeIntervalSince(since) / span), y: size.height * CGFloat(1 - min(1, max(0, p.1))))
            }
            var line = Path()
            var area = Path()
            line.move(to: pt(points[0]))
            area.move(to: CGPoint(x: pt(points[0]).x, y: size.height))
            area.addLine(to: pt(points[0]))
            for p in points.dropFirst() { line.addLine(to: pt(p)); area.addLine(to: pt(p)) }
            area.addLine(to: CGPoint(x: pt(points[points.count - 1]).x, y: size.height))
            area.closeSubpath()
            let last = points[points.count - 1].1
            let color = Pace.plain(last).color
            ctx.fill(area, with: .color(color.opacity(0.15)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.2)
            let end = pt(points[points.count - 1])
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)), with: .color(color))
        }
        .accessibilityLabel(points.last.map { L("latest %@", Format.percent($0.1)) } ?? L("no data"))
    }
}
