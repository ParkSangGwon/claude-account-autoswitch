import Foundation
import NIOCore
import NIOPosix
import AutoSwitchCore

/// The host and port a CONNECT names, normalised.
struct ConnectAuthority: Equatable, Sendable {
    let host: String
    let port: Int

    /// The API host is the only one worth holding open: the rotation has to read the exchange.
    static let terminatedHost = ClaudeAPI.host
    static let terminatedPort = 443

    var isTerminated: Bool { host == Self.terminatedHost && port == Self.terminatedPort }

    /// Splitting on the last colon gets four things wrong, and teamclaude hit every one of them:
    /// a bracketed IPv6 literal keeps its bracket, an empty host silently dials localhost, an
    /// uppercase or root-dotted name escapes the terminate route, and a port outside 1…65535 is
    /// taken at face value.
    static func parse(_ raw: String) -> ConnectAuthority? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var host: String
        var portText: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") { portText = rest.dropFirst() } else if !rest.isEmpty { return nil }
        } else if let colon = text.lastIndex(of: ":") {
            host = String(text[..<colon])
            portText = text[text.index(after: colon)...]
        } else {
            host = text
        }

        host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(" ") else { return nil }

        let port: Int
        if let portText {
            guard let parsed = Int(portText), (1...65535).contains(parsed) else { return nil }
            port = parsed
        } else {
            port = 443
        }
        return ConnectAuthority(host: host, port: port)
    }
}

