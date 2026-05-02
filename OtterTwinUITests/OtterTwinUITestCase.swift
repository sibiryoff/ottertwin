import XCTest

class OtterTwinUITestCase: XCTestCase {
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

    func waitForRows(in table: XCUIElement, timeout: TimeInterval = 10) {
        let hasRows = NSPredicate(format: "count > 0")
        let expectation = XCTNSPredicateExpectation(predicate: hasRows, object: table.tableRows)
        wait(for: [expectation], timeout: timeout)
    }
}
