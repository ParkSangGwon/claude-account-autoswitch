import Foundation
import NIOCore
import NIOPosix

/// Which hosts a blind tunnel may dial.
///
/// The listener binds loopback only, so anything reaching it already runs as this user and could
/// open the same sockets itself — there is no privilege to escalate and no proxy key to enforce.
/// What is left worth refusing is a tunnel that comes back to us (an unbounded re-entry that eats
/// file descriptors) and the link-local metadata range.
struct TunnelPolicy: Sendable {
    /// The port the proxy listens on, so a tunnel back into it can be spotted.
    var listeningPort: Int
    /// Tests need a loopback echo server on the far side; production never does.
    var allowsLoopback: Bool

    static func production(listeningPort: Int) -> TunnelPolicy {
        TunnelPolicy(listeningPort: listeningPort, allowsLoopback: false)
    }

    static func permissive(listeningPort: Int) -> TunnelPolicy {
        TunnelPolicy(listeningPort: listeningPort, allowsLoopback: true)
    }

    func allows(host: String) -> Bool {
        if allowsLoopback { return true }
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") { return false }
        if name == "::1" || name == "::" || name.hasPrefix("fe80:") { return false }
        let octets = name.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            if octets[0] == 127 || octets[0] == 0 { return false }
            if octets[0] == 169 && octets[1] == 254 { return false }
        }
        return true
    }

    /// Whether a resolved address is this very listener. A name can point back at us without
    /// looking like it does, so the check runs again once the socket is up.
    func isSelf(_ address: SocketAddress, listeningPort ours: Int) -> Bool {
        guard address.port == ours else { return false }
        switch address {
        case .v4(let v4): return v4.host == "127.0.0.1" || String(describing: address).contains("127.0.0.1")
        case .v6: return true
        case .unixDomainSocket: return false
        }
    }
}

/// Byte-for-byte relay between the client and whatever it asked for, with back pressure kept.
enum TunnelRelay {
    /// A CONNECT tunnel: the gate already forwards client bytes, so only the return leg needs glue.
    static func glue(client: Channel, upstream: Channel, gate: ConnectGate) {
        _ = upstream.pipeline.addHandler(GlueHandler(partner: client))
        upstream.closeFuture.whenComplete { _ in gate.upstreamClosed(client: client) }
    }

    /// An upgraded connection: nothing forwards either side any more, so both ends get glue.
    /// `send` runs once both are in place, so nothing the upstream answers can outrun its own glue.
    static func pipe(_ client: Channel, _ upstream: Channel, then send: @escaping @Sendable () -> Void) {
        let both = [
            client.pipeline.addHandler(GlueHandler(partner: upstream)),
            upstream.pipeline.addHandler(GlueHandler(partner: client)),
        ]
        EventLoopFuture.andAllComplete(both, on: client.eventLoop).whenComplete { _ in send() }
    }
}

/// Writes everything it reads into its partner, and stops reading while the partner is backed up.
private final class GlueHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let partner: Channel

    init(partner: Channel) { self.partner = partner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        partner.writeAndFlush(buffer).whenComplete { [weak self] result in
            guard let self else { return }
            if case .failure = result { self.partner.close(promise: nil); context.close(promise: nil) }
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        // Mirror our writability onto the partner's reads: a slow client must not make us buffer
        // the whole of a fast upstream.
        if context.channel.isWritable {
            partner.read()
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner.close(promise: nil)
        context.close(promise: nil)
    }
}
