import XCTest

/// #5: clicking Delete always asks first; Cancel leaves the file untouched.
/// Both panels start in a disposable temp folder (OTTERTWIN_UITEST_START_DIR),
/// never the real home folder.
final class DeleteConfirmationUITests: OtterTwinUITestCase {
    private var tempDir: URL!
    private var victim: URL!

    override func configure(_ app: XCUIApplication) {
        let fm = FileManager.default
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("DeleteConfirmationUITests-\(UUID().uuidString)", isDirectory: true)
        victim = tempDir.appendingPathComponent("victim.txt")
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try Data("keep me".utf8).write(to: victim)
        } catch {
            XCTFail("Could not create fixture: \(error)")
        }
        app.launchEnvironment["OTTERTWIN_UITEST_START_DIR"] = tempDir.path
    }

    override func tearDown() {
        super.tearDown()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }  // best-effort fixture cleanup
    }

    func testDeleteAsksForConfirmationAndCancelKeepsFile() throws {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)

        // Guard: only proceed when the panel really shows the temp fixture.
        let name = NSPredicate(format: "label CONTAINS 'victim.txt' OR value CONTAINS 'victim.txt'")
        let nameCell = table.staticTexts.matching(name).firstMatch
        guard nameCell.waitForExistence(timeout: 5), table.tableRows.count == 1 else {
            XCTFail("Left panel is not showing the temp fixture folder; refusing to click Delete")
            return
        }
        table.tableRows.element(boundBy: 0).click()
        XCTAssertTrue(app.buttons["toolbar.delete"].isEnabled)

        app.buttons["toolbar.delete"].click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Delete must show a confirmation sheet")
        XCTAssertTrue(sheet.buttons["Move to Trash"].exists, "Trash is the default action for local files")
        sheet.buttons["Cancel"].click()

        XCTAssertFalse(sheet.waitForExistence(timeout: 1), "Sheet should dismiss after Cancel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path), "Cancel must not delete anything")
    }
}
