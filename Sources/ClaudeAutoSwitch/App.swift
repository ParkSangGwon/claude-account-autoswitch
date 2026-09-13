import AppKit
import SwiftUI
import Observation
import AutoSwitchCore

@main
struct ClaudeAutoSwitchApp {
    static func main() {
        // Pipes to a child that exited and sockets to a proxy that went away must not take the app down.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, no main window. Set here too so `swift run` behaves like the bundle.
        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu()
        app.run()
    }

    /// Never shown (LSUIElement), but key equivalents route through the main menu: without an
    /// Edit menu ⌘C/⌘V/⌘A do nothing in the settings text fields, and ⌘W cannot close the window.
    static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Claude AutoSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        menu.addItem(windowItem)
        return menu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore!
    private var statusItem: StatusItemController!
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = AppStore()
        statusItem = StatusItemController(store: store, openSettings: { [weak self] in self?.showSettings() })
        Notifier.shared.onOpen = { [weak self] in self?.statusItem.showPopover() }
        Notifier.shared.requestAuthorization()
        store.start()
        observeHotkeys()
        // `AUTOSWITCH_SNAPSHOT=<dir>` renders the popover to PNG after the first
        // poll and quits: PR screenshots and a look at the layout without a click.
        if let dir = ProcessInfo.processInfo.environment["AUTOSWITCH_SNAPSHOT"], !dir.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                await store.loadConfiguration()
                try? await Task.sleep(for: .seconds(1))
                Snapshot.write(store: store, to: URL(fileURLWithPath: dir))
                NSApp.terminate(nil)
            }
        }
        // `AUTOSWITCH_DEBUG_APPEARANCE=light|dark` pins the appearance for documentation screenshots
        // (the status-item popover pins its own in StatusItemController).
        if let raw = ProcessInfo.processInfo.environment["AUTOSWITCH_DEBUG_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: raw == "dark" ? .darkAqua : .aqua)
        }
        // `AUTOSWITCH_DEBUG_WINDOW=<section>` opens the settings window on that
        // section and the popover, and logs their window numbers for `screencapture -l`.
        if let raw = ProcessInfo.processInfo.environment["AUTOSWITCH_DEBUG_WINDOW"], let section = SettingsSection(rawValue: raw) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                settings = SettingsWindowController(store: store, section: section)
                settings?.show()
                NSLog("[ClaudeAutoSwitch] settings window %d", settings?.windowNumber ?? -1)
                statusItem.showPopover()
                try? await Task.sleep(for: .seconds(1))
                NSLog("[ClaudeAutoSwitch] popover window %d", statusItem.popoverWindowNumber ?? -1)
                if let f = statusItem.statusItemFrame {
                    let scale = statusItem.statusItemScale
                    NSLog("[ClaudeAutoSwitch] status item frame %.0f %.0f %.0f %.0f scale %.0f", f.minX, f.minY, f.width, f.height, scale)
                }
            }
        }
    }

    /// `applicationWillTerminate` cannot wait for anything: the work it starts is still in flight when
    /// the process goes, which lost the last rotation and up to five minutes of history on every quit.
    /// The engine is an actor of its own, so waiting for it here blocks nothing it needs; the timeout
    /// is there because a quit that hangs is worse than a quit that skips the last write.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.prepareForQuit()
        let engine = store.engine
        let finished = DispatchSemaphore(value: 0)
        Task.detached { await engine.stop(); finished.signal() }
        _ = finished.wait(timeout: .now() + 3)
        return .terminateNow
    }

    /// Bind the two global shortcuts to their switches, re-binding whenever a switch changes.
    private func observeHotkeys() {
        withObservationTracking {
            let prefs = store.prefs
            HotKeyCenter.shared.set(.nextAccount, enabled: prefs.hotkeyNextAccount) { [weak self] in self?.store.switchToNextAvailable() }
            HotKeyCenter.shared.set(.togglePopover, enabled: prefs.hotkeyTogglePopover) { [weak self] in self?.statusItem.togglePopover() }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHotkeys() }
        }
    }

    @objc func showSettings() {
        statusItem.closePopover()
        if settings == nil { settings = SettingsWindowController(store: store) }
        settings?.show()
    }

    @objc func showAccountsSettings() {
        statusItem.closePopover()
        settings = SettingsWindowController(store: store, section: .accounts)
        settings?.show()
    }
}
