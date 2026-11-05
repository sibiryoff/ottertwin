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

    /// #57: settings changed in a UI test live only in the UI-test defaults
    /// suite. Turning verification off survives a relaunch that keeps the suite,
    /// and a fresh launch starts with verification on again, which could not
    /// happen if the choice (and its acknowledgement) had gone to the real domain.
    func testDisabledVerificationStaysInTheUITestSuite() {
        let toggle = openSettingsChecksumToggle()
        waitFor(toggle, value: 1, "a fresh launch starts with verification on")
        toggle.click()
        let disableButton = app.buttons["Disable Verification"]
        XCTAssertTrue(disableButton.waitForExistence(timeout: 3))
        disableButton.click()
        waitFor(toggle, value: 0, "verification is off after confirming")

        relaunch(keepingSettings: true)
        waitFor(openSettingsChecksumToggle(), value: 0, "a relaunch keeping the suite still has verification off")

        relaunch(keepingSettings: false)
        waitFor(openSettingsChecksumToggle(), value: 1, "a fresh launch has verification on again")
    }

    private func openSettingsChecksumToggle() -> XCUIElement {
        let settingsButton = app.buttons["toolbar.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()
        let toggle = app.checkBoxes["settings.checksumEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        return toggle
    }

    private func waitFor(_ toggle: XCUIElement, value: Int, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let matches = NSPredicate(format: "value == %d", value)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: matches, object: toggle)],
                                      timeout: 5)
        XCTAssertEqual(result, .completed, message, file: file, line: line)
    }
}
