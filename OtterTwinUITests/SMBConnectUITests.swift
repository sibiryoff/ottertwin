import XCTest

final class SMBConnectUITests: XCTestCase {
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

    private func openSMBDialog() {
        let smbButton = app.buttons["panel.left.smb"]
        XCTAssertTrue(smbButton.waitForExistence(timeout: 5))
        smbButton.click()
        XCTAssertTrue(app.buttons["smb.connect"].waitForExistence(timeout: 3))
    }

    func testSMBDialogOpens() {
        openSMBDialog()
        XCTAssertTrue(app.buttons["smb.connect"].exists)
        XCTAssertTrue(app.buttons["smb.cancel"].exists)
    }

    func testConnectButtonDisabledWithEmptyFields() {
        openSMBDialog()
        XCTAssertFalse(app.buttons["smb.connect"].isEnabled)
    }

    func testConnectButtonDisabledWithOnlyHost() {
        openSMBDialog()

        app.textFields["smb.host"].click()
        app.textFields["smb.host"].typeText("myserver")

        // Share is still empty, so Connect should remain disabled
        XCTAssertFalse(app.buttons["smb.connect"].isEnabled)
    }

    func testConnectButtonEnabledWithHostAndShare() {
        openSMBDialog()

        app.textFields["smb.host"].click()
        app.textFields["smb.host"].typeText("myserver")

        app.textFields["smb.share"].click()
        app.textFields["smb.share"].typeText("myshare")

        XCTAssertTrue(app.buttons["smb.connect"].isEnabled)
    }

    func testCancelDismissesDialog() {
        openSMBDialog()
        app.buttons["smb.cancel"].click()

        let dismissed = NSPredicate(format: "exists == false")
        let cancelButton = app.buttons["smb.cancel"]
        let expectation = XCTNSPredicateExpectation(predicate: dismissed, object: cancelButton)
        wait(for: [expectation], timeout: 3)
    }

    func testAllFormFieldsPresent() {
        openSMBDialog()
        XCTAssertTrue(app.textFields["smb.host"].exists)
        XCTAssertTrue(app.textFields["smb.share"].exists)
        XCTAssertTrue(app.textFields["smb.username"].exists)
        XCTAssertTrue(app.secureTextFields["smb.password"].exists)
    }
}
