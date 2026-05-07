import XCTest
@testable import OtterTwin

final class FileOperationServiceTests: XCTestCase {
    let fm = FileManager.default

    private func makeSettings(checksumEnabled: Bool = true) -> SettingsService {
        let s = SettingsService()
        s.checksumEnabled = checksumEnabled
        s.chunkSizeBytes = 4096
        return s
    }

    private func tmpDir() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Happy path copy

    func testHappyPathCopy() async throws {
        let dir = try tmpDir()
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appendingPathComponent("source.bin")
        let dst = dir.appendingPathComponent("dest.bin")
        try Data(repeating: 0xCD, count: 32_768).write(to: src)

        let service = FileOperationService(settings: makeSettings())
        let provider = LocalProvider()

        var finalState: OperationState?
        for try await state in await service.copy(source: src, destination: dst, provider: provider) {
            finalState = state
        }

        guard case .complete(let result) = finalState else {
            XCTFail("Expected .complete, got \(String(describing: finalState))")
            return
        }
        guard case .verified(let srcHash, let dstHash) = result else {
            XCTFail("Expected .verified")
            return
        }
        XCTAssertEqual(srcHash, dstHash)
        XCTAssertTrue(fm.fileExists(atPath: dst.path))
    }

    // MARK: - No checksum

    func testCopyWithoutChecksum() async throws {
        let dir = try tmpDir()
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appendingPathComponent("source.bin")
        let dst = dir.appendingPathComponent("dest.bin")
        try Data(repeating: 0x01, count: 1024).write(to: src)

        let service = FileOperationService(settings: makeSettings(checksumEnabled: false))
        let provider = LocalProvider()

        var finalState: OperationState?
        for try await state in await service.copy(source: src, destination: dst, provider: provider) {
            finalState = state
        }

        guard case .complete(let result) = finalState else {
            XCTFail("Expected .complete")
            return
        }
        if case .skipped = result { /* pass */ } else {
            XCTFail("Expected .skipped, got \(result)")
        }
    }

    // MARK: - Conflict skip

    func testConflictSkip() async throws {
        let dir = try tmpDir()
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appendingPathComponent("source.bin")
        let dst = dir.appendingPathComponent("dest.bin")
        try Data(repeating: 0xAA, count: 512).write(to: src)
        try Data(repeating: 0xBB, count: 512).write(to: dst)  // existing file

        let service = FileOperationService(settings: makeSettings())
        let provider = LocalProvider()

        var finalState: OperationState?
        for try await state in await service.copy(
            source: src, destination: dst, provider: provider, conflictResolution: .skip
        ) {
            finalState = state
        }

        guard case .complete(let result) = finalState else {
            XCTFail("Expected .complete")
            return
        }
        if case .skipped = result { /* pass */ } else {
            XCTFail("Expected .skipped, got \(result)")
        }
        let destContent = try Data(contentsOf: dst)
        XCTAssertEqual(destContent, Data(repeating: 0xBB, count: 512))
    }

    // MARK: - Conflict rename

    func testConflictRename() async throws {
        let dir = try tmpDir()
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appendingPathComponent("file.txt")
        let dst = dir.appendingPathComponent("file.txt")
        try "original".data(using: .utf8)!.write(to: src)
        try "existing".data(using: .utf8)!.write(to: dst)

        let service = FileOperationService(settings: makeSettings(checksumEnabled: false))
        let provider = LocalProvider()

        for try await _ in await service.copy(
            source: src, destination: dst, provider: provider, conflictResolution: .rename
        ) {}

        let renamed = dir.appendingPathComponent("file-2.txt")
        XCTAssertTrue(fm.fileExists(atPath: renamed.path))
        XCTAssertEqual(try String(contentsOf: dst), "existing")
    }

    // MARK: - Cancellation

