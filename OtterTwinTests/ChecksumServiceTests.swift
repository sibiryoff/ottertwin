import XCTest
import CryptoKit
@testable import OtterTwin

final class ChecksumServiceTests: XCTestCase {
    let service = ChecksumService()

    // MARK: - Known hash

    func testKnownHash() async throws {
        let content = "Hello, OtterTwin!".data(using: .utf8)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try content.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()

        var finalDigest: String?
        for try await event in service.hash(url: file, chunkSize: 1024) {
            if case .complete(let hex) = event { finalDigest = hex }
        }
        XCTAssertEqual(finalDigest, expected)
    }

    // MARK: - Multi-chunk

    func testMultiChunkHash() async throws {
        let data = Data((0..<10_000).map { UInt8($0 % 256) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        var finalDigest: String?
        for try await event in service.hash(url: file, chunkSize: 1000) {
            if case .complete(let hex) = event { finalDigest = hex }
        }
        XCTAssertEqual(finalDigest, expected)
    }

    // MARK: - Cancellation

    func testCancellationLeavesNoSideEffects() async throws {
        let size = 2 * 1024 * 1024
        let data = Data(repeating: 0x42, count: size)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let task = Task<Void, Error> {
            for try await event in self.service.hash(url: file, chunkSize: 256 * 1024) {
                if case .progress = event { return }  // exit after first progress event
            }
        }
        task.cancel()
        _ = try? await task.value

        // File must still exist — hashing has no write side effects
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
