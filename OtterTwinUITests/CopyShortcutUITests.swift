import XCTest

/// #25: typing an unmodified `c` with a selection must not start a copy.
///
/// Runs in the base class's temp fixture folder (#44): if `c` did start a copy,
/// it would only ever act on fixture files, and the tree comparison would show it.
final class CopyShortcutUITests: OtterTwinUITestCase {
    func testTypingCWithSelectionDoesNotStartCopy() throws {
        let table = app.tables["fileTable.left"]
        guard assertShowsFixture(table) else { return }
        let before = try fixtureTreeContents()
        XCTAssertFalse(before.isEmpty, "fixture tree was captured")

        // Select a fixture file; Copy becomes available, so a `c` shortcut would fire.
        let row = table.tableRows.element(boundBy: 1)
        row.click()
        XCTAssertTrue(row.isSelected, "a fixture row is selected")
        XCTAssertTrue(app.buttons["toolbar.copy"].isEnabled, "Copy is enabled with a selection")

        table.typeKey("c", modifierFlags: [])

        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 3), "typing c must not show a progress sheet")
        for id in ["progress.cancel", "progress.close", "progress.done"] {
            XCTAssertFalse(app.descendants(matching: .any)[id].exists, "no copy progress UI (\(id))")
        }
        XCTAssertEqual(try fixtureTreeContents(), before, "the fixture tree is unchanged")
    }
}
