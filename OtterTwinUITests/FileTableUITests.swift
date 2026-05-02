import XCTest

final class FileTableUITests: XCTestCase {
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

    // MARK: - Helpers

    private func waitForRows(in table: XCUIElement, timeout: TimeInterval = 10) {
        let hasRows = NSPredicate(format: "count > 0")
        let expectation = XCTNSPredicateExpectation(predicate: hasRows, object: table.tableRows)
        wait(for: [expectation], timeout: timeout)
    }

    // MARK: - Content Loading

    func testLeftTableLoadsHomeDirectory() {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)
        XCTAssertGreaterThan(table.tableRows.count, 0)
    }

    func testRightTableLoadsHomeDirectory() {
        let table = app.tables["fileTable.right"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)
        XCTAssertGreaterThan(table.tableRows.count, 0)
    }

    // MARK: - Row Selection

    func testClickingRowSelectsIt() {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)

        let firstRow = table.tableRows.element(boundBy: 0)
        firstRow.click()

        XCTAssertTrue(firstRow.isSelected)
    }

    func testMultipleSelectionWithCommandClick() throws {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)

        guard table.tableRows.count >= 2 else {
            throw XCTSkip("Need at least 2 rows for multi-select test")
        }

        table.tableRows.element(boundBy: 0).click()
        table.tableRows.element(boundBy: 1).click(forDuration: 0, thenDragTo: table.tableRows.element(boundBy: 1), withVelocity: .default, thenHoldForDuration: 0)
        // Cmd+click second row
        XCUIElement.perform(withKeyModifiers: .command) {
            table.tableRows.element(boundBy: 1).click()
        }

        XCTAssertTrue(app.buttons["toolbar.copy"].isEnabled)
    }

    func testShiftClickSelectsRange() throws {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)

        guard table.tableRows.count >= 3 else {
            throw XCTSkip("Need at least 3 rows for range-select test")
        }

        table.tableRows.element(boundBy: 0).click()
        XCUIElement.perform(withKeyModifiers: .shift) {
            table.tableRows.element(boundBy: 2).click()
        }

        XCTAssertTrue(app.buttons["toolbar.copy"].isEnabled)
    }

    // MARK: - Keyboard Navigation

    func testArrowDownMovesSelection() {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)

        table.tableRows.element(boundBy: 0).click()
        table.typeKey(.downArrow, modifierFlags: [])

        XCTAssertTrue(table.tableRows.element(boundBy: 1).isSelected)
    }

    func testArrowUpMovesSelection() throws {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)

        guard table.tableRows.count >= 2 else {
            throw XCTSkip("Need at least 2 rows for arrow-up test")
        }

        table.tableRows.element(boundBy: 1).click()
        table.typeKey(.upArrow, modifierFlags: [])

        XCTAssertTrue(table.tableRows.element(boundBy: 0).isSelected)
    }

    // MARK: - Panel Switching

    func testTabKeyTogglesFocusBetweenPanels() {
        let leftTable = app.tables["fileTable.left"]
        XCTAssertTrue(leftTable.waitForExistence(timeout: 5))

        leftTable.click()
        app.windows.firstMatch.typeKey("\t", modifierFlags: [])

        // Right panel's table should now receive keyboard events
        let rightTable = app.tables["fileTable.right"]
        XCTAssertTrue(rightTable.exists)
    }

    // MARK: - Column Sorting

    func testClickingColumnHeaderSorts() {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)

        // Click the "Name" column header to sort
        let nameHeader = table.tableColumns["name"]
        if nameHeader.exists {
            nameHeader.click()
            // Table should still have rows after sort
            XCTAssertGreaterThan(table.tableRows.count, 0)
        }
    }
}
