import AppKit
import SwiftUI
import Observation
import AutoSwitchCore

/// Owns every piece of AppKit state for the menu bar item: the status item, the
/// popover, the right-click menu, and the observation loop that redraws the icon.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: AppStore
    private let openSettings: () -> Void
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var hosting: NSHostingController<AnyView>?
    private var container: PopoverContainerController?
    /// Wide enough for the account table's five columns at a readable size.
    static let popoverWidth: CGFloat = 380
    private var lastModel: IconModel?
    private var lastStyle: Preferences.IconStyle?
    private var lastMono: Bool?

    /// AppKit keeps the slot under this name in the standard domain, whatever domain `Preferences`
    /// uses, so `AUTOSWITCH_DEBUG_SIDECAR=<tag>` needs its own name too: a second instance shot for
    /// the documentation must not move the item the user dragged into place.
    static let autosaveName: String = {
        guard let tag = ProcessInfo.processInfo.environment["AUTOSWITCH_DEBUG_SIDECAR"], !tag.isEmpty else { return "claudeAutoSwitch.main" }
        return "claudeAutoSwitch.\(tag)"
    }()

    /// macOS remembers a status item's slot under this key (distance from the
    /// right edge, in points). A new item otherwise lands at the far left of the
    /// status area, which a full menu bar hides behind the notch or an overflow
    /// chevron. Seeded once, on the first launch, so a slot the user dragged the
    /// item to afterwards survives a relaunch.
    static func seedPositionOnFirstLaunch() {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(30, forKey: key)
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(autosaveName)")
    }

    init(store: AppStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        Self.seedPositionOnFirstLaunch()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = NSStatusItem.AutosaveName(Self.autosaveName)
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        popover.behavior = .transient
        // A status-item popover follows the menu bar's appearance (dark over a dark wallpaper), not the app's;
        // documentation screenshots pin it with the same variable App.swift honours.
        if let raw = ProcessInfo.processInfo.environment["AUTOSWITCH_DEBUG_APPEARANCE"] {
            popover.appearance = NSAppearance(named: raw == "dark" ? .darkAqua : .aqua)
        }
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(rootView: AnyView(PopoverView().environment(store)))
        // A bare NSHostingController as the popover's content ended up offset inside
        // the popover frame (clipped left edge). Pinning it inside a plain container
        // with Auto Layout keeps it exactly where the popover puts its content.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        let container = PopoverContainerController(hosting: hosting)
        popover.contentViewController = container
        self.hosting = hosting
        self.container = container
        observe()
    }

    /// Re-render whenever the pieces of the store the icon depends on change.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        let model = store.iconModel
        let style = store.prefs.iconStyle
        let mono = store.prefs.monochrome
        // The tooltip is localized, so a language change already shows up as a new model; reading the
        // language here only keeps this render inside the observation that fires on the change.
        _ = store.prefs.language
        guard let button = item.button else { return }
        if model == lastModel, style == lastStyle, mono == lastMono { return }
        lastModel = model; lastStyle = style; lastMono = mono
        let rendered = IconRenderer.render(model, style: style, monochrome: mono)
        if popover.isShown { resizePopover() }
        button.image = rendered.image
        button.attributedTitle = rendered.title
        button.toolTip = model.tooltip
        button.setAccessibilityLabel(model.tooltip)
    }

    @objc private func clicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    func togglePopover() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    func showPopover() {
        guard let button = item.button else { return }
        store.popoverOpen = true
        store.refreshNow()
        resizePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // The popover window takes the menu bar's appearance when it is created; a screenshot pin applies here.
        if let raw = ProcessInfo.processInfo.environment["AUTOSWITCH_DEBUG_APPEARANCE"] {
            popover.contentViewController?.view.window?.appearance = NSAppearance(named: raw == "dark" ? .darkAqua : .aqua)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    var popoverWindowNumber: Int? { popover.contentViewController?.view.window?.windowNumber }

    /// Screen frame of the status item, for the documentation screenshot crop.

    var statusItemFrame: CGRect? { item.button?.window?.frame }
    var statusItemScale: CGFloat { item.button?.window?.screen?.backingScaleFactor ?? 2 }

    /// Measure the SwiftUI content at the fixed width and size the popover to it.
    func resizePopover() {
        guard let hosting else { return }
        let size = hosting.sizeThatFits(in: NSSize(width: Self.popoverWidth, height: 10_000))
        let target = NSSize(width: Self.popoverWidth, height: max(120, ceil(size.height)))
        if popover.contentSize != target {
            container?.preferredContentSize = target
            popover.contentSize = target
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        store.popoverOpen = false
    }

    private func showMenu() {
        let menu = NSMenu()
        let current = store.state?.currentAccount?.label
        let head = NSMenuItem(title: current.map { L("Current: %@", store.displayName($0)) } ?? "Claude AutoSwitch", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if store.state?.accounts.count ?? 0 > 1 {
            let next = menu.addItem(withTitle: L("Switch to Next Available Account"), action: #selector(switchNext), keyEquivalent: "")
            next.target = self
            next.isEnabled = !store.isDown
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Refresh"), action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: L("Reload Config"), action: #selector(reload), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Open Terminal with Claude Code"), action: #selector(launchClaudeCode), keyEquivalent: "t").target = self
                menu.addItem(.separator())
        let paused = store.prefs.alertPrefs.isPaused(at: Date())
        menu.addItem(withTitle: paused ? L("Resume Notifications") : L("Pause Notifications for 1 Hour"), action: #selector(togglePause), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Settings…"), action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit Claude AutoSwitch"), action: #selector(quit), keyEquivalent: "q").target = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func switchNext() { store.switchToNextAvailable() }
    @objc private func refresh() { store.refreshNow() }
    @objc private func reload() { Task { await store.reloadConfig() } }
    @objc private func launchClaudeCode() { Actions.launchClaudeCode(store) }
    @objc private func togglePause() {
        var p = store.prefs.alertPrefs
        p.pausedUntil = p.isPaused(at: Date()) ? nil : Date().addingTimeInterval(3600)
        store.prefs.alertPrefs = p
    }
    @objc private func settings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Plain container whose only job is to pin the SwiftUI hosting view to its edges.
@MainActor
final class PopoverContainerController: NSViewController {
    private let hosting: NSHostingController<AnyView>

    init(hosting: NSHostingController<AnyView>) {
        self.hosting = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = NSView()
        addChild(hosting)
        let child = hosting.view
        child.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            child.topAnchor.constraint(equalTo: root.topAnchor),
            child.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}

enum Actions {
    /// Ordinary copy. `copySecret` marks the pasteboard concealed, which is right for a token and
    /// wrong for a setup line someone wants to keep in their clipboard manager.
    static func copyPlainly(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    static func copySecret(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    /// Open the default terminal on `claude` pointed at the proxy, through a .command file (no Automation permission needed).
    @MainActor static func launchClaudeCode(_ store: AppStore) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Claude AutoSwitch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "claude.command")
        // `-l` reads the profile first, so an old `export ANTHROPIC_BASE_URL` may still be in the
        // environment; the setup file's closing `unset` runs after it and clears it.
        let cmd = "#!/bin/zsh -l\n\(store.claudeCodeEnvironment.sourceLine)\nexec claude\n"
        try? cmd.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o755)
        NSWorkspace.shared.open(file)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// What is listening on a port, as `lsof` names it. Best effort: no answer at all is normal,
    /// and the point is to save the person the trip to a terminal, not to be authoritative.
    static func processHolding(port: Int) -> String? {
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard FileManager.default.isExecutableFile(atPath: lsof.path) else { return nil }
        let task = Process()
        task.executableURL = lsof
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "cp"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        // `-F cp` prints one field per line: `p<pid>` then `c<command>`.
        var command: String?
        var pid: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            switch line.first {
            case "c": command = String(line.dropFirst())
            case "p": pid = String(line.dropFirst())
            default: break
            }
            if let command, let pid { return "\(command) (\(pid))" }
        }
        return command
    }
}
