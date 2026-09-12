import Foundation
import AutoSwitchCore

/// Credentials that already exist on this Mac: Claude Code's own, a credentials file, or the upstream project's config.
enum Importers {
    static let keychainService = "Claude Code-credentials"

    struct Imported: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var rateLimitTier: String?
    }

    /// Claude Code keeps its login in the Keychain; `security` is how every reader gets at it (a prompt may appear once).
    static func fromKeychain() throws -> Imported {
        let user = NSUserName()
        for args in [["find-generic-password", "-s", keychainService, "-a", user, "-w"], ["find-generic-password", "-s", keychainService, "-w"]] {
            if let out = try? run("/usr/bin/security", args), let imported = parse(Data(out.utf8)) { return imported }
        }
        throw EngineError.importFailed(L("Claude Code is not signed in on this Mac (no Keychain item)"))
    }

    static func fromFile(_ path: String) throws -> Imported {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { throw EngineError.importFailed(L("Cannot read %@", url.path)) }
        guard let imported = parse(data) else { throw EngineError.importFailed(L("No access token in %@", url.lastPathComponent)) }
        return imported
    }

    /// `{ claudeAiOauth: { accessToken, refreshToken, expiresAt } }` or the flat shape.
    static func parse(_ data: Data) -> Imported? {
        guard let json = try? JSON.parse(data) else { return nil }
        let raw = json["claudeAiOauth"].object != nil ? json["claudeAiOauth"] : json
        guard let token = raw["accessToken"].string, !token.isEmpty else { return nil }
        return Imported(accessToken: token, refreshToken: raw["refreshToken"].string, expiresAt: raw["expiresAt"].date, rateLimitTier: raw["rateLimitTier"].string)
    }

    private static func run(_ executable: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw EngineError.importFailed("security exited \(p.terminationStatus)") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
