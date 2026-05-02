import XCTest
@testable import OtterTwin

final class ConnectionInfoTests: XCTestCase {
    func testSMBURLRejectsInjectedShareAuthority() {
        let info = ConnectionInfo(host: "legit.local", share: "share@evil.com/x", username: "alice")

        XCTAssertNil(info.smbURL)
    }

    func testSMBURLUsesHostAndPercentEncodedPath() throws {
        let info = ConnectionInfo(host: "fileserver.local", share: "team_share", username: "alice")

        let url = try XCTUnwrap(info.smbURL)
        XCTAssertEqual(url.scheme, "smb")
        XCTAssertEqual(url.host(), "fileserver.local")
        XCTAssertEqual(url.path, "/team_share")
    }

    func testSMBComponentValidationRejectsEmptyAndSeparators() {
        XCTAssertFalse(ConnectionInfo.isValidSMBComponent(""))
        XCTAssertFalse(ConnectionInfo.isValidSMBComponent("share/name"))
        XCTAssertFalse(ConnectionInfo.isValidSMBComponent("share@host"))
        XCTAssertTrue(ConnectionInfo.isValidSMBComponent("share_name-01.local"))
    }
}
