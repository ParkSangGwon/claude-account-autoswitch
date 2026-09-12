import AppKit
import SwiftUI
import AutoSwitchCore

/// Renders the popover in both appearances to PNG files (2× scale).
@MainActor
enum Snapshot {
    static func write(store: AppStore, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, scheme) in [("popover-dark", ColorScheme.dark), ("popover-light", ColorScheme.light)] {
            let view = PopoverView().environment(store).environment(\.colorScheme, scheme).environment(\.snapshotMode, true)
                .background(scheme == .dark ? Color(nsColor: NSColor(calibratedWhite: 0.14, alpha: 1)) : Color(nsColor: .windowBackgroundColor))
            render(view, to: dir.appending(path: "\(name).png"))
        }
        for section in SettingsSection.allCases {
            let pane = SettingsPaneOnly(section: section).environment(store).environment(\.colorScheme, .dark).environment(\.snapshotMode, true)
                .frame(width: 600).padding(20).background(Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1)))
            render(pane, to: dir.appending(path: "settings-\(section.rawValue).png"))
        }
    }

    private static func render<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
