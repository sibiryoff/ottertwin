import XCTest
@testable import OtterTwin

/// #57: UI tests store settings in their own defaults suite through the
/// `OTTERTWIN_UITEST_DEFAULTS_SUITE` launch-environment hook. The hook is honoured
/// only when set and non-empty (in Debug builds); a normal launch uses
/// `UserDefaults.standard`.
final class SettingsDefaultsSuiteTests: XCTestCase {
    private let key = SettingsService.defaultsSuiteEnvironmentKey
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.mas.ottertwin.unittests.\(UUID().uuidString)"
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        suiteName = nil
        super.tearDown()
    }

    func testEnvironmentKeyMatchesTheUITestHook() {
        XCTAssertEqual(key, "OTTERTWIN_UITEST_DEFAULTS_SUITE")
    }

    func testUnsetVariableUsesStandardDefaults() {
        let environment = ["HOME": "/elsewhere", "PATH": "/usr/bin"]
        XCTAssertNil(SettingsService.defaultsSuiteName(environment: environment))
        XCTAssertTrue(SettingsService.resolvedDefaults(environment: environment) === UserDefaults.standard)
    }

    func testEmptyVariableUsesStandardDefaults() {
        XCTAssertNil(SettingsService.defaultsSuiteName(environment: [key: ""]))
        XCTAssertTrue(SettingsService.resolvedDefaults(environment: [key: ""]) === UserDefaults.standard)
    }

    func testDefaultLaunchWithoutTheVariableUsesStandardDefaults() {
        // The unit-test process is launched without the hook, like a normal app launch.
        XCTAssertNil(ProcessInfo.processInfo.environment[key])
        XCTAssertTrue(SettingsService.resolvedDefaults(environment: ProcessInfo.processInfo.environment)
                      === UserDefaults.standard)
    }

    #if DEBUG
    func testSetVariableNamesThatSuite() {
        XCTAssertEqual(SettingsService.defaultsSuiteName(environment: [key: suiteName]), suiteName)

        let defaults = SettingsService.resolvedDefaults(environment: [key: suiteName])
        XCTAssertFalse(defaults === UserDefaults.standard)

        defaults.set("marker", forKey: "suiteMarker")
        XCTAssertEqual(UserDefaults(suiteName: suiteName)?.string(forKey: "suiteMarker"), "marker")
        XCTAssertNil(UserDefaults.standard.object(forKey: "suiteMarker"))
    }

    func testSettingsInASuiteNeverTouchTheStandardDefaults() {
        let keys = ["checksumEnabled", "checksumAlgorithm", "chunkSizeBytes", "checksumDisableAcknowledged"]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }

        let settings = SettingsService(environment: [key: suiteName])
        XCTAssertTrue(settings.checksumEnabled, "a fresh suite starts with verification on")
        settings.setChecksumEnabled(false, userConfirmedDisable: true)
        settings.setChunkSizeBytes(4_096)

        let suite = UserDefaults(suiteName: suiteName)
        XCTAssertEqual(suite?.object(forKey: "checksumEnabled") as? Bool, false)
        XCTAssertEqual(suite?.object(forKey: "checksumDisableAcknowledged") as? Bool, true)
        XCTAssertEqual(suite?.integer(forKey: "chunkSizeBytes"), 4_096)
        let after = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        XCTAssertEqual(after, before, "the standard defaults must not change")

        // A later launch with the same suite sees the stored values; once the
        // suite is removed (UI-test tearDown) a launch starts from the defaults again.
        XCTAssertFalse(SettingsService(environment: [key: suiteName]).checksumEnabled)
        UserDefaults().removePersistentDomain(forName: suiteName)
        XCTAssertTrue(SettingsService(environment: [key: suiteName]).checksumEnabled)
    }
    #else
    func testVariableIsIgnoredInReleaseBuilds() {
        XCTAssertNil(SettingsService.defaultsSuiteName(environment: [key: suiteName]))
        XCTAssertTrue(SettingsService.resolvedDefaults(environment: [key: suiteName]) === UserDefaults.standard)
    }
    #endif
}
