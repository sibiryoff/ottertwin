import XCTest
@testable import OtterTwin

final class LocalProviderTests: XCTestCase {
    let provider = LocalProvider()
    let fm = FileManager.default

    // MARK: - List

    func testListDirectory() async throws {
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let a = dir.appendingPathComponent("alpha.txt")
        let b = dir.appendingPathComponent("beta.txt")
        try "a".data(using: .utf8)!.write(to: a)
        try "b".data(using: .utf8)!.write(to: b)

        let items = try await provider.listDirectory(dir)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.name).sorted(), ["alpha.txt", "beta.txt"])
    }

    // MARK: - Round-trip read

    func testReadRoundTrip() async throws {
        let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data(repeating: 0xAB, count: 4096)
        try payload.write(to: file)
        defer { try? fm.removeItem(at: file) }

        var collected = Data()
        for try await chunk in provider.readChunks(of: file, chunkSize: 1024) {
            collected.append(chunk)
        }
        XCTAssertEqual(collected, payload)
    }

    // MARK: - Delete

    func testDeleteFile() async throws {
        let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "x".data(using: .utf8)!.write(to: file)
        try await provider.delete(file)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
    }

    func testTrashFile() async throws {
        let file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "x".data(using: .utf8)!.write(to: file)
        try await provider.trash(file)
        XCTAssertFalse(fm.fileExists(atPath: file.path),
                       "File should no longer exist at original path after trash")
    }

    func testSupportsTrash() {
        XCTAssertTrue(provider.supportsTrash)
    }

    // MARK: - Move

    func testMoveFile() async throws {
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appendingPathComponent("source.txt")
        let dst = dir.appendingPathComponent("dest.txt")
        try "hello".data(using: .utf8)!.write(to: src)

        try await provider.move(from: src, to: dst)

        XCTAssertFalse(fm.fileExists(atPath: src.path))
        XCTAssertTrue(fm.fileExists(atPath: dst.path))
    }
}
