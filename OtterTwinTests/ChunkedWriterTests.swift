import XCTest
import Darwin
@testable import OtterTwin

/// #6: `ChunkedWriter` writes to a temporary file that is unique per writer
/// (per operation), owner-only and created exclusively; only `close()` moves it
/// to the final name, never over an existing item; `abort()` removes only its
/// own temporary file.
final class ChunkedWriterTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("ChunkedWriterTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func permissions(_ url: URL) throws -> Int {
        Int(try HarnessPOSIX.lstat(url.path).st_mode & 0o777)
    }

    func testDataStaysInAUniqueOwnerOnlyTemporaryFileUntilClose() throws {
        let destination = tempDir.appendingPathComponent("file.bin")
        let first = try LocalProvider().makeWriter(at: destination)
        let second = try LocalProvider().makeWriter(at: destination)

        XCTAssertNotEqual(first.temporaryURL, second.temporaryURL, "unique per writer")
        for writer in [first, second] {
            XCTAssertEqual(writer.destinationURL, destination)
            XCTAssertEqual(writer.temporaryURL.deletingLastPathComponent(), tempDir, "same folder as the destination")
            XCTAssertTrue(ChunkedWriter.isTemporaryFileName(writer.temporaryURL.lastPathComponent))
            XCTAssertEqual(try permissions(writer.temporaryURL), 0o600)
        }

        try first.write(Data([1, 2, 3]))
        try second.write(Data([4, 5]))
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "nothing under the final name before close")

        first.abort()
        XCTAssertFalse(fm.fileExists(atPath: first.temporaryURL.path), "abort removes its own temporary file")
        XCTAssertTrue(fm.fileExists(atPath: second.temporaryURL.path), "and never another writer's")

        try second.close()
        XCTAssertEqual(try Data(contentsOf: destination), Data([4, 5]))
        XCTAssertFalse(fm.fileExists(atPath: second.temporaryURL.path))
        XCTAssertEqual(try permissions(destination), 0o600)

        second.abort()
        XCTAssertEqual(try Data(contentsOf: destination), Data([4, 5]), "abort after close never touches the destination")
    }

    func testCloseNeverReplacesAnItemThatAppearedMeanwhile() throws {
        let destination = tempDir.appendingPathComponent("file.bin")
        let writer = try LocalProvider().makeWriter(at: destination)
        try writer.write(Data([1, 2, 3]))
        try Data("someone else's".utf8).write(to: destination)

        XCTAssertThrowsError(try writer.close()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("someone else's".utf8))

        writer.abort()
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tempDir.path), ["file.bin"], "temporary file removed")
        XCTAssertEqual(try Data(contentsOf: destination), Data("someone else's".utf8))
    }

    func testTemporaryNameFitsNextToALongestPossibleName() throws {
        let destination = tempDir.appendingPathComponent(String(repeating: "n", count: 251) + ".txt")
        let writer = try LocalProvider().makeWriter(at: destination)
        XCTAssertLessThanOrEqual(writer.temporaryURL.lastPathComponent.utf8.count, 255)
        try writer.write(Data([7]))
        try writer.close()
        XCTAssertEqual(try Data(contentsOf: destination), Data([7]))
    }

    func testTemporaryFileNameRecognition() {
        XCTAssertTrue(ChunkedWriter.isTemporaryFileName(".a.bin.ottertwin-0F1C1D7E-1111-2222-3333-444455556666.part"))
        XCTAssertFalse(ChunkedWriter.isTemporaryFileName("a.bin"))
        XCTAssertFalse(ChunkedWriter.isTemporaryFileName(".a.bin.part"))
    }
}
