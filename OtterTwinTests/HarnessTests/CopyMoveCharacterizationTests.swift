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
        assertTreeSnapshot(try snapshot(before.root), matches: before, "source changed", file: file, line: line)
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
            XCTExpectFailure("#30: copies do not preserve \(name)'s metadata yet", options: .treeDifferencesOnly) {
                assertTreesEqual(expected: source, actual: destination, comparator: TreeComparator(checks: check), name)
            }
        }
    }

    // MARK: - Single-file copy: names as the UI takes them (#48)

    /// Copies the only file in `folder` the way the UI does: the destination name
    /// is the `FileItem.name` from `provider.listDirectory`.
    private func copyAsUI(folder: String, of tree: FixtureTree, into output: URL) async throws -> Outcome {
        let items = try await provider.listDirectory(tree.url(folder))
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        return await copy(item.id, to: output.appendingPathComponent(item.name))
    }

    func testSingleFileCopyFromListingKeepsNFDName() async throws {
        let tree = try makeFixture()
        let output = tempDir.appendingPathComponent("out-nfd", isDirectory: true)

        let outcome = try await copyAsUI(folder: "unicode/nfd", of: tree, into: output)

        XCTAssertNil(outcome.error)
        assertTreesEqual(expected: tree.url("unicode/nfd"), actual: output, comparator: TreeComparator(checks: .data))
    }

    func testSingleFileCopyFromListingKeepsNFCName_knownGap48() async throws {
        let tree = try makeFixture()
        let output = tempDir.appendingPathComponent("out-nfc", isDirectory: true)

        let outcome = try await copyAsUI(folder: "unicode/nfc", of: tree, into: output)

        XCTAssertNil(outcome.error)
        // The bytes arrive whatever the name; only the name's spelling is the gap.
        let copiedNames = try HarnessPOSIX.directoryEntries(output.path)
        XCTAssertEqual(copiedNames.count, 1)
        if let name = copiedNames.first {
            let copied = URL(fileURLWithPath: output.path + "/" + String(decoding: name, as: UTF8.self))
            assertTreesEqual(expected: tree.url(FixtureTree.Path.nfcName), actual: copied,
                             comparator: TreeComparator(checks: [.type, .size, .content]))
        }
        XCTExpectFailure("#48: a single-file copy started like the UI rewrites an NFC name to NFD",
                         options: .treeDifferencesOnly) {
            assertTreesEqual(expected: tree.url("unicode/nfc"), actual: output, comparator: TreeComparator(checks: .data))
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

    /// #27 (was a known gap): a failed overwrite keeps the original destination.
    /// More cases (corruption, cancel, other volumes, no rename swap) are in `AtomicFinalizeTests`.
    func testFailedOverwriteKeepsTheOriginalDestination() async throws {
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
        XCTAssertTrue(fm.fileExists(atPath: destination.path), "original destination must survive")
        assertTree(destination, matches: original, comparator: TreeComparator(checks: .data),
                   "original destination must survive byte-identical")
        XCTAssertEqual(try partialFiles(in: tempDir), [], "no partial or .old file left")
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
        // Since #6 the copy is written to a partial file and only appears under
        // its final name once complete.
        let partials = try partialFiles(in: tempDir)
        XCTAssertEqual(partials.count, 1, "\(partials)")
        if let partial = partials.first {
            XCTAssertEqual(try HarnessPOSIX.lstat(tempDir.appendingPathComponent(partial).path).st_size,
                           Int64(2 * Self.chunkSize), "paused after exactly two chunks were written")
        }
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "no final-looking file while copying")
        XCTAssertFalse(duringVerification.isReached)
        duringCopy.release()

        let reachedVerification = await duringVerification.waitUntilReached()
        XCTAssertTrue(reachedVerification)
        // Since #27 the copy is verified in its partial file, before it gets its final name.
        let verifiedPartials = try partialFiles(in: tempDir)
        XCTAssertEqual(verifiedPartials.count, 1, "\(verifiedPartials)")
        if let partial = verifiedPartials.first {
            XCTAssertEqual(try HarnessPOSIX.lstat(tempDir.appendingPathComponent(partial).path).st_size,
                           try HarnessPOSIX.lstat(source.path).st_size,
                           "verification starts after the whole file was written")
        }
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "no final-looking file before verification")
        duringVerification.release()

        let outcome = await operation.value
        XCTAssertTrue(outcome.isVerified)
        assertNoDifferences(try dataDifferences(source, destination))
        XCTAssertEqual(try partialFiles(in: tempDir), [])
    }

    /// #6 (was a known gap): cancelling the task that consumes the stream
    /// cancels the underlying copy. The stream form cleans up in the background,
    /// so the partial file's removal is awaited here; the awaited form
    /// (`copy(…onState:)`) is covered by `FileOperationCancellationTests`.
    func testCancelDuringCopyStopsTheOperation() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = tempDir.appendingPathComponent("cancelled.bin")
        let before = try snapshot(source)
        let duringCopy = provider.pauseRead(of: source, beforeChunk: 1)
        let duringVerification = provider.pauseRead(of: destination, beforeChunk: 0)
        let operation = Task { await copy(source, to: destination) }

        let reachedCopy = await duringCopy.waitUntilReached()
        XCTAssertTrue(reachedCopy)
        XCTAssertEqual(try partialFiles(in: tempDir).count, 1)
        operation.cancel()
        duringCopy.release()
        _ = await operation.value

        // A cancelled copy must never get as far as verifying.
        let continued = await duringVerification.waitUntilReached(timeout: 5)
        XCTAssertFalse(continued, "copy kept running after cancel")
        duringVerification.release()
        let finished = await provider.waitUntilReadsFinished(of: source)
        XCTAssertTrue(finished, "the source read stopped")
        XCTAssertEqual(provider.bytesDelivered(from: source), Int64(Self.chunkSize), "no byte read after the cancel")
        let cleanedUp = await waitUntil { (try? self.partialFiles(in: self.tempDir).isEmpty) == true }
        XCTAssertTrue(cleanedUp, "partial file removed")
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        try assertUnchanged(before)
    }

    /// `ChunkedWriter` temporary (partial) files in `directory`.
    private func partialFiles(in directory: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: directory.path).filter(ChunkedWriter.isTemporaryFileName)
    }

    /// Polls `condition` until it holds; false after `timeout`.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)  // test polling; the deadline bounds the wait
        }
        return true
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
        let nfcName = FixtureTree.Path.nfcName
        // Guarantee today: every visible file and folder, byte-exact, including NFD, emoji and long names.
        assertTreeSnapshot(copied, matches: before,
                       comparator: TreeComparator(checks: .data, excluding: { TreeComparator.isHidden($0) || $0 == nfcName }))
        XCTExpectFailure("#9: copyDirectory skips hidden files and folders", options: .treeDifferencesOnly) {
            assertTreeSnapshot(copied, matches: before,
                           comparator: TreeComparator(checks: [.presence], excluding: { !TreeComparator.isHidden($0) }))
        }
        XCTExpectFailure("#48: copyDirectory rewrites an NFC file name to NFD", options: .treeDifferencesOnly) {
            assertTreeSnapshot(copied, matches: before,
                           comparator: TreeComparator(checks: .data, excluding: { !$0.hasPrefix("unicode/nfc/") }))
        }
        for check in [TreeComparator.Checks.mtime, .permissions, .xattrs] {
            XCTExpectFailure("#30: folder copies do not preserve metadata (check \(check.rawValue))", options: .treeDifferencesOnly) {
                assertTreeSnapshot(copied, matches: before, comparator: TreeComparator(checks: check, excluding: TreeComparator.isHidden))
            }
        }
    }

    func testFolderCopyWithSymlinks_knownGap9() async throws {
        let tree = try makeFixture("tree", symlinks: true)
        let destination = tempDir.appendingPathComponent("copy", isDirectory: true)
        let before = try snapshot(tree.root)

        let outcome = await copyDirectory(tree.root, to: destination)

        try assertUnchanged(before)
        XCTExpectFailure("#9: folder copy fails on symlinks (to file, to dir, dangling, loop)") {
            XCTAssertNil(outcome.error)
        }
        let links = { (path: String) in !(path == "." || path == "links" || path.hasPrefix("links/")) }
        XCTExpectFailure("#9: folder copy does not recreate symlinks", options: .treeDifferencesOnly) {
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
        assertTreeSnapshot(moved, matches: before, comparator: TreeComparator(checks: .data))
        XCTExpectFailure("#30: cross-volume moves do not preserve mtime", options: .treeDifferencesOnly) {
            assertTreeSnapshot(moved, matches: before, comparator: TreeComparator(checks: .mtime))
        }
        XCTExpectFailure("#30: cross-volume moves do not preserve permissions", options: .treeDifferencesOnly) {
            assertTreeSnapshot(moved, matches: before, comparator: TreeComparator(checks: .permissions))
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
        assertTree(destination, matches: before, comparator: TreeComparator(checks: .data))
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
        assertTree(destination, matches: before, comparator: TreeComparator(checks: .data), "verified destination is kept")
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
        XCTExpectFailure("#9: moving a folder across volumes fails") {
            XCTAssertNil(outcome.error)
        }
        XCTExpectFailure("#9: moving a folder across volumes leaves no destination folder") {
            XCTAssertTrue(fm.fileExists(atPath: destination.path))
        }
    }
}
