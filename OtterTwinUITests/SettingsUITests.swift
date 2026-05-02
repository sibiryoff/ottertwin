import XCTest

final class SettingsUITests: XCTestCase {
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

    func testSettingsButtonOpensWindow() {
        XCTAssertTrue(app.buttons["toolbar.settings"].waitForExistence(timeout: 5))
        app.buttons["toolbar.settings"].click()

        // Settings window should appear
        let settingsExists = NSPredicate(format: "exists == true")
        let toggle = app.checkBoxes["settings.checksumEnabled"]
        let expectation = XCTNSPredicateExpectation(predicate: settingsExists, object: toggle)
        wait(for: [expectation], timeout: 5)
    }

    func testChecksumToggleIsPresent() {
        app.buttons["toolbar.settings"].click()
        XCTAssertTrue(app.checkBoxes["settings.checksumEnabled"].waitForExistence(timeout: 5))
    }

    func testChunkSizeFieldIsPresent() {
        app.buttons["toolbar.settings"].click()
        XCTAssertTrue(app.textFields["settings.chunkSize"].waitForExistence(timeout: 5))
    }

    func testAlgorithmPickerIsPresent() {
        app.buttons["toolbar.settings"].click()
        XCTAssertTrue(app.popUpButtons["settings.algorithm"].waitForExistence(timeout: 5))
    }

    func testToggleChecksumDisablesAlgorithmPicker() {
        app.buttons["toolbar.settings"].click()

        let toggle = app.checkBoxes["settings.checksumEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        // If checksum is currently enabled, disable it
        if toggle.value as? Int == 1 {
            toggle.click()
        }

        // Algorithm picker should be disabled when checksum is off
        let algPicker = app.popUpButtons["settings.algorithm"]
        if algPicker.waitForExistence(timeout: 3) {
            XCTAssertFalse(algPicker.isEnabled)
        }
    }
}
