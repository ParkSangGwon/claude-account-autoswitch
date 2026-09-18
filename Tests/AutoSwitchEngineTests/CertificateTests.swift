import XCTest
import X509
@testable import AutoSwitchEngine

final class CertificateTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "autoswitch-ca-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func mode(of name: String) throws -> mode_t {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)
        return (attributes[.posixPermissions] as! NSNumber).uint16Value
    }

    func testMintingWritesTheChainButNeverTheCAKey() throws {
        let ca = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com"])

        XCTAssertEqual(try mode(of: LocalCA.caFile), 0o644)
        XCTAssertEqual(try mode(of: LocalCA.leafFile), 0o644)
        XCTAssertEqual(try mode(of: LocalCA.leafKeyFile), 0o600, "the leaf key is the one secret on disk")

        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(written), [LocalCA.caFile, LocalCA.leafFile, LocalCA.leafKeyFile],
                       "nothing else is written — in particular the CA private key")
        XCTAssertFalse(ca.caPEM.contains("PRIVATE KEY"), "the CA file carries only the certificate")
    }

    func testLeafIsSignedByTheCAAndCoversTheHost() throws {
        let local = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com"])
        let ca = try Certificate(pemEncoded: local.caPEM)
        let leaf = try Certificate(pemEncoded: local.leafPEM)

        XCTAssertTrue(ca.publicKey.isValidSignature(leaf.signature, for: leaf))
        XCTAssertEqual(leaf.dnsNames, ["api.anthropic.com"])
        XCTAssertEqual(leaf.issuer, ca.subject)
    }

    func testAnExistingChainIsReused() throws {
        let first = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com"])
        let second = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com"])
        XCTAssertEqual(first.leafPEM, second.leafPEM, "a usable chain is not reminted on every start")
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testAChainAboutToExpireIsReminted() throws {
        let first = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com"])
        // Ask as of a date inside the renewal window: an expired leaf reused forever would only ever
        // fail the handshake, with nothing in the app to say why.
        let late = Date().addingTimeInterval(LocalCA.leafLifetime - LocalCA.renewWithin / 2)
        let second = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com"], now: late)
        XCTAssertNotEqual(first.leafPEM, second.leafPEM)
    }

    func testAChainThatMissesAHostIsReminted() throws {
        let first = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com"])
        let second = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com", "example.invalid"])
        XCTAssertNotEqual(first.leafPEM, second.leafPEM)
        XCTAssertEqual(Set(try Certificate(pemEncoded: second.leafPEM).dnsNames), ["api.anthropic.com", "example.invalid"])
    }

    func testDiscardForcesAFreshChain() throws {
        let first = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com"])
        LocalCA.discard(in: directory)
        let second = try LocalCA.ensure(in: directory, hosts: ["api.anthropic.com"])
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }
}
