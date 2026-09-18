import Foundation
import NIOCore
import NIOPosix
@testable import AutoSwitchEngine

/// Answers a protocol upgrade with 101 and echoes whatever follows.
///
/// `HTTPServer` cannot stand in for this: `RequestHandler` buffers a request and writes one response,
/// so it can neither switch protocols nor carry frames afterwards.
final class UpgradeStandIn: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channel: Channel?
    private var request = ""
    private var echoed = Data()

    var boundPort: Int { lock.lock(); defer { lock.unlock() }; return channel?.localAddress?.port ?? 0 }
    var base: String { "http://127.0.0.1:\(boundPort)" }

    /// The request line and headers exactly as they arrived, so a test can see what survived the relay.
    var seenRequest: String { lock.lock(); defer { lock.unlock() }; return request }
    var seenAfterUpgrade: Data { lock.lock(); defer { lock.unlock() }; return echoed }

    func start() async throws {
        let owner = self
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(Handler(owner: owner))
            }
        setChannel(try await bootstrap.bind(host: "127.0.0.1", port: 0).get())
    }

    private func setChannel(_ c: Channel) {
        lock.lock(); channel = c; lock.unlock()
    }

    func stop() async {
        try? await takeChannel()?.close().get()
        try? await group.shutdownGracefully()
    }

    private func takeChannel() -> Channel? {
        lock.lock(); defer { lock.unlock() }
        let c = channel; channel = nil; return c
    }

    fileprivate func recordRequest(_ text: String) { lock.lock(); request = text; lock.unlock() }
    fileprivate func recordEcho(_ data: Data) { lock.lock(); echoed.append(data); lock.unlock() }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let owner: UpgradeStandIn
        private var head = ByteBuffer()
        private var upgraded = false

        init(owner: UpgradeStandIn) { self.owner = owner }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var incoming = unwrapInboundIn(data)
            if upgraded {
                if let bytes = incoming.readBytes(length: incoming.readableBytes) {
                    owner.recordEcho(Data(bytes))
                    var out = context.channel.allocator.buffer(capacity: bytes.count)
                    out.writeBytes(bytes)
                    context.writeAndFlush(wrapOutboundOut(out), promise: nil)
                }
                return
            }
            head.writeImmutableBuffer(incoming)
            let text = String(decoding: head.readableBytesView, as: UTF8.self)
            guard let end = text.range(of: "\r\n\r\n") else { return }
            owner.recordRequest(String(text[text.startIndex..<end.lowerBound]))
            upgraded = true
            var reply = context.channel.allocator.buffer(capacity: 128)
            reply.writeString("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n\r\n")
            // Closed right after the switch so a plain HTTP client stops waiting; a real socket
            // stays open, and what this test needs to know is that the 101 arrived at all.
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(wrapOutboundOut(reply), promise: promise)
            promise.futureResult.whenComplete { _ in context.close(promise: nil) }
        }
    }
}

/// A value a test can read after a callback on another thread wrote it.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
