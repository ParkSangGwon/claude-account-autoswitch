import XCTest
@testable import AutoSwitchCore

final class ReleaseVersionTests: XCTestCase {
    func testLaterReleasesCompareGreater() {
        XCTAssertTrue(ReleaseVersion.isNewer("0.1.3", than: "0.1.2"))
        XCTAssertTrue(ReleaseVersion.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(ReleaseVersion.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(ReleaseVersion.isNewer("0.1.10", than: "0.1.9"), "components are numbers, not text")
        XCTAssertTrue(ReleaseVersion.isNewer("0.2", than: "0.1.9"))
        XCTAssertTrue(ReleaseVersion.isNewer("v0.1.3", than: "0.1.2"), "the tag keeps its v")
    }

    func testSameOrOlderReleasesDoNot() {
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.2", than: "0.1.2"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.1", than: "0.1.2"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1", than: "0.1.0"), "a missing component reads as zero")
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.2", than: "0.1.2.1"))
    }

    func testSomethingThatIsNotAVersionAnswersNo() {
        XCTAssertFalse(ReleaseVersion.isNewer("nightly", than: "0.1.2"))
        XCTAssertFalse(ReleaseVersion.isNewer("", than: "0.1.2"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.3", than: ""))
        XCTAssertFalse(ReleaseVersion.isNewer("0.x.3", than: "0.1.2"))
    }

    /// The dev build reports 0.0.0-dev; a real release must read as newer than it.
    func testAReleaseBeatsTheDevelopmentBuild() {
        XCTAssertTrue(ReleaseVersion.isNewer("0.1.2", than: "0.0.0-dev"))
    }
}