/// The first handler on every connection: it reads the request line as raw bytes and decides whether
/// this is a CONNECT to hold open, a CONNECT to pass through, or an ordinary request for the engine.
///
/// It sniffs bytes rather than letting `HTTPRequestDecoder` do it because a client sends the TLS
/// ClientHello in the same segment as the CONNECT it answers; removing a decoder and adding handlers
/// around those bytes loses them. Holding the buffer here and replaying it once the pipeline is built
/// removes the race. The handler stays in the pipeline afterwards — one hop on loopback is free, and
/// removing it would reintroduce the same ordering problem.
final class ConnectGate: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// Builds the rest of the pipeline once the gate knows what this connection is.
    typealias Installer = @Sendable (Channel) -> EventLoopFuture<Void>

    private enum State {
        case sniffing(ByteBuffer)
        case passthrough
        case tunnelling(Channel)
        case closing
    }

    /// A request line longer than this is not a request line.
    private static let maxRequestLine = 8 * 1024

    private var state: State = .sniffing(ByteBuffer())
    private let terminator: Installer
    private let plaintext: Installer
    private let policy: TunnelPolicy
    private let onLegacyRequest: @Sendable (String) -> Void

    init(terminator: @escaping Installer, plaintext: @escaping Installer, policy: TunnelPolicy, onLegacyRequest: @escaping @Sendable (String) -> Void) {
        self.terminator = terminator
        self.plaintext = plaintext
        self.policy = policy
        self.onLegacyRequest = onLegacyRequest
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let incoming = unwrapInboundIn(data)
        switch state {
        case .closing:
            return
        case .passthrough:
            context.fireChannelRead(data)
        case .tunnelling(let upstream):
            upstream.writeAndFlush(incoming, promise: nil)
        case .sniffing(var buffer):
            buffer.writeImmutableBuffer(incoming)
            guard let line = Self.requestLine(in: buffer) else {
                if buffer.readableBytes > Self.maxRequestLine {
                    refuse(context: context, status: "400 Bad Request")
                } else {
                    state = .sniffing(buffer)
                }
                return
            }
            decide(line, buffer: buffer, context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if case .tunnelling(let upstream) = state { upstream.close(promise: nil) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - routing

    private func decide(_ line: String, buffer: ByteBuffer, context: ChannelHandlerContext) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return refuse(context: context, status: "400 Bad Request") }
        let method = String(parts[0])
        let target = String(parts[1])

        if method == "CONNECT" {
            guard let authority = ConnectAuthority.parse(target) else {
                return refuse(context: context, status: "400 Bad Request")
            }
            if authority.isTerminated {
                terminate(context: context, consuming: buffer)
            } else {
                tunnel(to: authority, context: context, consuming: buffer)
            }
            return
        }

        // Only a client still pointed here by ANTHROPIC_BASE_URL sends an absolute URI, and the
        // engine's upstream URL is built by concatenation — it cannot take one.
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            return refuse(context: context, status: "501 Not Implemented")
        }

        // Origin-form: the health endpoint and the smoke test, or a client that never moved off
        // ANTHROPIC_BASE_URL. Serve it either way and let the app say which it was.
        if !target.hasPrefix(Engine.healthPath) { onLegacyRequest(target) }
        state = .passthrough
        install(plaintext, context: context, replaying: buffer)
    }

    /// Answer the CONNECT, then hand the connection to the TLS pipeline. Whatever the client
    /// piggybacked on the CONNECT — normally the ClientHello — is replayed into it.
    private func terminate(context: ChannelHandlerContext, consuming buffer: ByteBuffer) {
        let leftovers = Self.remainder(after: buffer)
        state = .passthrough
        writeEstablished(context: context)
        install(terminator, context: context, replaying: leftovers)
    }

    /// Build the rest of the pipeline, then replay the bytes this handler was holding.
    private func install(_ installer: Installer, context: ChannelHandlerContext, replaying buffer: ByteBuffer?) {
        let channel = context.channel
        let box = UnsafeContext(context)
        installer(channel).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard let buffer, buffer.readableBytes > 0 else { return }
                let context = box.context
                context.fireChannelRead(self.wrapInboundOut(buffer))
                context.fireChannelReadComplete()
            case .failure:
                channel.close(promise: nil)
            }
        }
    }

    /// Dial the named host and glue the two channels together, seeing nothing in between.
    private func tunnel(to authority: ConnectAuthority, context: ChannelHandlerContext, consuming buffer: ByteBuffer) {
        guard policy.allows(host: authority.host) else {
            return refuse(context: context, status: "403 Forbidden")
        }
        let leftovers = Self.remainder(after: buffer)
        let channel = context.channel
        let ours = policy.listeningPort
        state = .closing

        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(15))
            .connect(host: authority.host, port: authority.port)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure:
                    // The client must learn the dial failed. Answering 200 first and closing quietly
                    // leaves it with an error it cannot place.
                    self.state = .closing
                    self.writeStatus("502 Bad Gateway", context: context, thenClose: true)
                case .success(let upstream):
                    // A name can resolve to us even when it is not spelled like us.
                    if let remote = upstream.remoteAddress, self.policy.isSelf(remote, listeningPort: ours) {
                        upstream.close(promise: nil)
                        self.state = .closing
                        self.writeStatus("403 Forbidden", context: context, thenClose: true)
                        return
                    }
                    self.state = .tunnelling(upstream)
                    self.writeEstablished(context: context)
                    TunnelRelay.glue(client: channel, upstream: upstream, gate: self)
                    if let leftovers, leftovers.readableBytes > 0 { upstream.writeAndFlush(leftovers, promise: nil) }
                }
            }
    }

    /// Called by the glue when the upstream half closes.
    func upstreamClosed(client: Channel) {
        state = .closing
        client.close(promise: nil)
    }

    // MARK: - raw replies

    private func writeEstablished(context: ChannelHandlerContext) {
        writeStatus("200 Connection Established", context: context, thenClose: false)
    }

    private func refuse(context: ChannelHandlerContext, status: String) {
        state = .closing
        writeStatus(status, context: context, thenClose: true)
    }

    /// Written as raw bytes: there is no response encoder in front of this handler.
    private func writeStatus(_ status: String, context: ChannelHandlerContext, thenClose: Bool) {
        var out = context.channel.allocator.buffer(capacity: 64)
        out.writeString("HTTP/1.1 \(status)\r\n\r\n")
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(out), promise: promise)
        if thenClose { promise.futureResult.whenComplete { _ in context.close(promise: nil) } }
    }

    // MARK: - byte work

    /// The request line, once the whole of it has arrived.
    private static func requestLine(in buffer: ByteBuffer) -> String? {
        let bytes = buffer.readableBytesView
        guard let cr = bytes.firstIndex(of: 0x0D), cr + 1 < bytes.endIndex, bytes[cr + 1] == 0x0A else { return nil }
        return String(decoding: bytes[bytes.startIndex..<cr], as: UTF8.self)
    }

    /// Whatever the client sent past the CONNECT's blank line — usually the TLS ClientHello.
    private static func remainder(after buffer: ByteBuffer) -> ByteBuffer? {
        let bytes = buffer.readableBytesView
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard bytes.count >= terminator.count else { return nil }
        for start in bytes.startIndex...(bytes.endIndex - terminator.count) where Array(bytes[start..<(start + terminator.count)]) == terminator {
            let tail = start + terminator.count
            guard tail < bytes.endIndex else { return nil }
            var out = ByteBufferAllocator().buffer(capacity: bytes.endIndex - tail)
            out.writeBytes(bytes[tail...])
            return out
        }
        return nil
    }
}
