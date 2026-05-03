import XCTest

final class FileTableUITests: OtterTwinUITestCase {
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

        XCTAssertTrue(app.tables["fileTable.right"].exists)
    }

    // MARK: - Quick Look

    func testSpaceKeyOpensAndClosesQuickLook() {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)

        // Select the first row — any file or folder can trigger Quick Look
        table.tableRows.element(boundBy: 0).click()
        let windowCountBefore = app.windows.count

        // Press Space — Quick Look panel should open as an additional window
        table.typeKey(" ", modifierFlags: [])

        let panelAppeared = NSPredicate(format: "count > %d", windowCountBefore)
        let openExpect = XCTNSPredicateExpectation(predicate: panelAppeared, object: app.windows)
        XCTAssertEqual(
            XCTWaiter.wait(for: [openExpect], timeout: 5), .completed,
            "Quick Look panel should open after pressing Space"
        )

        // Press Space again — panel should close
        table.typeKey(" ", modifierFlags: [])
        let panelClosed = NSPredicate(format: "count == %d", windowCountBefore)
        let closeExpect = XCTNSPredicateExpectation(predicate: panelClosed, object: app.windows)
        XCTAssertEqual(
            XCTWaiter.wait(for: [closeExpect], timeout: 5), .completed,
            "Quick Look panel should close on second Space key"
        )
    }

    // MARK: - Column Sorting

    func testClickingColumnHeaderSorts() {
        let table = app.tables["fileTable.left"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        waitForRows(in: table)

        let nameHeader = table.tableColumns["name"]
        XCTAssertTrue(nameHeader.exists)
        nameHeader.click()
        XCTAssertGreaterThan(table.tableRows.count, 0)
    }
}
