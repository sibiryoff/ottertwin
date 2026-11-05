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

    /// #57: turning verification off is stored in this test's own defaults suite,
    /// never in the app's real preferences domain (which this test does not read).
    func testDisablingVerificationIsStoredInTheTestDefaultsSuite() {
        app.buttons["toolbar.settings"].click()

        let toggle = app.checkBoxes["settings.checksumEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // A fresh suite starts with verification on.
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        let disableButton = app.buttons["Disable Verification"]
        XCTAssertTrue(disableButton.waitForExistence(timeout: 3))
        disableButton.click()

        let suite = defaultsSuiteName!
        let stored = NSPredicate { _, _ in
            // The app writes through cfprefsd; re-read the suite on every poll.
            CFPreferencesAppSynchronize(suite as CFString)
            return UserDefaults(suiteName: suite)?.object(forKey: "checksumEnabled") as? Bool == false
        }
        wait(for: [XCTNSPredicateExpectation(predicate: stored, object: nil)], timeout: 10)
    }
}
