import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import AutoSwitchCore

/// The listener Claude Code is pointed at with `HTTPS_PROXY`.
///
/// It answers `CONNECT api.anthropic.com:443` by holding the TLS itself, so the rotation still sees
/// every request and reply; every other CONNECT is relayed blind. Ordinary origin-form requests are
/// served too — the health endpoint arrives that way, and so does a client that has not yet moved off
/// `ANTHROPIC_BASE_URL`.
final class ProxyServer: Sendable {
    let port: Int
    private let handler: HTTPServer.Handler
    private let onLegacyRequest: @Sendable (String) -> Void
    private let tls: NIOSSLContext
    private let policy: TunnelPolicy
    private let group: MultiThreadedEventLoopGroup
    private let channelBox = ChannelBox()

    /// `policy` is injected so tests can tunnel to a loopback stand-in; production never widens it.
    init(port: Int, certificates: LocalCA, policy: TunnelPolicy? = nil, handler: @escaping HTTPServer.Handler, onLegacyRequest: @escaping @Sendable (String) -> Void) throws {
        self.port = port
        self.handler = handler
        self.onLegacyRequest = onLegacyRequest
        self.policy = policy ?? .production(listeningPort: port)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        do {
            let chain = try NIOSSLCertificate.fromPEMBytes(Array(certificates.leafPEM.utf8)).map { NIOSSLCertificateSource.certificate($0) }
            let key = try NIOSSLPrivateKey(bytes: Array(certificates.leafKeyPEM.utf8), format: .pem)
            var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: chain, privateKey: .privateKey(key))
            // http/1.1 alone, deliberately. Remote Control's channel is a WebSocket, and over HTTP/2
            // that needs RFC 8441 extended CONNECT — teamclaude shipped h2 here and watched the
            // handshake vanish with no error at all. Everything downstream is HTTP/1.1 anyway, and
            // the leg that carries volume is the upstream one, where URLSession still negotiates h2.
            configuration.applicationProtocols = ["http/1.1"]
            configuration.minimumTLSVersion = .tlsv12
            self.tls = try NIOSSLContext(configuration: configuration)
        } catch {
            throw EngineError.certificates(String(describing: error))
        }
    }

    var boundPort: Int { channelBox.port }

    func start() async throws {
        let handler = self.handler
        let tls = self.tls
        let onLegacy = self.onLegacyRequest
        let policy = self.policy

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let gate = ConnectGate(
                    terminator: { channel in
                        Self.terminate(channel, tls: tls, handler: handler)
                    },
                    plaintext: { channel in
                        Self.serveInTheClear(channel, handler: handler)
                    },
                    policy: policy,
                    onLegacyRequest: onLegacy
                )
                return channel.pipeline.addHandler(gate)
            }
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
            channelBox.set(channel, port: channel.localAddress?.port ?? port)
        } catch let e as IOError where e.errnoCode == EADDRINUSE {
            throw EngineError.portInUse(port)
        } catch {
            throw EngineError.listen(String(describing: error))
        }
    }

    func stop() async {
        if let c = channelBox.take() { try? await c.close().get() }
    }

    /// TLS first, then the same HTTP/1.1 pipeline the plaintext path uses.
    private static func terminate(_ channel: Channel, tls: NIOSSLContext, handler: @escaping HTTPServer.Handler) -> EventLoopFuture<Void> {
        do {
            let ssl = NIOSSLServerHandler(context: tls)
            return channel.pipeline.addHandler(ssl).flatMap { httpPipeline(channel, handler: handler) }
        }
    }

    private static func serveInTheClear(_ channel: Channel, handler: @escaping HTTPServer.Handler) -> EventLoopFuture<Void> {
        httpPipeline(channel, handler: handler)
    }

    /// Assembled by hand rather than with `configureHTTPServerPipeline`, which does not let the
    /// decoder forward the bytes it has already buffered.
    private static func httpPipeline(_ channel: Channel, handler: @escaping HTTPServer.Handler) -> EventLoopFuture<Void> {
        channel.pipeline.addHandlers([
            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
            HTTPResponseEncoder(),
            HTTPServerPipelineHandler(),
            HTTPServerProtocolErrorHandler(),
            RequestHandler(handler: handler),
        ])
    }

    deinit { try? group.syncShutdownGracefully() }
}
