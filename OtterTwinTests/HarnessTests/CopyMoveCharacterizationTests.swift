import XCTest
@testable import OtterTwin

/// #24: characterization of `FileOperationService` on current `main`, using the
/// data-safety harness. Assertions outside `XCTExpectFailure` are guarantees that
/// hold today. Known gaps are wrapped in `XCTExpectFailure` naming the issue that
/// will fix them; when that fix lands the block starts passing, the expectation
/// fails, and the fixing PR must remove it (turning the gap into a guarantee).
final class CopyMoveCharacterizationTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var provider: FaultInjectingProvider!

    private static let chunkSize = 64 * 1024

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("CopyMoveCharacterizationTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        provider = FaultInjectingProvider(fakeTrash: tempDir.appendingPathComponent("FakeTrash", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
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

    /// A fixture tree with a small "large" file, for single-file tests.
    private func makeFixture(_ name: String = "fixture", largeFileSize: Int = 1 << 20, symlinks: Bool = false) throws -> FixtureTree {
        var options = FixtureTree.Options()
        options.chunkSize = Self.chunkSize
        options.largeFileSize = largeFileSize
        options.includeSymlinks = symlinks
        return try FixtureTree.build(at: tempDir.appendingPathComponent(name, isDirectory: true), options: options)
    }

    private struct Outcome {
        var states: [OperationState] = []
        var error: Error?

        var result: VerificationResult? {
            if case .complete(let result)? = states.last { return result }
            return nil
        }
        var isVerified: Bool {
            if case .verified? = result { return true }
            return false
        }
        var isChecksumMismatch: Bool {
            if case .checksumMismatch? = error as? OperationError { return true }
            return false
        }
        /// The injected fault, if the operation failed with one wrapped in `.ioError`.
        var injectedFault: InjectedFault? {
            if case .ioError(let underlying)? = error as? OperationError { return underlying as? InjectedFault }
            return nil
        }
    }

    private func run(_ stream: AsyncThrowingStream<OperationState, Error>) async -> Outcome {
        var outcome = Outcome()
        do {
            for try await state in stream { outcome.states.append(state) }
        } catch {
            outcome.error = error
        }
        return outcome
    }

    private func copy(_ source: URL, to destination: URL, checksum: Bool = true,
                      conflict: ConflictResolution = .skip) async -> Outcome {
        await run(await makeService(checksumEnabled: checksum).copy(
            source: source, destination: destination, provider: provider, conflictResolution: conflict))
    }

    private func move(_ source: URL, to destination: URL, checksum: Bool = true) async -> Outcome {
        await run(await makeService(checksumEnabled: checksum).move(
            source: source, destination: destination, provider: provider))
    }

    private func copyDirectory(_ source: URL, to destination: URL) async -> Outcome {
        await run(await makeService().copyDirectory(source: source, destination: destination, provider: provider))
    }

    private func snapshot(_ url: URL) throws -> TreeSnapshot { try TreeSnapshot.capture(url) }

    /// The source must be exactly as before the operation (all checks, including mtime).
    private func assertUnchanged(_ before: TreeSnapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        assertNoDifferences(TreeComparator().compare(expected: before, actual: try snapshot(before.root)),
                            "source changed", file: file, line: line)
    }

    private func dataDifferences(_ expected: URL, _ actual: URL) throws -> [TreeDifference] {
        try TreeComparator(checks: .data).compare(expected: expected, actual: actual)
    }

    // MARK: - Single-file copy

    func testSingleFileCopyIsByteExactAtChunkBoundaries() async throws {
        let tree = try makeFixture()
        typealias P = FixtureTree.Path
        let output = tempDir.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)

        for name in [P.emptyFile, P.chunkMinusOne, P.chunkExact, P.chunkPlusOne, P.multiChunk, P.large,
                     P.spaces, P.emoji, P.longName, P.readOnly] {
            let source = tree.url(name)
            let destination = output.appendingPathComponent(source.lastPathComponent)
            let outcome = await copy(source, to: destination)

            XCTAssertNil(outcome.error, name)
            assertNoDifferences(try dataDifferences(source, destination), name)
            // The app's hash agrees with the harness's independent SHA-256.
            let independent = try snapshot(source).entries[Array(".".utf8)]?.sha256
            guard case .verified(let sourceHash, let destHash)? = outcome.result else {
                XCTFail("\(name): expected .verified, got \(String(describing: outcome.result))")
                continue
            }
            XCTAssertEqual(sourceHash, independent, name)
            XCTAssertEqual(destHash, independent, name)
        }
    }

    func testSingleFileCopyDropsMetadata_knownGap30() async throws {
        let tree = try makeFixture()
        typealias P = FixtureTree.Path
        let output = tempDir.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let cases: [(String, TreeComparator.Checks)] = [(P.mtimeFile, .mtime), (P.readOnly, .permissions), (P.xattrFile, .xattrs)]

        for (name, check) in cases {
            let source = tree.url(name)
            let destination = output.appendingPathComponent(source.lastPathComponent)
            let outcome = await copy(source, to: destination)
            XCTAssertNil(outcome.error, name)
            assertNoDifferences(try dataDifferences(source, destination), name)
            XCTExpectFailure("#30: copies do not preserve \(name)'s metadata yet") {
                assertTreesEqual(expected: source, actual: destination, comparator: TreeComparator(checks: check), name)
            }
        }
    }

    func testCorruptedWriteIsDetectedAndCleanedUp() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = tempDir.appendingPathComponent("corrupted.bin")
        provider.corruptions = [destination: Int64(Self.chunkSize + 3)]
        let before = try snapshot(source)

        let outcome = await copy(source, to: destination)

        XCTAssertTrue(outcome.isChecksumMismatch, "\(String(describing: outcome.error))")
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "corrupted copy is removed")
        try assertUnchanged(before)
    }

    func testWriteFaultMidCopyFailsAndLeavesNoDestination() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = tempDir.appendingPathComponent("write-fault.bin")
        let fault = InjectedFault(message: "disk full")
        provider.writeFaults = [destination: ByteFault(offset: Int64(2 * Self.chunkSize + 5), error: fault)]
        let before = try snapshot(source)

        let outcome = await copy(source, to: destination)

        XCTAssertEqual(outcome.injectedFault, fault)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        try assertUnchanged(before)
    }

    func testSourceReadFaultFailsAndLeavesNoDestination() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = tempDir.appendingPathComponent("read-fault.bin")
        let fault = InjectedFault(message: "I/O error")
        provider.readFaults = [source: ByteFault(offset: Int64(Self.chunkSize), error: fault)]

        let outcome = await copy(source, to: destination)

        XCTAssertEqual(outcome.injectedFault, fault)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    func testVerificationReadFaultFailsAndRemovesDestination() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = tempDir.appendingPathComponent("verify-fault.bin")
        let fault = InjectedFault(message: "I/O error while verifying")
        provider.readFaults = [destination: ByteFault(offset: 10, error: fault)]

        let outcome = await copy(source, to: destination)

        XCTAssertEqual(outcome.injectedFault, fault)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(provider.readCalls, [source, destination], "copy reads the source, verification the destination")
    }

    func testCloseFaultFailsAndRemovesDestination() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.chunkPlusOne)
        let destination = tempDir.appendingPathComponent("close-fault.bin")
        let fault = InjectedFault(message: "flush failed")
        provider.closeFaults = [destination: fault]

        let outcome = await copy(source, to: destination)

        XCTAssertEqual(outcome.injectedFault, fault)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    func testFailedOverwriteDestroysTheOriginalDestination_knownGap27() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = tempDir.appendingPathComponent("existing.bin")
        try FixtureTree.content(for: "existing", size: 5_000, seed: 1).write(to: destination)
        let original = try snapshot(destination)
        let sourceBefore = try snapshot(source)
        provider.writeFaults = [destination: ByteFault(offset: Int64(Self.chunkSize), error: InjectedFault(message: "disk full"))]

        let outcome = await copy(source, to: destination, conflict: .overwrite)

        XCTAssertNotNil(outcome.error)
        try assertUnchanged(sourceBefore)
        XCTExpectFailure("#27: overwrite deletes the original destination before the new copy is verified") {
            assertTree(destination, matches: original, comparator: TreeComparator(checks: .data),
                       "original destination must survive byte-identical")
        }
    }

    // MARK: - Pause points: exactly during copy / exactly during verification

    func testPausePointsStopExactlyDuringCopyAndDuringVerification() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = tempDir.appendingPathComponent("paused.bin")
        let duringCopy = provider.pauseRead(of: source, beforeChunk: 2)
        let duringVerification = provider.pauseRead(of: destination, beforeChunk: 0)
        let operation = Task { await copy(source, to: destination) }

        let reachedCopy = await duringCopy.waitUntilReached()
        XCTAssertTrue(reachedCopy)
        XCTAssertEqual(try HarnessPOSIX.lstat(destination.path).st_size, Int64(2 * Self.chunkSize),
                       "paused after exactly two chunks were written")
        XCTAssertFalse(duringVerification.isReached)
        duringCopy.release()

        let reachedVerification = await duringVerification.waitUntilReached()
        XCTAssertTrue(reachedVerification)
        XCTAssertEqual(try HarnessPOSIX.lstat(destination.path).st_size, try HarnessPOSIX.lstat(source.path).st_size,
                       "verification starts after the whole file was written")
        duringVerification.release()

        let outcome = await operation.value
        XCTAssertTrue(outcome.isVerified)
        assertNoDifferences(try dataDifferences(source, destination))
    }

    func testCancelDuringCopyDoesNotStopTheOperation_knownGap6() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = tempDir.appendingPathComponent("cancelled.bin")
        let duringCopy = provider.pauseRead(of: source, beforeChunk: 1)
        let duringVerification = provider.pauseRead(of: destination, beforeChunk: 0)
        let operation = Task { await copy(source, to: destination) }

        let reachedCopy = await duringCopy.waitUntilReached()
        XCTAssertTrue(reachedCopy)
        operation.cancel()
        duringCopy.release()
        _ = await operation.value

        // A cancelled copy must never get as far as verifying.
        let continued = await duringVerification.waitUntilReached(timeout: 5)
        XCTExpectFailure("#6: cancelling the caller does not cancel the underlying copy task") {
            XCTAssertFalse(continued, "copy kept running after cancel")
        }
        duringVerification.release()
    }

    // MARK: - Folder copy

    func testFolderCopy() async throws {
        // Full fixture (64 MiB large file by default), without symlinks: see the next test.
        var options = FixtureTree.Options()
        options.chunkSize = Self.chunkSize
        options.includeSymlinks = false
        let tree = try FixtureTree.build(at: tempDir.appendingPathComponent("tree", isDirectory: true), options: options)
        let destination = tempDir.appendingPathComponent("copy", isDirectory: true)
        let before = try snapshot(tree.root)

        let outcome = await copyDirectory(tree.root, to: destination)

        XCTAssertNil(outcome.error)
        try assertUnchanged(before)
        let copied = try snapshot(destination)
        // Guarantee today: every visible file and folder, byte-exact, including Unicode/long names.
        assertNoDifferences(TreeComparator(checks: .data, excluding: TreeComparator.isHidden).compare(expected: before, actual: copied))
        XCTExpectFailure("#9: copyDirectory skips hidden files and folders") {
            assertNoDifferences(TreeComparator(checks: [.presence]).compare(expected: before, actual: copied))
        }
        XCTExpectFailure("#30: folder copies do not preserve mtimes, permissions or xattrs") {
            assertNoDifferences(TreeComparator(checks: .metadata, excluding: TreeComparator.isHidden).compare(expected: before, actual: copied))
        }
    }

    func testFolderCopyWithSymlinks_knownGap9() async throws {
        let tree = try makeFixture("tree", symlinks: true)
        let destination = tempDir.appendingPathComponent("copy", isDirectory: true)
        let before = try snapshot(tree.root)

        let outcome = await copyDirectory(tree.root, to: destination)

        try assertUnchanged(before)
        XCTExpectFailure("#9: folder copy does not handle symlinks (to file, to dir, dangling, loop)") {
            XCTAssertNil(outcome.error)
            let links = { (path: String) in !(path == "." || path == "links" || path.hasPrefix("links/")) }
            assertTree(destination, matches: before,
                       comparator: TreeComparator(checks: [.presence, .type, .symlinkTarget], excluding: links))
        }
    }

    // MARK: - Cross-volume move (APFS scratch volume)

    func testCrossVolumeMoveOfFile() async throws {
        let volume = try makeScratchVolume(.apfs)
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.mtimeFile)
        let destination = volume.mountPoint.appendingPathComponent("moved.txt")
        let before = try snapshot(source)

        let outcome = await move(source, to: destination)

        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.isVerified)
        XCTAssertFalse(fm.fileExists(atPath: source.path), "source removed after a verified copy")
        let moved = try snapshot(destination)
        assertNoDifferences(TreeComparator(checks: .data).compare(expected: before, actual: moved))
        XCTExpectFailure("#30: cross-volume moves do not preserve mtime and permissions") {
            assertNoDifferences(TreeComparator(checks: [.mtime, .permissions]).compare(expected: before, actual: moved))
        }
    }

    func testCrossVolumeMoveWithCorruptionKeepsSource() async throws {
        let volume = try makeScratchVolume(.apfs)
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = volume.mountPoint.appendingPathComponent("moved.bin")
        provider.corruptions = [destination: 7]
        let before = try snapshot(source)

        let outcome = await move(source, to: destination)

        XCTAssertTrue(outcome.isChecksumMismatch, "\(String(describing: outcome.error))")
        try assertUnchanged(before)
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "corrupted copy removed")
        XCTAssertFalse(provider.deleteCalls.contains(source), "source never deleted")
    }

    func testCrossVolumeMoveWithChecksumDisabled_knownGap28() async throws {
        let volume = try makeScratchVolume(.apfs)
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = volume.mountPoint.appendingPathComponent("moved.bin")
        let before = try snapshot(source)

        let outcome = await move(source, to: destination, checksum: false)

        XCTAssertNil(outcome.error)
        assertNoDifferences(TreeComparator(checks: .data).compare(expected: before, actual: try snapshot(destination)))
        XCTExpectFailure("#28: a cross-volume move deletes the source without verifying when checksums are off") {
            XCTAssertTrue(outcome.isVerified)
        }
    }

    func testCrossVolumeMoveWhenSourceDeleteFails_knownGap28() async throws {
        let volume = try makeScratchVolume(.apfs)
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = volume.mountPoint.appendingPathComponent("moved.bin")
        provider.deleteFaults = [source: InjectedFault(message: "permission denied")]
        let before = try snapshot(source)

        let outcome = await move(source, to: destination)

        try assertUnchanged(before)
        assertNoDifferences(TreeComparator(checks: .data).compare(expected: before, actual: try snapshot(destination)),
                            "verified destination is kept")
        XCTExpectFailure("#28: a verified copy whose source can't be deleted should be a reported partial success, not an error") {
            XCTAssertNil(outcome.error)
        }
    }

    func testCrossVolumeMoveOfFolder_knownGap9() async throws {
        let volume = try makeScratchVolume(.apfs)
        let tree = try makeFixture("tree", largeFileSize: 256 * 1024)
        let destination = volume.mountPoint.appendingPathComponent("moved", isDirectory: true)
        let before = try snapshot(tree.root)

        let outcome = await move(tree.root, to: destination)

        try assertUnchanged(before)
        XCTExpectFailure("#9: moving a folder across volumes is not supported yet") {
            XCTAssertNil(outcome.error)
            XCTAssertTrue(fm.fileExists(atPath: destination.path))
        }
    }
}
