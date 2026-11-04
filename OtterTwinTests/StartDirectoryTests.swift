import XCTest
@testable import OtterTwin

/// #44: UI tests start both panels in a disposable temp folder through the
/// `OTTERTWIN_UITEST_START_DIR` launch-environment hook. The hook is honoured
/// only when set (in Debug builds); a normal launch opens the home folder.
final class StartDirectoryTests: XCTestCase {
    private let key = AppState.startDirectoryEnvironmentKey
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func testEnvironmentKeyMatchesTheUITestHook() {
        XCTAssertEqual(key, "OTTERTWIN_UITEST_START_DIR")
    }

    func testUnsetVariableOpensHome() {
        let start = AppState.startDirectory(environment: ["HOME": "/elsewhere", "PATH": "/usr/bin"], home: home)
        XCTAssertEqual(start, home)
    }

    func testEmptyVariableOpensHome() {
        XCTAssertEqual(AppState.startDirectory(environment: [key: ""], home: home), home)
    }

    func testDefaultInitWithoutTheVariableOpensTheRealHomeFolder() {
        // Only compares paths; nothing in the home folder is listed or touched.
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let state = AppState(environment: [:])
        XCTAssertEqual(state.leftPath, realHome)
        XCTAssertEqual(state.rightPath, realHome)

        // The unit-test process is launched without the hook, like a normal app launch.
        XCTAssertNil(ProcessInfo.processInfo.environment[key])
        let launched = AppState()
        XCTAssertEqual(launched.leftPath, realHome)
        XCTAssertEqual(launched.rightPath, realHome)
    }

    #if DEBUG
    func testSetVariableIsUsedForBothPanels() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(environment: [key: dir.path], home: home)

        XCTAssertEqual(state.leftPath.path, dir.path)
        XCTAssertEqual(state.rightPath.path, dir.path)
        XCTAssertTrue(state.leftPath.hasDirectoryPath)
        XCTAssertNotEqual(state.leftPath, home)
    }

    func testMissingFolderNeverFallsBackToHome() {
        // The folder is never created: the hook must still point at it, so a
        // broken UI-test fixture cannot end up acting on the real home folder.
        let missing = "/nonexistent-\(UUID().uuidString)/fixture"
        let start = AppState.startDirectory(environment: [key: missing], home: home)
        XCTAssertEqual(start.path, missing)
        XCTAssertNotEqual(start, home)
    }
    #else
    func testVariableIsIgnoredInReleaseBuilds() {
        XCTAssertEqual(AppState.startDirectory(environment: [key: "/tmp/fixture"], home: home), home)
    }
    #endif
}
