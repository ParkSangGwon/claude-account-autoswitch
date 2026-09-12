import Foundation

/// Runtime-switchable localization. Keys are the English source strings; a
/// language without a translation for a key shows the English. The table is
/// read on every call so a language change takes effect on the next render,
/// no relaunch.
public enum L10n {
    public struct Language: Sendable, Equatable, Identifiable {
        public var id: String { code }
        public let code: String
        /// The language's own name for itself, which is how a language menu is readable in any language.
        public let name: String
    }

    public static let supported: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "ko", name: "한국어"),
        Language(code: "ja", name: "日本語"),
        Language(code: "zh-Hans", name: "简体中文"),
        Language(code: "es", name: "Español"),
        Language(code: "de", name: "Deutsch"),
        Language(code: "fr", name: "Français"),
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: String] = [:]
    nonisolated(unsafe) private static var current = "en"
    nonisolated(unsafe) private static var missing = false

    /// The language the Mac prefers among the ones the app ships.
    public static func systemDefault(preferences: [String] = Locale.preferredLanguages) -> String {
        Bundle.preferredLocalizations(from: supported.map(\.code), forPreferences: preferences).first ?? "en"
    }

    /// Switch languages; nil follows the system. Returns the code in effect.
    @discardableResult
    public static func activate(_ code: String?) -> String {
        let chosen = supported.contains { $0.code == code } ? code! : systemDefault()
        let loaded = loadTable(chosen)
        lock.lock(); table = loaded; current = chosen; missing = chosen != "en" && loaded.isEmpty; lock.unlock()
        return chosen
    }

    public static var language: String { lock.lock(); defer { lock.unlock() }; return current }
    /// True when the active language has no table in this build (the UI is showing English).
    public static var translationMissing: Bool { lock.lock(); defer { lock.unlock() }; return missing }

    /// The app language with the Mac's own region: Korean weekday names, the user's hour and date order.
    public static var locale: Locale {
        let parts = language.split(separator: "-").map(String.init)
        var c = Locale.Components(languageCode: Locale.LanguageCode(parts[0]), script: parts.count > 1 ? Locale.Script(parts[1]) : nil)
        c.region = Locale.current.region
        return Locale(components: c)
    }

    public static func string(_ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return table[key] ?? key
    }

    // MARK: - resources

    static let bundleName = "ClaudeAutoSwitch_AutoSwitchCore.bundle"

    /// The package's resource bundle, wherever this build put it: inside the app bundle (copied by the
    /// Makefile), next to a `swift run` binary, or next to the test bundle. Never `Bundle.module`, whose
    /// accessor traps when the bundle is absent — a missing translation must never be a crash.
    static func resourceBundle() -> Bundle? {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r) }
        candidates.append(Bundle.main.bundleURL)
        let own = Bundle(for: BundleAnchor.self).bundleURL
        candidates.append(own)
        candidates.append(own.deletingLastPathComponent())
        for dir in candidates {
            if let b = Bundle(url: dir.appending(path: bundleName)) { return b }
        }
        return nil
    }

    static func loadTable(_ code: String) -> [String: String] {
        // SwiftPM lower-cases lproj names when it processes resources (zh-Hans → zh-hans); a case-sensitive volume needs the second try.
        guard code != "en", let bundle = resourceBundle(),
              let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(code).lproj")
                ?? bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(code.lowercased()).lproj"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return dict
    }

    private final class BundleAnchor {}
}

/// The one-word spelling every view uses: `Text(L("Accounts"))`.
public func L(_ key: String) -> String { L10n.string(key) }

/// With arguments: `L("Resets in %@", countdown)`. Positional `%1$@` works when a language reorders them.
/// No locale on purpose: a locale would group `%d` ("9,212 runs") and the UI formats its own numbers.
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(key), arguments: args)
}
