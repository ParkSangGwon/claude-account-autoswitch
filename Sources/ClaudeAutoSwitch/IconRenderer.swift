import AppKit
import AutoSwitchCore

/// Draws the status-item glyph: two mini bars (5h over 7d) on a translucent
/// track. Monochrome renders as a template image so AppKit tints it for the
/// menu bar's appearance; the colour mode paints the severity.
enum IconRenderer {
    struct Rendered {
        var image: NSImage?
        var title: NSAttributedString
    }

    static func color(for state: IconState) -> NSColor {
        switch state {
        case .normal, .rotating: return SeverityColors.calm
        case .warning: return SeverityColors.hot
        case .critical: return SeverityColors.critical
        case .proxyDown, .stale, .noAccounts, .starting: return .secondaryLabelColor
        }
    }

    static func render(_ model: IconModel, style: Preferences.IconStyle, monochrome: Bool) -> Rendered {
        let showBars = style != .percent
        let quiet = style == .quiet && (model.state == .normal)
        var text: String? = nil
        switch style {
        case .bars: text = nil
        case .percent, .barsPercent: text = model.label
        case .barsBoth:
            if let l = model.label, let w = model.weeklyLabel {
                let bang = l.hasSuffix("!")
                text = "\(bang ? String(l.dropLast()) : l) · \(w)" + (bang ? "!" : "")
            }
            else { text = model.label }
        case .quiet: text = quiet ? nil : model.label
        }
        if case .rotating = model.state { text = model.label }
        if model.state == .proxyDown { text = style == .bars ? nil : "—" }
        if model.state == .starting { text = nil }
        // Pinned to one account: its three-letter tag leads the title at a legible size, never inside the glyph.
        if let tag = model.tag, model.state != .starting, model.state != .proxyDown { text = [tag, text].compactMap { $0 }.joined(separator: " ") }

        let image = showBars ? barsImage(model, monochrome: monochrome) : nil
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: monochrome ? NSColor.labelColor : color(for: model.state),
            .baselineOffset: 0.5,
        ]
        let title = NSAttributedString(string: text.map { " " + $0 } ?? "", attributes: attrs)
        return Rendered(image: image, title: title)
    }

    static func barsImage(_ model: IconModel, monochrome: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let fg: NSColor = monochrome ? .black : color(for: model.state)
            let dim = model.state == .proxyDown || model.state == .stale || model.state == .starting
            let trackAlpha: CGFloat = dim ? 0.22 : 0.28
            let fillAlpha: CGFloat = dim ? 0.4 : 1
            let barW: CGFloat = 16, barH: CGFloat = 3, x: CGFloat = 2
            let top: CGFloat = 9.5, bottom: CGFloat = 3.5
            func bar(y: CGFloat, fill: Double?) {
                let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: barH), xRadius: barH / 2, yRadius: barH / 2)
                fg.withAlphaComponent(trackAlpha).setFill()
                track.fill()
                guard let fill else { return }
                let w = max(fill > 0 ? 1 : 0, barW * CGFloat(min(1, max(0, fill))))
                let f = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: barH), xRadius: barH / 2, yRadius: barH / 2)
                fg.withAlphaComponent(fillAlpha).setFill()
                f.fill()
            }
            bar(y: top, fill: model.fiveHour)
            bar(y: bottom, fill: model.weekly)
            if model.state == .critical {
                fg.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16, y: rect.height - 4.5, width: 4, height: 4)).fill()
            }
            if model.state == .proxyDown {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 3, y: 2)); line.line(to: NSPoint(x: 17, y: rect.height - 2))
                line.lineWidth = 1.5; line.lineCapStyle = .round
                fg.withAlphaComponent(0.9).setStroke()
                line.stroke()
            }
            return true
        }
        image.isTemplate = monochrome
        image.accessibilityDescription = model.tooltip
        return image
    }
}
