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
