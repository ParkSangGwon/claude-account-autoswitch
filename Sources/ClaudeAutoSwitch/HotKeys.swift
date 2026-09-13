import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon's hot-key API: no Accessibility permission,
/// works while any app is frontmost. Two fixed chords, each with an on/off switch.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum Key: UInt32 {
        case nextAccount = 1
        case togglePopover = 2

        var keyCode: UInt32 {
            switch self {
            case .nextAccount: return UInt32(kVK_ANSI_N)
            case .togglePopover: return UInt32(kVK_ANSI_T)
            }
        }
        /// ⌃⌥⌘ + the letter.
        static let modifiers = UInt32(controlKey | optionKey | cmdKey)
        var title: String {
            switch self {
            case .nextAccount: return "⌃⌥⌘N"
            case .togglePopover: return "⌃⌥⌘T"
            }
        }
    }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    /// Which shortcuts are switched on but could not be registered, because another app holds the
    /// chord. Without this the toggle stays on and the key simply never fires.
    private(set) var unavailable: Set<Key> = []

    @discardableResult
    func set(_ key: Key, enabled: Bool, handler: @escaping () -> Void) -> Bool {
        unregister(key)
        unavailable.remove(key)
        guard enabled else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x4341_5357, id: key.rawValue) // "CASW"
        guard RegisterEventHotKey(key.keyCode, Key.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else {
            unavailable.insert(key)
            NSLog("[ClaudeAutoSwitch] %@ is held by another app", key.title)
            return false
        }
        refs[key.rawValue] = ref
        handlers[key.rawValue] = handler
        return true
    }

    private func unregister(_ key: Key) {
        if let ref = refs.removeValue(forKey: key.rawValue) { UnregisterEventHotKey(ref) }
        handlers[key.rawValue] = nil
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
