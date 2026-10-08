import XCTest
@testable import OtterTwin

/// #5: `FileOperationService.deleteItems` — per-item execution, no swallowed errors.
final class DeleteServiceTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("DeleteServiceTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeService() -> FileOperationService {
        FileOperationService(settings: SettingsService())
    }

    private func makeFile(_ name: String, _ text: String = "data") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Local delete success

    func testLocalTrashSuccess() async throws {
        let unique = "OtterTwin-DeleteServiceTests-\(UUID().uuidString).txt"
        let file = try makeFile(unique, "hello")

        let result = await makeService().deleteItems(urls: [file], mode: .trash, provider: LocalProvider())

        XCTAssertEqual(result.trashedURLs, [file])
        XCTAssertTrue(result.deletedURLs.isEmpty)
        XCTAssertFalse(result.hasFailures)
        XCTAssertFalse(fm.fileExists(atPath: file.path), "File should no longer exist at original path after trash")
        // Independent check: the item is in the Trash with its content; then clean it up.
        let trashDir = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: file, create: false)
        let trashed = trashDir.appendingPathComponent(unique)
        XCTAssertTrue(fm.fileExists(atPath: trashed.path))
        if fm.fileExists(atPath: trashed.path) {
            XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "hello")
            try fm.removeItem(at: trashed)
        }
    }

    func testLocalPermanentDeleteSuccess() async throws {
        let file = try makeFile("a.txt")
        let dir = tempDir.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("inner.txt"))

        let result = await makeService().deleteItems(urls: [file, dir], mode: .permanent, provider: LocalProvider())

        XCTAssertEqual(result.deletedURLs, [file, dir])
        XCTAssertTrue(result.trashedURLs.isEmpty)
        XCTAssertFalse(result.hasFailures)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
    }

    // MARK: - Partial failure

    func testPartialFailureContinuesAndRecordsError() async throws {
        let first = try makeFile("first.txt")
        let missing = tempDir.appendingPathComponent("missing.txt")
        let last = try makeFile("last.txt")

        let result = await makeService().deleteItems(
            urls: [first, missing, last], mode: .permanent, provider: LocalProvider()
        )

        XCTAssertEqual(result.deletedURLs, [first, last], "Items after a failure are still processed")
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.url, missing)
        XCTAssertEqual(result.failures.first?.mode, .permanent)
        XCTAssertFalse(result.failures.first?.error.localizedDescription.isEmpty ?? true)
        XCTAssertTrue(result.hasFailures)
    }

    // MARK: - Provider failure

    func testSMBProviderTrashFailureIsCollected() async throws {
        let file = try makeFile("y.txt")
        // SMBProvider cannot Trash; it must throw rather than silently delete.
        let provider = SMBProvider(connection: ConnectionInfo(host: "fake", share: "s", username: "u"))
        XCTAssertFalse(provider.supportsTrash)

        let result = await makeService().deleteItems(urls: [file], mode: .trash, provider: provider)

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures.first?.error is TrashNotSupportedError)
        XCTAssertTrue(fm.fileExists(atPath: file.path), "File still exists because the operation failed")
    }

    func testInjectedProviderFailureIsCollected() async throws {
        let ok = try makeFile("ok.txt")
        let bad = try makeFile("bad.txt")
        let provider = FaultInjectingDeleteProvider(fakeTrash: tempDir.appendingPathComponent("FakeTrash"))
        provider.deleteFaults[bad] = InjectedFault(message: "I/O error")

        let result = await makeService().deleteItems(urls: [ok, bad], mode: .permanent, provider: provider)

        XCTAssertEqual(result.deletedURLs, [ok])
        XCTAssertEqual(result.failures.map(\.url), [bad])
        XCTAssertEqual(result.failures.first?.error as? InjectedFault, InjectedFault(message: "I/O error"))
        XCTAssertFalse(fm.fileExists(atPath: ok.path))
        XCTAssertTrue(fm.fileExists(atPath: bad.path))
    }

    // MARK: - DeleteResult

    func testApplyingRetryReplacesFailures() {
        let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b"), c = URL(fileURLWithPath: "/tmp/c")
        let first = DeleteResult(
            trashedURLs: [a],
            failures: [DeleteFailure(url: b, mode: .trash, error: InjectedFault(message: "x")),
                       DeleteFailure(url: c, mode: .trash, error: InjectedFault(message: "y"))]
        )
        let retry = DeleteResult(
            deletedURLs: [b],
            failures: [DeleteFailure(url: c, mode: .permanent, error: InjectedFault(message: "z"))]
        )

        let merged = first.applyingRetry(retry)

        XCTAssertEqual(merged.trashedURLs, [a])
        XCTAssertEqual(merged.deletedURLs, [b])
        XCTAssertEqual(merged.failures.map(\.url), [c])
        XCTAssertEqual(merged.failures.first?.mode, .permanent)
        XCTAssertEqual(merged.succeededURLs, [a, b])
    }
}