    func testCancelDuringCopy() async throws {
        let dir = try tmpDir()
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appendingPathComponent("source.bin")
        let dst = dir.appendingPathComponent("dest.bin")
        let partURL = dst.deletingLastPathComponent()
            .appendingPathComponent("." + dst.lastPathComponent + ".part")
        try Data(repeating: 0xCD, count: 32_768).write(to: src)

        let service = FileOperationService(settings: makeSettings())
        let provider = LocalProvider()

        let task = Task {
            for try await _ in await service.copy(source: src, destination: dst, provider: provider) {}
        }
        task.cancel()
        _ = await task.result

        XCTAssertFalse(fm.fileExists(atPath: dst.path), "Final dest must not exist after cancel")
        XCTAssertFalse(fm.fileExists(atPath: partURL.path), "Temp .part file must be cleaned up")
    }

    func testCancelDuringVerification() async throws {
        let dir = try tmpDir()
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appendingPathComponent("source.bin")
        let dst = dir.appendingPathComponent("dest.bin")
        let partURL = dst.deletingLastPathComponent()
            .appendingPathComponent("." + dst.lastPathComponent + ".part")
        // Use a single-chunk file so copy finishes quickly and verify is reached.
        // We then cancel the outer task which stops the verify loop.
        try Data(repeating: 0xAB, count: 256).write(to: src)

        // Tiny chunk size so copy finishes in one chunk, checksum loop starts.
        let settings = makeSettings(checksumEnabled: true)
        settings.chunkSizeBytes = 1024 * 1024  // 1 MB — whole file fits in one read
        let service = FileOperationService(settings: settings)
        let provider = LocalProvider()

        let task = Task {
            for try await _ in await service.copy(source: src, destination: dst, provider: provider) {}
        }
        task.cancel()
        _ = await task.result

        XCTAssertFalse(fm.fileExists(atPath: dst.path), "Final dest must not exist after cancel during verify")
        XCTAssertFalse(fm.fileExists(atPath: partURL.path), "Temp .part file must be cleaned up")
    }

    func testCancelDuringMoveNoDataLoss() async throws {
        let dir = try tmpDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("srcDir")
        let dstDir = dir.appendingPathComponent("dstDir")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let src = srcDir.appendingPathComponent("file.bin")
        let dst = dstDir.appendingPathComponent("file.bin")
        let partURL = dstDir.appendingPathComponent(".file.bin.part")
        try Data(repeating: 0x77, count: 32_768).write(to: src)

        let service = FileOperationService(settings: makeSettings())
        let provider = LocalProvider()

        let task = Task {
            for try await _ in await service.move(source: src, destination: dst, provider: provider) {}
        }
        task.cancel()
        _ = await task.result

        // Same-volume move uses an atomic rename; cancellation may occur before or
        // after it. Either way, the file must exist at exactly one location (no loss).
        let sourceExists = fm.fileExists(atPath: src.path)
        let destExists   = fm.fileExists(atPath: dst.path)
        XCTAssertTrue(sourceExists || destExists, "File must exist at source or dest — no data loss")
        XCTAssertFalse(sourceExists && destExists, "File must not be duplicated after cancelled move")
        XCTAssertFalse(fm.fileExists(atPath: partURL.path), "No .part temp file should remain")
    }

    // MARK: - Recursive directory copy

    func testRecursiveDirectoryCopy() async throws {
        let dir = try tmpDir()
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appendingPathComponent("srcDir")
        let sub = src.appendingPathComponent("subDir")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try "a".data(using: .utf8)!.write(to: src.appendingPathComponent("a.txt"))
        try "b".data(using: .utf8)!.write(to: sub.appendingPathComponent("b.txt"))

        let dst = dir.appendingPathComponent("dstDir")
        let service = FileOperationService(settings: makeSettings(checksumEnabled: false))
        let provider = LocalProvider()

        for try await _ in await service.copyDirectory(
            source: src, destination: dst, provider: provider
        ) {}

        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("subDir/b.txt").path))
    }
}
