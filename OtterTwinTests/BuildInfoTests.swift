import XCTest
@testable import OtterTwin

final class BuildInfoTests: XCTestCase {
    func testReadsSHAAndDateFromInfoDictionary() {
        let info = BuildInfo(infoDictionary: ["OTGitSHA": "1a2b3c4", "OTBuildDate": "2026-10-08 12:00 UTC"])

        XCTAssertEqual(info.gitSHA, "1a2b3c4")
        XCTAssertEqual(info.buildDate, "2026-10-08 12:00 UTC")
        XCTAssertEqual(info.summary, "1a2b3c4 · 2026-10-08 12:00 UTC")
    }

    func testMissingValuesAreUnknown() {
        let info = BuildInfo(infoDictionary: [:])

        XCTAssertEqual(info.gitSHA, BuildInfo.unknown)
        XCTAssertEqual(info.buildDate, BuildInfo.unknown)
    }

    func testEmptyOrUnexpandedValuesAreUnknown() {
        let info = BuildInfo(infoDictionary: ["OTGitSHA": "  ", "OTBuildDate": "$(OTTERTWIN_BUILD_DATE)"])

        XCTAssertEqual(info.gitSHA, BuildInfo.unknown)
        XCTAssertEqual(info.buildDate, BuildInfo.unknown)
    }
}
