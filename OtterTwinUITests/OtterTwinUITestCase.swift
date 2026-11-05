import XCTest

/// Base class for all UI tests.
///
/// Every test launches the app with both panels in a unique, disposable temp
/// folder (`fixtureDirectory`, passed via `OTTERTWIN_UITEST_START_DIR`), never in
/// the real home folder (#44, `docs/agent-workflow.md` §5). The folder holds
/// `fixtureEntries` and is removed in `tearDown`. A subclass may point the app
/// at a folder inside `fixtureDirectory` in `configure(_:)` (removed with it);
/// any other start folder is refused before launch (#59).
///
/// Every launch also stores the app's settings in the UI-test defaults suite
/// (`UITestDefaultsHook.suiteName`, passed via `OTTERTWIN_UITEST_DEFAULTS_SUITE`),
/// never in the app's real preferences domain (#57). The app empties that suite
/// itself at launch, because this sandboxed runner cannot reach the app's
/// preferences; `relaunch(keepingSettings:)` can keep it across a relaunch.
class OtterTwinUITestCase: XCTestCase {
    static let startDirectoryEnvironmentKey = "OTTERTWIN_UITEST_START_DIR"

    /// Top-level names in `fixtureDirectory`, in the order the panel lists them
    /// (folders first, then files by name). No name starts with `c`, so typing `c`
    /// cannot type-select a row.
    static let fixtureEntries = ["Folder A", "alpha.txt", "beta.txt", "gamma.txt"]

    var app: XCUIApplication!
    /// The temp folder both panels start in, unless `configure(_:)` picks a
    /// folder inside it.
    private(set) var fixtureDirectory: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtterTwinUITests-\(UUID().uuidString)", isDirectory: true)
        fixtureDirectory = dir
        do {
            try OtterTwinUITestCase.createFixtures(in: dir)
        } catch {
            // continueAfterFailure is false: the test stops here, before any launch.
            XCTFail("Could not create the UI-test fixture folder \(dir.path): \(error)")
            return
        }

        app = XCUIApplication()
        app.launchEnvironment[Self.startDirectoryEnvironmentKey] = dir.path
        app.launchEnvironment[UITestDefaultsHook.suiteEnvironmentKey] = UITestDefaultsHook.suiteName
        configure(app)

        launchCheckedApp()
    }

    /// Terminates and relaunches the app with the same environment. With
    /// `keepingSettings` the app keeps what the previous launch stored in the
    /// UI-test suite; otherwise it starts from the default settings again.
    /// The relaunch goes through the same checks as the first launch.
    func relaunch(keepingSettings: Bool) {
        app.terminate()
        if keepingSettings {
            app.launchEnvironment[UITestDefaultsHook.keepEnvironmentKey] = "1"
        } else {
            app.launchEnvironment.removeValue(forKey: UITestDefaultsHook.keepEnvironmentKey)
        }
        launchCheckedApp()
    }

    /// Launches `app`, or fails the test without launching if the environment
    /// would let the app touch the real home folder or its real settings.
    /// `setUp` and `relaunch(keepingSettings:)` both launch only through here.
    private func launchCheckedApp() {
        // Refuse unless the start folder is `fixtureDirectory` or inside it (#59):
        // a removed or blanked value would make the app open the real home folder.
        // This runner is sandboxed, so `homeDirectoryForCurrentUser` is its
        // container; the guard compares against the real home folder instead.
        let start = app.launchEnvironment[Self.startDirectoryEnvironmentKey] ?? ""
        guard let dir = fixtureDirectory,
              let home = UITestStartDirectoryGuard.realHomeDirectory(),
              UITestStartDirectoryGuard.isAllowed(startPath: start, disposableRoot: dir.path, home: home) else {
            XCTFail("UI tests must start inside their temp folder \(fixtureDirectory?.path ?? "<none>"), "
                    + "never the home folder (got '\(start)')")
            return
        }
        // Refuse if the defaults suite was removed or replaced: the app would
        // then read and write its real settings.
        guard app.launchEnvironment[UITestDefaultsHook.suiteEnvironmentKey] == UITestDefaultsHook.suiteName else {
            XCTFail("UI tests must use the defaults suite '\(UITestDefaultsHook.suiteName)', not the app's real settings")
            return
        }
        app.launch()
    }

    /// Override to set launch arguments/environment before the app launches.
    func configure(_ app: XCUIApplication) {}

    override func tearDown() {
        app?.terminate()
        if let dir = fixtureDirectory, FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.removeItem(at: dir)
            } catch {
                XCTFail("Could not remove the UI-test fixture folder \(dir.path): \(error)")
            }
        }
        fixtureDirectory = nil
        super.tearDown()
    }

    private static func createFixtures(in dir: URL) throws {
        let fm = FileManager.default
        let folder = dir.appendingPathComponent("Folder A", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside Folder A\n".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        try Data("alpha\n".utf8).write(to: dir.appendingPathComponent("alpha.txt"))
        try Data("beta beta\n".utf8).write(to: dir.appendingPathComponent("beta.txt"))
        try Data("gamma gamma gamma\n".utf8).write(to: dir.appendingPathComponent("gamma.txt"))
    }

    /// Every entry below `fixtureDirectory` (hidden ones included) mapped to its
    /// contents; folders map to `nil`. Compare two of these to prove nothing changed.
    func fixtureTreeContents() throws -> [String: Data?] {
        let fm = FileManager.default
        var contents: [String: Data?] = [:]
        for relative in try fm.subpathsOfDirectory(atPath: fixtureDirectory.path) {
            let url = fixtureDirectory.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if !fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                contents.updateValue(Data("<missing>".utf8), forKey: relative)
            } else if isDirectory.boolValue {
                contents.updateValue(nil, forKey: relative)
            } else {
                let data = try Data(contentsOf: url)
                contents.updateValue(data, forKey: relative)
            }
        }
        return contents
    }

    /// Waits until `table` lists exactly `fixtureEntries`. Returns false (and fails
    /// the test) if it shows anything else, so a test never clicks rows elsewhere.
    @discardableResult
    func assertShowsFixture(_ table: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        XCTAssertTrue(table.waitForExistence(timeout: 5), "file table exists", file: file, line: line)
        waitForRows(in: table)
        for name in Self.fixtureEntries {
            // Name cells read "📁 <name>" / "📄 <name>", hence CONTAINS.
            let cell = table.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", name, name)
            ).firstMatch
            guard cell.waitForExistence(timeout: 5) else {
                XCTFail("Panel is not showing the temp fixture folder (no '\(name)')", file: file, line: line)
                return false
            }
        }
        guard table.tableRows.count == Self.fixtureEntries.count else {
            XCTFail("Panel shows \(table.tableRows.count) rows, expected the \(Self.fixtureEntries.count) fixture entries",
                    file: file, line: line)
            return false
        }
        return true
    }

    func waitForRows(in table: XCUIElement, timeout: TimeInterval = 10) {
        let hasRows = NSPredicate(format: "count > 0")
        let expectation = XCTNSPredicateExpectation(predicate: hasRows, object: table.tableRows)
        wait(for: [expectation], timeout: timeout)
    }
}
