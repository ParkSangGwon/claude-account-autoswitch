import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import AutoSwitchCore

struct HTTPRequest: Sendable {
    var method: String
    var uri: String
    var headers: [(String, String)]
    var body: Data

    var path: String { uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri }
    func header(_ name: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }
}

/// A response the handler hands back whole, or as a stream of chunks (SSE relays).
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: HTTPBody

    enum HTTPBody: Sendable {
        case data(Data)
        case stream(AsyncStream<Data>)
    }

    init(status: Int, headers: [(String, String)] = [], body: HTTPBody) {
        self.status = status; self.headers = headers; self.body = body
    }

    init(status: Int, json: JSON) {
        let data = Data(json.pretty().utf8)
        self.init(status: status, headers: [("content-type", "application/json"), ("content-length", String(data.count))], body: .data(data))
    }
}

/// HTTP/1.1 on loopback. One handler closure gets every request with its body buffered.
final class HTTPServer: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    let port: Int
    private let handler: Handler
    private let group: MultiThreadedEventLoopGroup
    private let channelBox = ChannelBox()

    init(port: Int, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    /// The port actually bound (differs from `port` only when 0 asked for any free port).
    var boundPort: Int { channelBox.port }

    func start() async throws {
        let handler = self.handler
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(RequestHandler(handler: handler))
                }
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

    deinit { try? group.syncShutdownGracefully() }
}

/// The listening channel, shared between start and stop without making the server an actor.
private final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private(set) var port = 0
    func set(_ c: Channel, port p: Int) { lock.lock(); channel = c; port = p; lock.unlock() }
    func take() -> Channel? { lock.lock(); defer { lock.unlock() }; let c = channel; channel = nil; return c }
}

/// Collects one request, runs the handler off the event loop, writes the response; keep-alive is left to NIO.
private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handler: HTTPServer.Handler
    private var head: HTTPRequestHead?
    private var body = Data()
    /// Requests are answered one at a time per connection; pipelined ones queue behind the running one.
    private var busy = false
    private var pending: [(HTTPRequestHead, Data)] = []

    init(handler: @escaping HTTPServer.Handler) { self.handler = handler }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body = Data()
        case .body(var buf):
            if let bytes = buf.readBytes(length: buf.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let h = head else { return }
            head = nil
            if busy { pending.append((h, body)); return }
            run(h, body, context: context)
        }
    }

    private func run(_ h: HTTPRequestHead, _ body: Data, context: ChannelHandlerContext) {
        busy = true
        let request = HTTPRequest(method: h.method.rawValue, uri: h.uri, headers: h.headers.map { ($0.name, $0.value) }, body: body)
        let handler = self.handler
        let loop = context.eventLoop
        let keepAlive = h.isKeepAlive
        let ctxBox = UnsafeContext(context)
        Task {
            let response = await handler(request)
            loop.execute { [self] in
                let context = ctxBox.context
                var headers = HTTPHeaders()
                for (k, v) in response.headers { headers.add(name: k, value: v) }
                if !keepAlive { headers.replaceOrAdd(name: "connection", value: "close") }
                let responseHead = HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.status), headers: headers)
                context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                switch response.body {
                case .data(let data):
                    var buf = context.channel.allocator.buffer(capacity: data.count)
                    buf.writeBytes(data)
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                    self.finish(context: context, keepAlive: keepAlive)
                case .stream(let stream):
                    Task {
                        for await chunk in stream {
                            loop.execute {
                                var buf = context.channel.allocator.buffer(capacity: chunk.count)
                                buf.writeBytes(chunk)
                                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                            }
                        }
                        loop.execute { self.finish(context: context, keepAlive: keepAlive) }
                    }
                }
            }
        }
    }

    private func finish(context: ChannelHandlerContext, keepAlive: Bool) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        if !keepAlive { promise.futureResult.whenComplete { _ in context.close(promise: nil) } }
        busy = false
        if !pending.isEmpty {
            let (h, b) = pending.removeFirst()
            run(h, b, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// NIO's context is not Sendable; it is only ever touched from its own event loop, which every use above guarantees.
private struct UnsafeContext: @unchecked Sendable {
    let context: ChannelHandlerContext
    init(_ c: ChannelHandlerContext) { context = c }
}
