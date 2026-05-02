import XCTest

final class SettingsUITests: OtterTwinUITestCase {
    func testSettingsButtonOpensWindow() {
        XCTAssertTrue(app.buttons["toolbar.settings"].waitForExistence(timeout: 5))
        app.buttons["toolbar.settings"].click()

        XCTAssertTrue(app.checkBoxes["settings.checksumEnabled"].waitForExistence(timeout: 5))
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

        if toggle.value as? Int == 1 {
            toggle.click()
            let disableButton = app.buttons["Disable Verification"]
            if disableButton.waitForExistence(timeout: 3) {
                disableButton.click()
            }
        }

        let algPicker = app.popUpButtons["settings.algorithm"]
        if algPicker.waitForExistence(timeout: 3) {
            XCTAssertFalse(algPicker.isEnabled)
        }
    }
}
