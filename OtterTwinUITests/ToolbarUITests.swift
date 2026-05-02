import XCTest

final class ToolbarUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - Initial State (no selection)

    func testCopyButtonDisabledWithoutSelection() {
        XCTAssertTrue(app.buttons["toolbar.copy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toolbar.copy"].isEnabled)
    }

    func testMoveButtonDisabledWithoutSelection() {
        XCTAssertTrue(app.buttons["toolbar.move"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toolbar.move"].isEnabled)
    }

    func testDeleteButtonDisabledWithoutSelection() {
        XCTAssertTrue(app.buttons["toolbar.delete"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toolbar.delete"].isEnabled)
    }

    func testRefreshButtonIsEnabled() {
        XCTAssertTrue(app.buttons["toolbar.refresh"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toolbar.refresh"].isEnabled)
    }

    func testSettingsButtonIsEnabled() {
        XCTAssertTrue(app.buttons["toolbar.settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toolbar.settings"].isEnabled)
    }

    // MARK: - With Selection

    func testOperationButtonsEnabledAfterSelection() {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))

        let hasRows = NSPredicate(format: "count > 0")
        let rowsLoaded = XCTNSPredicateExpectation(predicate: hasRows, object: table.tableRows)
        wait(for: [rowsLoaded], timeout: 10)

        table.tableRows.element(boundBy: 0).click()

        XCTAssertTrue(app.buttons["toolbar.copy"].isEnabled)
        XCTAssertTrue(app.buttons["toolbar.move"].isEnabled)
        XCTAssertTrue(app.buttons["toolbar.delete"].isEnabled)
    }

    // MARK: - Keyboard Shortcut

    func testRefreshKeyboardShortcutCmdR() {
        XCTAssertTrue(app.buttons["toolbar.refresh"].waitForExistence(timeout: 5))
        app.windows.firstMatch.typeKey("r", modifierFlags: .command)
        // After refresh, the table should still be present (no crash)
        XCTAssertTrue(app.tables["fileTable.left"].waitForExistence(timeout: 5))
    }
}
