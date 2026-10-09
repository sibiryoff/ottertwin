import XCTest
import Darwin

/// #6: pressing Cancel in the progress sheet stops the running copy, the sheet
/// reports "Cancelled" and no destination file (final or partial) is left.
///
/// The source is a named pipe (FIFO) nobody writes to, so the copy deterministically
/// stays in progress (blocked reading) until Cancel is pressed — no timing races
/// with a fast disk. Both panels start in a disposable temp folder
/// (OTTERTWIN_UITEST_START_DIR), never the real home folder.
final class CancelOperationUITests: OtterTwinUITestCase {
    private var tempDir: URL!
    private var destinationDir: URL!

    override func configure(_ app: XCUIApplication) {
        let fm = FileManager.default
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("CancelOperationUITests-\(UUID().uuidString)", isDirectory: true)
        destinationDir = tempDir.appendingPathComponent("dest", isDirectory: true)
        do {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            let fifo = tempDir.appendingPathComponent("never-ending.fifo")
            guard mkfifo(fifo.path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            XCTFail("Could not create fixture: \(error)")
        }
        app.launchEnvironment["OTTERTWIN_UITEST_START_DIR"] = tempDir.path
    }

    override func tearDown() {
        super.tearDown()  // terminates the app, which also ends its blocked read of the FIFO
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }  // best-effort fixture cleanup
    }

    private func destinationEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: destinationDir.path)) ?? ["<unreadable>"]
    }

    func testCancelStopsTheCopyReportsCancelledAndLeavesNoDestinationFile() throws {
        // Right panel: open the empty "dest" folder (directories are listed first).
        let right = app.tables["fileTable.right"]
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        waitForRows(in: right)
        let destRow = right.tableRows.element(boundBy: 0)
        guard destRow.staticTexts.matching(NSPredicate(format: "value CONTAINS 'dest' OR label CONTAINS 'dest'"))
                .firstMatch.waitForExistence(timeout: 5) else {
            XCTFail("Right panel is not showing the temp fixture folder")
            return
        }
        destRow.click()
        right.typeKey(.return, modifierFlags: [])
        let emptied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: right.tableRows)
        wait(for: [emptied], timeout: 5)

        // Left panel: select the FIFO and copy it into "dest".
        let left = app.tables["fileTable.left"]
        waitForRows(in: left)
        let fifoName = NSPredicate(format: "value CONTAINS 'never-ending.fifo' OR label CONTAINS 'never-ending.fifo'")
        let fifoCell = left.staticTexts.matching(fifoName).firstMatch
        guard fifoCell.waitForExistence(timeout: 5), left.tableRows.count == 2 else {
            XCTFail("Left panel is not showing the temp fixture folder; refusing to copy")
            return
        }
        fifoCell.click()
        app.buttons["toolbar.copy"].click()

        // The copy is running: Cancel is offered and a partial file exists.
        let cancel = app.buttons["progress.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "progress sheet with Cancel")
        let partialAppeared = expectation(for: NSPredicate { _, _ in
            self.destinationEntries().contains { $0.hasSuffix(".part") }
        }, evaluatedWith: NSNull())
        wait(for: [partialAppeared], timeout: 5)

        cancel.click()

        XCTAssertTrue(app.descendants(matching: .any)["progress.cancelled"].waitForExistence(timeout: 10),
                      "the sheet reports the operation as cancelled")
        let close = app.buttons["progress.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the sheet stays open with a Close button")
        XCTAssertEqual(destinationEntries(), [], "no destination file and no partial file left")

        close.click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        wait(for: [closed], timeout: 5)
        XCTAssertEqual(destinationEntries(), [])
    }
}
