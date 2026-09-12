import Foundation

/// Where the proxy listens. The host is always loopback for the app's own engine; the type
/// remains so a config-supplied `proxy.host` can be validated before it is bound.
public struct ProxyEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var apiKey: String?

    public init(host: String = "127.0.0.1", port: Int = 10912, apiKey: String? = nil) {
        self.host = host; self.port = port; self.apiKey = apiKey
    }

    public var baseURLString: String {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "http://\(h):\(port)"
    }

    public var label: String { "\(host):\(port)" }

    /// A host the engine can bind and a client can dial: an IP literal or a plain host name, and a real port.
    public static func isValid(host: String, port: Int) -> Bool {
        guard (1...65535).contains(port), !host.isEmpty, host.count <= 253 else { return false }
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "[" || $0 == "]" } }
        return host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }
}
