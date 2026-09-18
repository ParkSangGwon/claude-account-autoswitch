import Foundation
import Crypto
import SwiftASN1
import X509

/// The local authority whose leaf the proxy presents when it terminates a CONNECT to the API host.
///
/// The CA private key is never written down. Serving needs only the leaf key, and renewal mints the
/// whole chain again, so the one secret on disk authenticates a single host to a process that already
/// trusts this CA. Nothing here goes near the system trust store: `NODE_EXTRA_CA_CERTS` is the only
/// thing that makes Claude Code accept it.
struct LocalCA: Sendable {
    /// Where the three files live, and what the client is told to trust.
    let caPath: URL
    let caPEM: String
    let leafPEM: String
    let leafKeyPEM: String
    /// The hosts the leaf is good for, and when the chain stops being usable.
    let hosts: [String]
    let notAfter: Date
    /// First eight bytes of the CA's SHA-256, for the settings pane.
    let fingerprint: String

    static let caFile = "ca.pem"
    static let leafFile = "leaf.pem"
    static let leafKeyFile = "leaf.key"

    /// Chains are reminted well before they expire: a leaf that dies mid-session fails the handshake
    /// with nothing in the app to explain why.
    static let renewWithin: TimeInterval = 30 * 24 * 3600
    static let caLifetime: TimeInterval = 3650 * 24 * 3600
    static let leafLifetime: TimeInterval = 825 * 24 * 3600

    /// Load the chain in `directory`, minting one when what is there cannot serve `hosts`.
    static func ensure(in directory: URL, hosts: [String], now: Date = Date()) throws -> LocalCA {
        if let existing = try? load(from: directory, hosts: hosts, now: now) { return existing }
        return try mint(in: directory, hosts: hosts, now: now)
    }

    /// Read the three files back and decide whether they still cover `hosts`.
    static func load(from directory: URL, hosts: [String], now: Date) throws -> LocalCA {
        let caPEM = try String(contentsOf: directory.appending(path: caFile), encoding: .utf8)
        let leafPEM = try String(contentsOf: directory.appending(path: leafFile), encoding: .utf8)
        let leafKeyPEM = try String(contentsOf: directory.appending(path: leafKeyFile), encoding: .utf8)

        let ca = try Certificate(pemEncoded: caPEM)
        let leaf = try Certificate(pemEncoded: leafPEM)
        _ = try Certificate.PrivateKey(pemEncoded: leafKeyPEM)

        guard ca.publicKey.isValidSignature(leaf.signature, for: leaf) else { throw CertificateError.unusable("leaf was not signed by this CA") }
        let deadline = now.addingTimeInterval(renewWithin)
        guard ca.notValidAfter > deadline, leaf.notValidAfter > deadline else { throw CertificateError.unusable("chain expires too soon") }
        let covered = Set(leaf.dnsNames)
        guard hosts.allSatisfy({ covered.contains($0) }) else { throw CertificateError.unusable("leaf does not cover every host") }

        return LocalCA(
            caPath: directory.appending(path: caFile),
            caPEM: caPEM, leafPEM: leafPEM, leafKeyPEM: leafKeyPEM,
            hosts: hosts, notAfter: min(ca.notValidAfter, leaf.notValidAfter),
            fingerprint: try shortFingerprint(of: ca)
        )
    }

    /// Mint a CA and a leaf under it, writing everything but the CA's own key.
    static func mint(in directory: URL, hosts: [String], now: Date) throws -> LocalCA {
        let caKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let caName = try DistinguishedName { CommonName("Claude AutoSwitch local CA") }
        let ca = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: caKey.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(caLifetime),
            issuer: caName,
            subject: caName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: caKey
        )

        let leafKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: leafKey.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(leafLifetime),
            issuer: caName,
            subject: try DistinguishedName { CommonName(hosts.first ?? "localhost") },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(hosts.map { GeneralName.dnsName($0) })
            },
            issuerPrivateKey: caKey
        )

        let caPEM = try ca.serializeAsPEM().pemString
        let leafPEM = try leaf.serializeAsPEM().pemString
        let leafKeyPEM = try leafKey.serializeAsPEM().pemString

        try write(caPEM, to: directory.appending(path: caFile), mode: 0o644)
        try write(leafPEM, to: directory.appending(path: leafFile), mode: 0o644)
        try write(leafKeyPEM, to: directory.appending(path: leafKeyFile), mode: 0o600)

        return LocalCA(
            caPath: directory.appending(path: caFile),
            caPEM: caPEM, leafPEM: leafPEM, leafKeyPEM: leafKeyPEM,
            hosts: hosts, notAfter: leaf.notValidAfter,
            fingerprint: try shortFingerprint(of: ca)
        )
    }

    /// Throw the chain away so the next `ensure` mints a fresh one.
    static func discard(in directory: URL) {
        for name in [caFile, leafFile, leafKeyFile] { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
    }

    private static func shortFingerprint(of certificate: Certificate) throws -> String {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let digest = SHA256.hash(data: Data(serializer.serializedBytes))
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Same atomic replace the config document uses, with the mode the file needs.
    private static func write(_ text: String, to target: URL, mode: mode_t) throws {
        let fm = FileManager.default
        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let data = Data(text.utf8)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CertificateError.unwritable(String(cString: strerror(errno))) }
        var failure: String?
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 { failure = String(cString: strerror(errno)); return }
                offset += n
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = String(cString: strerror(errno)) }
        close(fd)
        if failure == nil, chmod(temp.path, mode) != 0 { failure = String(cString: strerror(errno)) }
        if failure == nil, rename(temp.path, target.path) != 0 { failure = String(cString: strerror(errno)) }
        if let failure {
            unlink(temp.path)
            throw CertificateError.unwritable(failure)
        }
    }
}

enum CertificateError: Error {
    case unusable(String)
    case unwritable(String)

    var message: String {
        switch self {
        case .unusable(let why): return why
        case .unwritable(let why): return why
        }
    }
}

extension Certificate {
    /// The DNS names the leaf attests to, empty when it carries no SAN.
    var dnsNames: [String] {
        guard let ext = try? extensions.subjectAlternativeNames else { return [] }
        return ext.compactMap { if case .dnsName(let name) = $0 { return name } else { return nil } }
    }
}
