import Foundation

/// The upstream Claude Code dials by name. The proxy terminates this host and tunnels every other.
public enum ClaudeAPI {
    public static let host = "api.anthropic.com"
}

/// What a shell has to hold for Claude Code to go through this proxy.
///
/// It is a proxy, not a different API: `ANTHROPIC_BASE_URL` stays unset so Claude Code keeps talking
/// to `api.anthropic.com` and keeps Remote Control, managed settings and organization policy with it.
public struct ClaudeCodeEnvironment: Sendable, Equatable {
    public let endpoint: ProxyEndpoint
    public let caPath: String
    public let scriptPath: String
    public let wrapperPath: String

    public init(endpoint: ProxyEndpoint, caPath: String, scriptPath: String, wrapperPath: String = "") {
        self.endpoint = endpoint
        self.caPath = caPath
        self.scriptPath = scriptPath
        self.wrapperPath = wrapperPath
    }

    /// The variables in the order they are written, for a settings pane that lists them.
    public var variables: [(name: String, value: String)] {
        let proxy = endpoint.baseURLString
        return [
            ("HTTPS_PROXY", proxy),
            ("https_proxy", proxy),
            ("NODE_EXTRA_CA_CERTS", caPath),
            ("NO_PROXY", "localhost,127.0.0.1,::1"),
            ("no_proxy", "localhost,127.0.0.1,::1"),
        ]
    }

    /// The exports as a shell would take them, ending in the line that matters most to anyone
    /// updating from an older version.
    public var shellBlock: String {
        variables.map { "export \($0.name)=\(Self.quoted($0.value))" }.joined(separator: "\n")
            + "\nunset ANTHROPIC_BASE_URL\n"
    }

    /// What the app writes, and what both the launcher and the profile line read.
    public var scriptContents: String {
        """
        # Written by Claude AutoSwitch. Edited by hand, it will be overwritten.
        # Claude Code keeps talking to api.anthropic.com; this only puts the proxy in front of it.
        \(shellBlock)
        """
    }

    /// The one line to put in a shell profile. Sourcing a generated file rather than pasting the
    /// exports means a port change never leaves a stale line behind, and the guard keeps the shell
    /// quiet if the app is ever removed.
    public var sourceLine: String {
        "[ -f \(Self.quoted(scriptPath)) ] && source \(Self.quoted(scriptPath))"
    }

    /// A `claude` that brings the proxy with it, for the places a shell profile does not reach: an
    /// editor or launcher that runs the binary directly and lets you name which one.
    /// `command` skips any alias, and the file is named differently so it cannot call itself.
    public var wrapperContents: String {
        "#!/bin/zsh\n"
            + "# Written by Claude AutoSwitch. Edited by hand, it will be overwritten.\n"
            + "source \(Self.quoted(scriptPath))\n"
            + "exec command claude \"$@\"\n"
    }

    /// Reads any shell profile without changing it, for someone who has an old export to find.
    public static let locateOldExport = "grep -rn ANTHROPIC_BASE_URL ~/.zshrc ~/.zprofile ~/.bash_profile ~/.profile 2>/dev/null"

    /// Single quotes: the app's own directory has a space in it.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
