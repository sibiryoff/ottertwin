import XCTest

final class AppLaunchTests: XCTestCase {
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

    func testAppLaunchesWithoutCrash() {
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testToolbarButtonsPresent() {
        XCTAssertTrue(app.buttons["toolbar.copy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toolbar.move"].exists)
        XCTAssertTrue(app.buttons["toolbar.delete"].exists)
        XCTAssertTrue(app.buttons["toolbar.refresh"].exists)
        XCTAssertTrue(app.buttons["toolbar.settings"].exists)
    }

    func testBothFilePanelsPresent() {
        XCTAssertTrue(app.tables["fileTable.left"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tables["fileTable.right"].waitForExistence(timeout: 5))
    }

    func testFilePanelsLoadContent() {
        let leftTable = app.tables["fileTable.left"]
        XCTAssertTrue(leftTable.waitForExistence(timeout: 5))

        let hasRows = NSPredicate(format: "count > 0")
        let expectation = XCTNSPredicateExpectation(predicate: hasRows, object: leftTable.tableRows)
        wait(for: [expectation], timeout: 10)
    }
}
