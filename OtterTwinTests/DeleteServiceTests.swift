import XCTest
@testable import OtterTwin

final class DeleteServiceTests: XCTestCase {
    let fm = FileManager.default

    private func makeService() -> FileOperationService {
        FileOperationService(settings: SettingsService())
    }

    // MARK: - Trash

    func testTrashSuccess() async throws {
        let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "hello".data(using: .utf8)!.write(to: file)

        let service = makeService()
        let result = await service.deleteItems(
            urls: [file],
            mode: .trash,
            provider: LocalProvider()
        )

        XCTAssertEqual(result.succeededURLs.count, 1)
        XCTAssertTrue(result.failedURLs.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: file.path),
                       "File should no longer exist at original path after trash")
    }

    // MARK: - Permanent delete

    func testPermanentDeleteSuccess() async throws {
        let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "data".data(using: .utf8)!.write(to: file)

        let service = makeService()
        let result = await service.deleteItems(
            urls: [file],
            mode: .permanent,
            provider: LocalProvider()
        )

        XCTAssertEqual(result.succeededURLs.count, 1)
        XCTAssertTrue(result.failedURLs.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
    }

    // MARK: - Partial failure

    func testPartialFailure() async throws {
        let existing = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "x".data(using: .utf8)!.write(to: existing)
        defer { try? fm.removeItem(at: existing) }

        let missing = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-nonexistent")

        let service = makeService()
        let result = await service.deleteItems(
            urls: [existing, missing],
            mode: .permanent,
            provider: LocalProvider()
        )

        XCTAssertEqual(result.succeededURLs.count, 1)
        XCTAssertEqual(result.failedURLs.count, 1)
        XCTAssertEqual(result.failedURLs.first?.url, missing)
        XCTAssertTrue(result.hasFailures)
    }

    // MARK: - Provider failure (SMBProvider.trash throws)

    func testProviderTrashFailureCollected() async throws {
        let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "y".data(using: .utf8)!.write(to: file)
        defer { try? fm.removeItem(at: file) }

        // SMBProvider.trash() always throws TrashNotSupportedError
        let provider = SMBProvider(connection: ConnectionInfo(host: "fake", share: "s", username: "u"))

        let service = makeService()
        let result = await service.deleteItems(urls: [file], mode: .trash, provider: provider)

        XCTAssertEqual(result.failedURLs.count, 1)
        XCTAssertTrue(result.failedURLs.first?.error is TrashNotSupportedError)
        XCTAssertTrue(result.hasFailures)
        // File still exists because the operation failed
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }
}
