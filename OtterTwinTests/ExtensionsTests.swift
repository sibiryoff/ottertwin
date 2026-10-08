import XCTest
import CryptoKit
@testable import OtterTwin

/// Tests for the shared helpers in `VFS/Extensions.swift`.
///
/// This file was also added to prove that a new `.swift` file is picked up by
/// the CI-generated Xcode project without any hand edits to project files (#16).
final class ExtensionsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Digest.hexString

    func testHexStringMatchesKnownSHA256Vector() {
        // FIPS 180-2 test vector for "abc".
        let digest = SHA256.hash(data: Data("abc".utf8))
        XCTAssertEqual(
            digest.hexString,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testHexStringOfEmptyInputIsLowercase64Chars() {
        let hex = SHA256.hash(data: Data()).hexString
        XCTAssertEqual(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex, hex.lowercased())
    }

    // MARK: - URL.fileByteCount

    func testFileByteCountReturnsSizeOfFile() throws {
        let url = tempDir.appendingPathComponent("sample.bin")
        try Data(repeating: 0xAB, count: 4097).write(to: url)
        XCTAssertEqual(url.fileByteCount, 4097)
    }

    func testFileByteCountOfEmptyFileIsZero() throws {
        let url = tempDir.appendingPathComponent("empty.bin")
        try Data().write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.fileByteCount, 0)
    }

    func testFileByteCountOfMissingFileFallsBackToZero() {
        // Documents current behaviour: a missing file reports 0 bytes rather than throwing.
        let url = tempDir.appendingPathComponent("does-not-exist.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.fileByteCount, 0)
    }
}
