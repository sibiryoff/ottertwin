import XCTest
import Darwin
@testable import OtterTwin

/// #6: cancelling a copy or move stops the real file I/O, removes the partial or
/// unverified destination before reporting `cancelled`, and never deletes a
/// move's source. Uses the data-safety harness (#24): pause points cancel exactly
/// during the copy, exactly during verification and right before a move deletes
/// its source; `TreeSnapshot` proves the source was not touched.
final class FileOperationCancellationTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var output: URL!
    private var provider: FaultInjectingProvider!

    private static let chunkSize = 64 * 1024

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("FileOperationCancellationTests-\(UUID().uuidString)", isDirectory: true)
        output = tempDir.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        provider = FaultInjectingProvider(fakeTrash: tempDir.appendingPathComponent("FakeTrash", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        output = nil
        provider = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeService(checksumEnabled: Bool = true) -> FileOperationService {
        let settings = SettingsService()
        settings.setChecksumEnabled(checksumEnabled, userConfirmedDisable: !checksumEnabled)
        settings.setChunkSizeBytes(Self.chunkSize)
        return FileOperationService(settings: settings)
    }

    private func makeFixture() throws -> FixtureTree {
        var options = FixtureTree.Options()
        options.chunkSize = Self.chunkSize
        options.largeFileSize = 1 << 20
        options.includeSymlinks = false
        return try FixtureTree.build(at: tempDir.appendingPathComponent("fixture", isDirectory: true), options: options)
    }

    /// Every state an operation reported, in order.
    final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [OperationState] = []
        var states: [OperationState] { lock.withLock { _states } }
        func append(_ state: OperationState) { lock.withLock { _states.append(state) } }

        var didVerify: Bool { states.contains { if case .verifying = $0 { return true } else { return false } } }
        var didComplete: Bool { states.contains { if case .complete = $0 { return true } else { return false } } }
    }

    /// Starts a copy (or move) in its own task; the task's value is the error it
    /// ended with, available only once the operation (and its cleanup) is over.
    private func start(_ kind: OperationKind, _ source: URL, to destination: URL,
                       service: FileOperationService? = nil) -> (Task<Error?, Never>, StateLog) {
        let log = StateLog()
        let service = service ?? makeService()
        let provider = provider!
        let task = Task { () -> Error? in
            do {
                switch kind {
                case .copy:
                    try await service.copy(source: source, destination: destination, provider: provider, onState: { log.append($0) })
                case .move:
                    try await service.move(source: source, destination: destination, provider: provider, onState: { log.append($0) })
                }
                return nil
            } catch {
                return error
            }
        }
        return (task, log)
    }

    private func assertCancelled(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .cancelled? = error as? OperationError else {
            return XCTFail("expected OperationError.cancelled, got \(String(describing: error))", file: file, line: line)
        }
    }

    /// Names of `ChunkedWriter` temporary files in `directory`.
    private func partialFiles(in directory: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: directory.path).filter(ChunkedWriter.isTemporaryFileName)
    }

    private func size(_ url: URL) throws -> Int64 { try HarnessPOSIX.lstat(url.path).st_size }

    // MARK: - Copy

    func testCancelDuringCopyStopsTheCopyAndRemovesThePartialFile() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = output.appendingPathComponent("copy.bin")
        let before = try TreeSnapshot.capture(source)
        let duringCopy = provider.pauseRead(of: source, beforeChunk: 2)
        let duringVerification = provider.pauseRead(of: destination, beforeChunk: 0)
        defer { duringVerification.release() }

        let (operation, log) = start(.copy, source, to: destination)
        let reached = await duringCopy.waitUntilReached()
        XCTAssertTrue(reached)

        // Mid-copy: the data so far is in one hidden, operation-unique partial
        // file; nothing exists under the final name.
        let partials = try partialFiles(in: output)
        XCTAssertEqual(partials.count, 1, "\(partials)")
        if let partial = partials.first {
            XCTAssertEqual(try size(output.appendingPathComponent(partial)), Int64(2 * Self.chunkSize))
        }
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "no final-looking file while copying")

        operation.cancel()
        duringCopy.release()
        let error = await operation.value

        assertCancelled(error)
        XCTAssertFalse(duringVerification.isReached, "a cancelled copy never starts verifying")
        XCTAssertFalse(log.didVerify)
        XCTAssertFalse(log.didComplete)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), [], "no destination and no partial file left")
        XCTAssertEqual(provider.bytesDelivered(from: source), Int64(2 * Self.chunkSize), "no byte read after the cancel")
        assertTree(source, matches: before, "source unchanged")
    }

    func testCancelDuringCopyWithChecksumOffRemovesThePartialFile() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = output.appendingPathComponent("copy.bin")
        let duringCopy = provider.pauseRead(of: source, beforeChunk: 1)

        let (operation, log) = start(.copy, source, to: destination, service: makeService(checksumEnabled: false))
        let reached = await duringCopy.waitUntilReached()
        XCTAssertTrue(reached)
        operation.cancel()
        duringCopy.release()
        let error = await operation.value

        assertCancelled(error)
        XCTAssertFalse(log.didComplete)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), [], "no destination and no partial file left")
    }

    func testCancelDuringVerificationRemovesTheUnverifiedDestination() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = output.appendingPathComponent("copy.bin")
        let before = try TreeSnapshot.capture(source)
        // Before the second chunk of the destination: verification is under way.
        let duringVerification = provider.pauseRead(of: destination, beforeChunk: 1)

        let (operation, log) = start(.copy, source, to: destination)
        let reached = await duringVerification.waitUntilReached()
        XCTAssertTrue(reached)
        XCTAssertTrue(log.didVerify, "verification has started")
        XCTAssertEqual(try size(destination), try size(source), "the copy was fully written")
        XCTAssertEqual(try partialFiles(in: output), [])

        operation.cancel()
        duringVerification.release()
        let error = await operation.value

        assertCancelled(error)
        XCTAssertFalse(log.didComplete)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), [], "unverified destination removed")
        XCTAssertEqual(provider.readCalls, [source, destination])
        assertTree(source, matches: before, "source unchanged")
    }

    func testCancellingOneOperationNeverTouchesAnotherOperationsFiles() async throws {
        let tree = try makeFixture()
        let first = tree.url(FixtureTree.Path.multiChunk)
        let second = tree.url(FixtureTree.Path.chunkPlusOne)
        let destination = output.appendingPathComponent("same-name.bin")
        let duringFirst = provider.pauseRead(of: first, beforeChunk: 1)

        let (firstOperation, _) = start(.copy, first, to: destination)
        let reached = await duringFirst.waitUntilReached()
        XCTAssertTrue(reached)

        // A second operation to the same name gets its own partial file and finishes.
        let (secondOperation, secondLog) = start(.copy, second, to: destination)
        let secondError = await secondOperation.value
        XCTAssertNil(secondError)
        XCTAssertTrue(secondLog.didComplete)
        XCTAssertEqual(try partialFiles(in: output).count, 1, "the first operation's partial file is still there")

        firstOperation.cancel()
        duringFirst.release()
        let firstError = await firstOperation.value

        assertCancelled(firstError)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), ["same-name.bin"])
        assertTree(destination, matches: try TreeSnapshot.capture(second), comparator: TreeComparator(checks: .data),
                   "the other operation's verified file is intact")
    }

    // MARK: - Move

    func testCancelDuringSameVolumeMoveKeepsTheSource() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = output.appendingPathComponent("moved.bin")
        let before = try TreeSnapshot.capture(source)
        let duringHash = provider.pauseRead(of: source, beforeChunk: 1)

        let (operation, log) = start(.move, source, to: destination)
        let reached = await duringHash.waitUntilReached()
        XCTAssertTrue(reached)
        operation.cancel()
        duringHash.release()
        let error = await operation.value

        assertCancelled(error)
        XCTAssertFalse(log.didComplete)
        XCTAssertTrue(provider.moveCalls.isEmpty, "never renamed")
        XCTAssertTrue(provider.deleteCalls.isEmpty, "nothing deleted")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), [])
        assertTree(source, matches: before, "source unchanged")
    }

    func testCancelDuringCrossVolumeMoveCopyKeepsTheSource() async throws {
        let volume = try makeScratchVolume(.apfs)
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = volume.mountPoint.appendingPathComponent("moved.bin")
        let before = try TreeSnapshot.capture(source)
        let duringCopy = provider.pauseRead(of: source, beforeChunk: 2)

        let (operation, log) = start(.move, source, to: destination)
        let reached = await duringCopy.waitUntilReached()
        XCTAssertTrue(reached)
        XCTAssertEqual(try partialFiles(in: volume.mountPoint).count, 1)
        operation.cancel()
        duringCopy.release()
        let error = await operation.value

        assertCancelled(error)
        XCTAssertFalse(log.didComplete)
        XCTAssertFalse(provider.deleteCalls.contains(source), "source never deleted")
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(try partialFiles(in: volume.mountPoint), [])
        assertTree(source, matches: before, "source unchanged")
    }

    func testCancelRightBeforeCrossVolumeMoveDeletesTheSourceKeepsTheSource() async throws {
        let volume = try makeScratchVolume(.apfs)
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = volume.mountPoint.appendingPathComponent("moved.bin")
        let before = try TreeSnapshot.capture(source)
        // Pause at the end-of-file read of verification: every byte of the copy
        // has been verified, the source delete is the next step.
        let chunks = Int((try size(source) + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize))
        let beforeSourceDelete = provider.pauseRead(of: destination, beforeChunk: chunks)

        let (operation, log) = start(.move, source, to: destination)
        let reached = await beforeSourceDelete.waitUntilReached()
        XCTAssertTrue(reached)
        XCTAssertEqual(provider.bytesDelivered(from: destination), try size(source), "fully verified")
        XCTAssertTrue(provider.deleteCalls.isEmpty)
        operation.cancel()
        beforeSourceDelete.release()
        let error = await operation.value

        assertCancelled(error)
        XCTAssertFalse(log.didComplete)
        XCTAssertFalse(provider.deleteCalls.contains(source), "source never deleted")
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "the copy is removed: a cancelled move changes nothing")
        XCTAssertEqual(try partialFiles(in: volume.mountPoint), [])
        assertTree(source, matches: before, "source unchanged")
    }

    // MARK: - Finalize on file systems without RENAME_EXCL support

    func testCopyToExFATAndFAT32FinalizesAndLeavesNoPartialFile() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        for fileSystem in [ScratchVolume.FileSystem.exfat, .fat32] {
            let volume = try makeScratchVolume(fileSystem)
            let destination = volume.mountPoint.appendingPathComponent("copy.bin")

            let (operation, log) = start(.copy, source, to: destination)
            let error = await operation.value

            XCTAssertNil(error, "\(fileSystem)")
            XCTAssertTrue(log.didComplete, "\(fileSystem)")
            assertTree(destination, matches: try TreeSnapshot.capture(source),
                       comparator: TreeComparator(checks: [.type, .size, .content]), "\(fileSystem)")
            XCTAssertEqual(try partialFiles(in: volume.mountPoint), [], "\(fileSystem)")
        }
    }
}
