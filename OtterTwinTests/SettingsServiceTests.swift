import XCTest
@testable import OtterTwin

final class SettingsServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearSettingsDefaults()
    }

    override func tearDown() {
        clearSettingsDefaults()
        super.tearDown()
    }

    func testChecksumCannotBeDisabledWithoutConfirmation() {
        let settings = SettingsService()

        settings.setChecksumEnabled(false)

        XCTAssertTrue(settings.checksumEnabled)
    }

    func testChecksumCanBeDisabledWithConfirmation() {
        let settings = SettingsService()

        settings.setChecksumEnabled(false, userConfirmedDisable: true)

        XCTAssertFalse(settings.checksumEnabled)
    }

    func testUnacknowledgedUserDefaultsChecksumDisableIsIgnored() {
        UserDefaults.standard.set(false, forKey: "checksumEnabled")
        UserDefaults.standard.set(false, forKey: "checksumDisableAcknowledged")

        let settings = SettingsService()

        XCTAssertTrue(settings.checksumEnabled)
    }

    func testChunkSizeIsClamped() {
        let settings = SettingsService()

        settings.setChunkSizeBytes(Int.max)

        XCTAssertEqual(settings.chunkSizeBytes, SettingsService.maximumChunkSizeBytes)
    }

    private func clearSettingsDefaults() {
        UserDefaults.standard.removeObject(forKey: "checksumEnabled")
        UserDefaults.standard.removeObject(forKey: "checksumAlgorithm")
        UserDefaults.standard.removeObject(forKey: "chunkSizeBytes")
        UserDefaults.standard.removeObject(forKey: "checksumDisableAcknowledged")
    }
}
