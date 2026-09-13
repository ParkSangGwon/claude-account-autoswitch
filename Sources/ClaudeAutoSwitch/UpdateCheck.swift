import Foundation
import AutoSwitchCore

/// Asks GitHub what the newest release is. A menu bar app is left running for months, and this one
/// talks to endpoints that change under it, so "there is a newer build" has to reach the person
/// somehow. It only ever reads the tag name; installing stays manual.
enum UpdateCheck {
    static let releasesURL = URL(string: "https://github.com/ParkSangGwon/claude-account-autoswitch/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/ParkSangGwon/claude-account-autoswitch/releases/latest")!

    /// The latest tag, without its `v`. Nil when the network, the rate limit or the shape says no.
    static func latestVersion() async -> String? {
        var request = URLRequest(url: api)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tag = (try? JSON.parse(data))?["tag_name"].string else { return nil }
        let trimmed = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return trimmed.isEmpty ? nil : trimmed
    }
}
