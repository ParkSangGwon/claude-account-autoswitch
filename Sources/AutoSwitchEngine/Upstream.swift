import Foundation

/// One upstream exchange: the head arrives as soon as the response starts, the body follows as chunks.
struct UpstreamReply: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: AsyncThrowingStream<Data, Error>
}

enum Upstream {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 3600
        c.httpMaximumConnectionsPerHost = 64
        // Never through a proxy, least of all our own: the app now tells Claude Code to set
        // HTTPS_PROXY, and an upstream call that honoured it would dial straight back into us.
        c.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable: 0, kCFNetworkProxiesHTTPSEnable: 0]
        return URLSession(configuration: c)
    }()

    static func send(_ request: URLRequest) async throws -> UpstreamReply {
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        var headers: [(String, String)] = []
        for (k, v) in http?.allHeaderFields ?? [:] { if let k = k as? String, let v = v as? String { headers.append((k, v)) } }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var buffer = Data()
                buffer.reserveCapacity(4096)
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        // SSE frames end in a newline; flushing there keeps the client's stream as live as the upstream's.
                        if byte == 0x0A || buffer.count >= 16_384 {
                            continuation.yield(buffer)
                            buffer = Data()
                            buffer.reserveCapacity(4096)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return UpstreamReply(status: http?.statusCode ?? 0, headers: headers, body: stream)
    }
}
