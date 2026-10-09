import XCTest
import Darwin
@testable import OtterTwin

/// #6: `ChunkedWriter` writes to a temporary file that is unique per writer
/// (per operation), owner-only and created exclusively; only `commit()` (or
/// `close()`) moves it to the final name, never over an existing item unless
/// the writer replaces it (#27); `abort()` removes only its own temporary file.
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
            XCTAssertTrue(ChunkedWriter.isDiscardablePartialFileName(writer.temporaryURL.lastPathComponent))
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
        let part = ".a.bin.ottertwin-0F1C1D7E-1111-2222-3333-444455556666.part"
        let old = ".a.bin.ottertwin-0F1C1D7E-1111-2222-3333-444455556666.old"
        XCTAssertTrue(ChunkedWriter.isDiscardablePartialFileName(part))
        XCTAssertFalse(ChunkedWriter.isDiscardablePartialFileName("a.bin"))
        XCTAssertFalse(ChunkedWriter.isDiscardablePartialFileName(".a.bin.part"))
        XCTAssertTrue(ChunkedWriter.isParkedOriginalFileName(old), "#27 parked original")
        XCTAssertFalse(ChunkedWriter.isParkedOriginalFileName(".a.bin.old"))
        XCTAssertFalse(ChunkedWriter.isParkedOriginalFileName(part))
        XCTAssertFalse(ChunkedWriter.isParkedOriginalFileName("a.bin"))
    }

    /// #27: a parked original (`.old`) can be the user's only copy of the
    /// original destination, so the discardable-partial predicate, the one a
    /// cleanup of stale partial files would use, must never match it.
    func testPartialPredicateNeverMatchesAParkedOriginal() {
        let destination = URL(fileURLWithPath: "/x/a.bin")
        for _ in 0..<20 {
            let parked = ChunkedWriter.backupURL(for: destination).lastPathComponent
            XCTAssertTrue(ChunkedWriter.isParkedOriginalFileName(parked), parked)
            XCTAssertFalse(ChunkedWriter.isDiscardablePartialFileName(parked), parked)
        }
        for name in [".a.bin.ottertwin-X.old", ".a.part.ottertwin-0F1C1D7E-1111-2222-3333-444455556666.old",
                     "." + String(repeating: "n", count: 100) + ".ottertwin-0F1C1D7E-1111-2222-3333-444455556666.old"] {
            XCTAssertFalse(ChunkedWriter.isDiscardablePartialFileName(name), name)
        }
    }

    /// #27: a replacing writer keeps the existing item until `commit()`, which
    /// swaps the finished file in and removes the original.
    func testReplacingWriterKeepsTheOriginalUntilCommit() throws {
        let destination = tempDir.appendingPathComponent("file.bin")
        try Data("original".utf8).write(to: destination)
        let writer = try LocalProvider().makeWriter(at: destination, replacingExisting: true)
        XCTAssertNotEqual(writer.backupURL, writer.temporaryURL)
        XCTAssertEqual(writer.backupURL.deletingLastPathComponent(), tempDir)

        try writer.write(Data([1, 2, 3]))
        try writer.finishWriting()
        XCTAssertEqual(try Data(contentsOf: writer.temporaryURL), Data([1, 2, 3]), "finished data is in the temporary file")
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8), "untouched before commit")

        try writer.commit()
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tempDir.path), ["file.bin"], "no temporary or .old file left")
        writer.abort()
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]), "abort after commit never touches the destination")
    }

    func testAbortedReplacingWriterLeavesTheOriginal() throws {
        let destination = tempDir.appendingPathComponent("file.bin")
        try Data("original".utf8).write(to: destination)
        let writer = try LocalProvider().makeWriter(at: destination, replacingExisting: true)
        try writer.write(Data([1, 2, 3]))
        try writer.finishWriting()

        writer.abort()
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tempDir.path), ["file.bin"])
    }
}
