import XCTest
@testable import OtterTwin

/// #57: UI tests store settings in their own defaults suite through the
/// `OTTERTWIN_UITEST_DEFAULTS_SUITE` launch-environment hook. The hook is honoured
/// only when set and non-empty (in Debug builds); a normal launch uses
/// `UserDefaults.standard` and never resets anything.
final class SettingsDefaultsSuiteTests: XCTestCase {
    private let key = UITestDefaultsHook.suiteEnvironmentKey
    private let keepKey = UITestDefaultsHook.keepEnvironmentKey
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A unique suite below the UI-test suite, so these tests never touch the
        // suite a UI-test run uses (this unsandboxed test host can remove it).
        suiteName = "\(UITestDefaultsHook.suiteName).unittest-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        suiteName = nil
        super.tearDown()
    }

    func testHookNamesMatchTheUITestTarget() {
        XCTAssertEqual(key, "OTTERTWIN_UITEST_DEFAULTS_SUITE")
        XCTAssertEqual(keepKey, "OTTERTWIN_UITEST_KEEP_DEFAULTS")
        XCTAssertEqual(UITestDefaultsHook.suiteName, "com.mas.ottertwin.uitests")
        XCTAssertNotEqual(UITestDefaultsHook.suiteName, Bundle.main.bundleIdentifier)
    }

    func testOnlyUITestSuiteNamesAreAllowed() {
        XCTAssertTrue(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitests"))
        XCTAssertTrue(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitests.unit"))
        XCTAssertTrue(UITestDefaultsHook.isAllowedSuiteName(suiteName), "the suite these tests use")
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitests./../com.mas.ottertwin"))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitests./x"))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitests.."))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitests."))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitests.a.b"))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitests.a b"))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitests.é"))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin"))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.mas.ottertwin.uitestsX"))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName("com.apple.finder"))
        XCTAssertFalse(UITestDefaultsHook.isAllowedSuiteName(""))
    }

    func testUnsetVariableUsesStandardDefaults() {
        let environment = ["HOME": "/elsewhere", "PATH": "/usr/bin"]
        XCTAssertNil(SettingsService.defaultsSuiteName(environment: environment))
        XCTAssertFalse(SettingsService.shouldResetDefaultsSuite(environment: environment))
        XCTAssertTrue(SettingsService.resolvedDefaults(environment: environment) === UserDefaults.standard)
    }

    func testEmptyVariableUsesStandardDefaults() {
        XCTAssertNil(SettingsService.defaultsSuiteName(environment: [key: ""]))
        XCTAssertFalse(SettingsService.shouldResetDefaultsSuite(environment: [key: ""]))
        XCTAssertTrue(SettingsService.resolvedDefaults(environment: [key: ""]) === UserDefaults.standard)
    }

    func testDefaultLaunchWithoutTheVariableUsesStandardDefaults() {
        // The unit-test process is launched without the hook, like a normal app launch.
        XCTAssertNil(ProcessInfo.processInfo.environment[key])
        XCTAssertTrue(SettingsService.resolvedDefaults(environment: ProcessInfo.processInfo.environment)
                      === UserDefaults.standard)
    }

    func testDefaultLaunchNeverResetsTheStandardDefaults() {
        // A unique probe key in the standard domain must survive resolving the
        // defaults without the hook (with or without the keep flag alone).
        let probe = "SettingsDefaultsSuiteTests.probe-\(UUID().uuidString)"
        UserDefaults.standard.set("probe", forKey: probe)
        defer { UserDefaults.standard.removeObject(forKey: probe) }

        let environments: [[String: String]] = [[:], [key: ""], [keepKey: "1"], [keepKey: "0"]]
        for environment in environments {
            XCTAssertFalse(SettingsService.shouldResetDefaultsSuite(environment: environment), "\(environment)")
            _ = SettingsService.resolvedDefaults(environment: environment)
            _ = SettingsService(environment: environment)
            XCTAssertEqual(UserDefaults.standard.string(forKey: probe), "probe", "\(environment)")
        }
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

    func testLaunchWithTheSuiteResetsItUnlessKeepIsSet() {
        XCTAssertTrue(SettingsService.shouldResetDefaultsSuite(environment: [key: suiteName]))
        XCTAssertTrue(SettingsService.shouldResetDefaultsSuite(environment: [key: suiteName, keepKey: "0"]))
        XCTAssertFalse(SettingsService.shouldResetDefaultsSuite(environment: [key: suiteName, keepKey: "1"]))

        UserDefaults(suiteName: suiteName)?.set("left over", forKey: "suiteMarker")
        let kept = SettingsService.resolvedDefaults(environment: [key: suiteName, keepKey: "1"])
        XCTAssertEqual(kept.string(forKey: "suiteMarker"), "left over")

        let fresh = SettingsService.resolvedDefaults(environment: [key: suiteName])
        XCTAssertNil(fresh.string(forKey: "suiteMarker"))
        XCTAssertNil(UserDefaults(suiteName: suiteName)?.string(forKey: "suiteMarker"))
    }

    func testSettingsInASuiteNeverTouchTheStandardDefaults() {
        let keys = ["checksumEnabled", "checksumAlgorithm", "chunkSizeBytes", "checksumDisableAcknowledged"]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }

        let defaults = SettingsService.resolvedDefaults(environment: [key: suiteName])
        // Never turn verification off in the developer's real domain, even if the
        // hook regressed to `.standard`.
        guard defaults !== UserDefaults.standard else {
            XCTFail("the hook resolved to UserDefaults.standard")
            return
        }
        let settings = SettingsService(defaults: defaults)
        XCTAssertTrue(settings.checksumEnabled, "a fresh suite starts with verification on")
        settings.setChecksumEnabled(false, userConfirmedDisable: true)
        settings.setChunkSizeBytes(4_096)

        let suite = UserDefaults(suiteName: suiteName)
        XCTAssertEqual(suite?.object(forKey: "checksumEnabled") as? Bool, false)
        XCTAssertEqual(suite?.object(forKey: "checksumDisableAcknowledged") as? Bool, true)
        XCTAssertEqual(suite?.integer(forKey: "chunkSizeBytes"), 4_096)
        let after = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        XCTAssertEqual(after, before, "the standard defaults must not change")

        // A relaunch that keeps the suite sees the stored choice; a fresh
        // UI-test launch starts with verification on again.
        XCTAssertFalse(SettingsService(environment: [key: suiteName, keepKey: "1"]).checksumEnabled)
        XCTAssertTrue(SettingsService(environment: [key: suiteName]).checksumEnabled)
    }
    #else
    func testVariableIsIgnoredInReleaseBuilds() {
        XCTAssertNil(SettingsService.defaultsSuiteName(environment: [key: suiteName]))
        XCTAssertFalse(SettingsService.shouldResetDefaultsSuite(environment: [key: suiteName]))
        XCTAssertTrue(SettingsService.resolvedDefaults(environment: [key: suiteName]) === UserDefaults.standard)
    }
    #endif
}
