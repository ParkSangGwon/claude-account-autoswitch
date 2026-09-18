import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import AutoSwitchCore

/// Catches a protocol upgrade before the engine sees it and relays the connection verbatim.
///
/// Remote Control's live channel is a WebSocket to `wss://api.anthropic.com/v1/session_ingress/ws/…`,
/// which is the host we terminate. `Relay.serve` cannot carry it: it buffers a whole request, answers
/// once, and `Engine.droppedOutbound` strips `upgrade`, `connection` and `authorization` — the three
/// headers the handshake is made of. So an upgrade must never reach it.
///
/// The client's own credential goes up untouched. The session is paired to the identity that asked
/// for it, and substituting the rotating account's token would only get it refused.
final class UpgradeGate: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart

    /// Where the upgrade should be forwarded; read late because the base URL can change under us.
    typealias UpstreamProvider = @Sendable () -> String

    /// The handlers to tear down before the connection becomes a byte pipe. Set by the pipeline builder.
    var httpHandlers: [RemovableChannelHandler] = []

    private let upstream: UpstreamProvider
    private let clientTLS: NIOSSLContext
    private var head: HTTPRequestHead?
    private var relaying = false

    init(upstream: @escaping UpstreamProvider, clientTLS: NIOSSLContext) {
        self.upstream = upstream
        self.clientTLS = clientTLS
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if relaying { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            // Per request, not per connection: a keep-alive connection can carry ordinary requests
            // and then an upgrade.
            if Self.isUpgrade(head) { self.head = head } else { self.head = nil; context.fireChannelRead(data) }
        case .body(let body):
            if head == nil { context.fireChannelRead(data) } else { _ = body }
        case .end:
            guard let head else { return context.fireChannelRead(data) }
            self.head = nil
            relaying = true
            start(head, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    static func isUpgrade(_ head: HTTPRequestHead) -> Bool {
        let connection = head.headers[canonicalForm: "connection"].map { $0.lowercased() }
        guard connection.contains("upgrade") else { return false }
        return !head.headers["upgrade"].isEmpty
    }

    /// Dial the upstream, replay the request line and headers byte for byte, then get out of the way.
    /// The 101 is never parsed — whatever the upstream answers, including a refusal, is the client's
    /// to interpret.
    private func start(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        let channel = context.channel
        guard let target = UpgradeTarget(baseURL: upstream()) else { return channel.close(promise: nil) }
        let tls = clientTLS
        let handlers = httpHandlers
        let box = UnsafeContext(context)

        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(15))
            .connect(host: target.host, port: target.port)
            .flatMap { upstream -> EventLoopFuture<Channel> in
                guard target.isSecure else { return upstream.eventLoop.makeSucceededFuture(upstream) }
                do {
                    let ssl = try NIOSSLClientHandler(context: tls, serverHostname: target.host)
                    return upstream.pipeline.addHandler(ssl, position: .first).map { upstream }
                } catch {
                    upstream.close(promise: nil)
                    return upstream.eventLoop.makeFailedFuture(error)
                }
            }
            .whenComplete { result in
                switch result {
                case .failure:
                    channel.close(promise: nil)
                case .success(let upstream):
                    var wire = channel.allocator.buffer(capacity: 512)
                    wire.writeString("\(head.method.rawValue) \(head.uri) HTTP/1.1\r\n")
                    for header in head.headers { wire.writeString("\(header.name): \(header.value)\r\n") }
                    wire.writeString("\r\n")
                    let request = wire

                    // The request goes out only once both ends are glued. Sent any earlier, a reply
                    // as quick as the 101 arrives at an upstream channel with nothing to carry it.
                    Self.becomeAPipe(channel, context: box.context, removing: handlers, upstream: upstream) {
                        upstream.writeAndFlush(request, promise: nil)
                    }
                }
            }
    }

    /// Strip the HTTP machinery off the client side and glue the two channels together.
    private static func becomeAPipe(_ channel: Channel, context: ChannelHandlerContext, removing handlers: [RemovableChannelHandler], upstream: Channel, then send: @escaping @Sendable () -> Void) {
        let removals = handlers.map { channel.pipeline.removeHandler($0) }
        EventLoopFuture.andAllComplete(removals, on: context.eventLoop).whenComplete { _ in
            channel.pipeline.removeHandler(context: context).whenComplete { _ in
                TunnelRelay.pipe(channel, upstream, then: send)
            }
        }
    }
}

/// The host, port and scheme an upgrade is forwarded to, taken from the configured base URL so the
/// WebSocket goes wherever the REST calls go.
struct UpgradeTarget: Equatable {
    let host: String
    let port: Int
    let isSecure: Bool

    init?(baseURL: String) {
        guard let url = URL(string: baseURL), let host = url.host else { return nil }
        let secure = (url.scheme ?? "https").lowercased() == "https"
        self.host = host
        self.port = url.port ?? (secure ? 443 : 80)
        self.isSecure = secure
    }
}
