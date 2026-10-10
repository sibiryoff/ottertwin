import XCTest
import Darwin
@testable import OtterTwin

/// #27: atomic finalize. A copy is written to its temporary file, verified
/// there, and only then moved into place; `.overwrite` swaps it with the
/// existing destination (or, without `RENAME_SWAP`, parks the original under a
/// hidden `.old` name and restores it on failure). Every scenario runs on the
/// same volume (with the native rename flags and with the fallback that smbfs,
/// ExFAT and FAT need), across volumes onto APFS, and onto a real ExFAT volume.
final class AtomicFinalizeTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var provider: FaultInjectingProvider!

    private static let chunkSize = 64 * 1024

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("AtomicFinalizeTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        provider = nil
        try super.tearDownWithError()
    }

    // MARK: - Setups

    /// Where the destination lives and how the copy is finalized.
    enum Setup: String, CaseIterable {
        /// Same volume as the source (the test's temp folder, APFS): `RENAME_EXCL` / `RENAME_SWAP`.
        case sameVolume
        /// Same volume, simulating a file system without rename flags (smbfs, ExFAT, FAT): the fallback.
        case sameVolumeWithoutRenameFlags
        /// Another APFS volume.
        case crossVolumeAPFS
        /// A real ExFAT volume: no `RENAME_SWAP`, so the fallback (see `AtomicRenameTests.testExFATHasNoRenameSwap`).
        case crossVolumeExFAT

        var usesFallback: Bool { self == .sameVolumeWithoutRenameFlags || self == .crossVolumeExFAT }
    }

    /// Records the renames that finalize a copy, then performs them with `base`.
    final class RenameLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(to: URL, flags: UInt32, result: Int32)] = []
        var calls: [(to: URL, flags: UInt32, result: Int32)] { lock.withLock { _calls } }

        func recording(_ base: AtomicRename) -> AtomicRename {
            AtomicRename { from, to, flags in
                let result = base.renamex(from, to, flags)
                self.lock.withLock { self._calls.append((URL(fileURLWithPath: to), flags, result)) }
                return result
            }
        }
    }

    /// An empty destination folder for `setup`, and a fresh provider configured for it.
    private func prepare(_ setup: Setup, _ label: String = "out") throws -> URL {
        let folder: URL
        switch setup {
        case .sameVolume, .sameVolumeWithoutRenameFlags:
            folder = tempDir.appendingPathComponent("\(label)-\(setup.rawValue)", isDirectory: true)
        case .crossVolumeAPFS:
            folder = try makeScratchVolume(.apfs).mountPoint.appendingPathComponent(label, isDirectory: true)
        case .crossVolumeExFAT:
            folder = try makeScratchVolume(.exfat).mountPoint.appendingPathComponent(label, isDirectory: true)
        }
        try HarnessPOSIX.makeDirectory(folder.path)
        resetProvider(for: setup)
        return folder
    }

    private func resetProvider(for setup: Setup) {
        provider = FaultInjectingProvider(fakeTrash: tempDir.appendingPathComponent("FakeTrash", isDirectory: true))
        provider.rename = setup == .sameVolumeWithoutRenameFlags ? .withoutRenameFlags() : .system
    }

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

    /// The existing destination file and a snapshot of it.
    private func makeOriginal(in folder: URL, name: String = "existing.bin") throws -> (URL, TreeSnapshot) {
        let url = folder.appendingPathComponent(name)
        try HarnessPOSIX.writeFile(url.path, data: FixtureTree.content(for: "original", size: 5_000, seed: 1))
        return (url, try TreeSnapshot.capture(url))
    }

    private struct Outcome {
        var error: Error?
        var result: VerificationResult?

        var isVerified: Bool { if case .verified? = result { return true } else { return false } }
        var isCancelled: Bool { if case .cancelled? = error as? OperationError { return true } else { return false } }
        var isChecksumMismatch: Bool {
            if case .checksumMismatch? = error as? OperationError { return true } else { return false }
        }
        var conflictURL: URL? {
            if case .conflict(let url)? = error as? OperationError { return url } else { return nil }
        }
        var injectedFault: InjectedFault? {
            if case .ioError(let underlying)? = error as? OperationError { return underlying as? InjectedFault }
            return nil
        }
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _result: VerificationResult?
        var result: VerificationResult? { lock.withLock { _result } }
        func record(_ state: OperationState) {
            if case .complete(let result) = state { lock.withLock { _result = result } }
        }
    }

    /// Runs a copy or move in its own task, in the awaited form: the task ends
    /// only once the operation and its cleanup are over.
    private func start(_ kind: OperationKind, _ source: URL, to destination: URL,
                       conflict: ConflictResolution = .overwrite, checksum: Bool = true) -> Task<Outcome, Never> {
        let service = makeService(checksumEnabled: checksum)
        let provider = provider!
        return Task {
            let box = ResultBox()
            do {
                switch kind {
                case .copy:
                    try await service.copy(source: source, destination: destination, provider: provider,
                                           conflictResolution: conflict, onState: { box.record($0) })
                case .move:
                    try await service.move(source: source, destination: destination, provider: provider,
                                           conflictResolution: conflict, onState: { box.record($0) })
                }
                return Outcome(error: nil, result: box.result)
            } catch {
                return Outcome(error: error, result: box.result)
            }
        }
    }

    private func run(_ kind: OperationKind, _ source: URL, to destination: URL,
                     conflict: ConflictResolution = .overwrite, checksum: Bool = true) async -> Outcome {
        await start(kind, source, to: destination, conflict: conflict, checksum: checksum).value
    }

    /// The folder holds exactly `names`: no partial (`.part`) or parked
    /// original (`.old`), nothing else. AppleDouble (`._*`) files that macOS
    /// may add on ExFAT are not ours and are ignored.
    private func assertContents(of folder: URL, are names: [String], _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        do {
            let found = try fm.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix("._") }.sorted()
            XCTAssertEqual(found, names.sorted(), message, file: file, line: line)
        } catch {
            XCTFail("\(message): cannot list \(folder.path): \(error)", file: file, line: line)
        }
    }

    // MARK: - Replace: failures keep the original

    func testReplaceFailingMidCopyKeepsTheOriginalByteIdentical() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let sourceBefore = try TreeSnapshot.capture(source)

        for setup in Setup.allCases {
            let folder = try prepare(setup)
            let (destination, original) = try makeOriginal(in: folder)
            let faults: [(String, (FaultInjectingProvider) -> Void)] = [
                ("write fault", { $0.writeFaults = [destination: ByteFault(offset: Int64(Self.chunkSize + 5))] }),
                ("source read fault", { $0.readFaults = [source: ByteFault(offset: Int64(2 * Self.chunkSize))] }),
                ("close fault", { $0.closeFaults = [destination: InjectedFault(message: "flush failed")] }),
                ("verification read fault", { $0.readFaults = [destination: ByteFault(offset: 10)] }),
            ]
            for (name, inject) in faults {
                let label = "\(setup.rawValue), \(name)"
                resetProvider(for: setup)
                inject(provider)

                let outcome = await run(.copy, source, to: destination)

                XCTAssertNotNil(outcome.injectedFault, "\(label): \(String(describing: outcome.error))")
                assertTree(destination, matches: original, comparator: TreeComparator(checks: .data),
                           "\(label): original destination byte-identical")
                assertContents(of: folder, are: ["existing.bin"], "\(label): no partial or .old file left")
            }
        }
        assertTree(source, matches: sourceBefore, "source unchanged")
    }

    func testReplaceWithCorruptedWriteKeepsTheOriginal() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)

        for setup in Setup.allCases {
            let folder = try prepare(setup)
            let (destination, original) = try makeOriginal(in: folder)
            provider.corruptions = [destination: Int64(Self.chunkSize + 3)]

            let outcome = await run(.copy, source, to: destination)

            XCTAssertTrue(outcome.isChecksumMismatch, "\(setup.rawValue): \(String(describing: outcome.error))")
            assertTree(destination, matches: original, comparator: TreeComparator(checks: .data),
                       "\(setup.rawValue): original destination intact")
            assertContents(of: folder, are: ["existing.bin"], "\(setup.rawValue): no partial or .old file left")
        }
    }

    func testCancelDuringReplaceKeepsTheOriginalAndLeavesNothing() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let sourceBefore = try TreeSnapshot.capture(source)

        for setup in Setup.allCases {
            let folder = try prepare(setup)
            let (destination, original) = try makeOriginal(in: folder)
            for phase in ["copy", "verification"] {
                let label = "\(setup.rawValue), cancel during \(phase)"
                resetProvider(for: setup)
                let pause = phase == "copy"
                    ? provider.pauseRead(of: source, beforeChunk: 2)
                    : provider.pauseRead(of: destination, beforeChunk: 1)

                let operation = start(.copy, source, to: destination)
                let reached = await pause.waitUntilReached()
                XCTAssertTrue(reached, label)
                // The original is still in place, untouched, while the new copy is in flight.
                assertTree(destination, matches: original, comparator: TreeComparator(checks: .data), "\(label): mid-operation")
                operation.cancel()
                pause.release()
                let outcome = await operation.value

                XCTAssertTrue(outcome.isCancelled, "\(label): \(String(describing: outcome.error))")
                assertTree(destination, matches: original, comparator: TreeComparator(checks: .data),
                           "\(label): original destination intact")
                assertContents(of: folder, are: ["existing.bin"], "\(label): no partial or .old file left")
            }
        }
        assertTree(source, matches: sourceBefore, "source unchanged")
    }

    // MARK: - Replace: success

    func testSuccessfulReplaceMakesTheDestinationEqualToTheSource() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let sourceBefore = try TreeSnapshot.capture(source)

        for setup in Setup.allCases {
            let folder = try prepare(setup)
            let (destination, _) = try makeOriginal(in: folder)
            let renames = RenameLog()
            provider.rename = renames.recording(provider.rename)
            // The original stays in place throughout the copy and the verification.
            let duringVerification = provider.pauseRead(of: destination, beforeChunk: 0)
            let operation = start(.copy, source, to: destination)
            let reached = await duringVerification.waitUntilReached()
            XCTAssertTrue(reached, setup.rawValue)
            XCTAssertEqual(try HarnessPOSIX.lstat(destination.path).st_size, 5_000,
                           "\(setup.rawValue): the original is untouched until the copy is verified")
            XCTAssertTrue(renames.calls.isEmpty, "\(setup.rawValue): nothing renamed before verification")
            duringVerification.release()
            let outcome = await operation.value

            XCTAssertNil(outcome.error, setup.rawValue)
            XCTAssertTrue(outcome.isVerified, setup.rawValue)
            assertTreesEqual(expected: source, actual: destination, comparator: TreeComparator(checks: .data), setup.rawValue)
            assertContents(of: folder, are: ["existing.bin"], "\(setup.rawValue): the original and the partial are gone")

            let swapped = renames.calls.contains { $0.flags == UInt32(RENAME_SWAP) && $0.result == 0 }
            let parkedOriginal = renames.calls.contains { $0.result == 0 && $0.to.lastPathComponent.hasSuffix(".old") }
            if setup.usesFallback {
                XCTAssertFalse(swapped, "\(setup.rawValue): \(renames.calls)")
                XCTAssertTrue(parkedOriginal, "\(setup.rawValue): the fallback parks the original: \(renames.calls)")
            } else {
                XCTAssertTrue(swapped, "\(setup.rawValue): \(renames.calls)")
                XCTAssertFalse(parkedOriginal, "\(setup.rawValue): \(renames.calls)")
            }
        }
        assertTree(source, matches: sourceBefore, "source unchanged")
    }

    func testReplaceWithChecksumOffStillReplacesAtomically() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.chunkPlusOne)

        for setup in Setup.allCases {
            let folder = try prepare(setup)
            let (destination, _) = try makeOriginal(in: folder)

            let outcome = await run(.copy, source, to: destination, checksum: false)

            XCTAssertNil(outcome.error, setup.rawValue)
            assertTreesEqual(expected: source, actual: destination, comparator: TreeComparator(checks: .data), setup.rawValue)
            assertContents(of: folder, are: ["existing.bin"], setup.rawValue)
        }
    }

    // MARK: - New destination: someone else creates it meanwhile

    func testDestinationCreatedBySomeoneElseDuringCopyIsAConflict() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let theirs = Data("someone else's file".utf8)

        for setup in Setup.allCases {
            let folder = try prepare(setup)
            for phase in ["copy", "verification"] {
                let label = "\(setup.rawValue), created during \(phase)"
                resetProvider(for: setup)
                let destination = folder.appendingPathComponent("new-\(phase).bin")
                let pause = phase == "copy"
                    ? provider.pauseRead(of: source, beforeChunk: 1)
                    : provider.pauseRead(of: destination, beforeChunk: 1)

                let operation = start(.copy, source, to: destination, conflict: .skip)
                let reached = await pause.waitUntilReached()
                XCTAssertTrue(reached, label)
                try HarnessPOSIX.writeFile(destination.path, data: theirs)
                pause.release()
                let outcome = await operation.value

                XCTAssertEqual(outcome.conflictURL, destination, "\(label): \(String(describing: outcome.error))")
                XCTAssertEqual(try Data(contentsOf: destination), theirs, "\(label): never overwritten")
            }
            assertContents(of: folder, are: ["new-copy.bin", "new-verification.bin"],
                           "\(setup.rawValue): only the other files, no partial file")
        }
    }

    // MARK: - Move with overwrite

    func testMoveReplacingTheDestination() async throws {
        for setup in Setup.allCases {
            let folder = try prepare(setup)
            let (destination, _) = try makeOriginal(in: folder)
            let source = tempDir.appendingPathComponent("move-source-\(setup.rawValue).bin")
            try HarnessPOSIX.writeFile(source.path, data: FixtureTree.content(for: "move", size: 3 * Self.chunkSize + 7, seed: 2))
            let sourceBefore = try TreeSnapshot.capture(source)

            let outcome = await run(.move, source, to: destination)

            XCTAssertNil(outcome.error, setup.rawValue)
            let sameVolume = setup == .sameVolume || setup == .sameVolumeWithoutRenameFlags
            if sameVolume {
                // #28: a same-volume move is a rename; there is nothing to verify.
                if case .renamed? = outcome.result {} else {
                    XCTFail("\(setup.rawValue): expected .renamed, got \(String(describing: outcome.result))")
                }
            } else {
                XCTAssertTrue(outcome.isVerified, setup.rawValue)
            }
            XCTAssertFalse(fm.fileExists(atPath: source.path), "\(setup.rawValue): source moved")
            assertTree(destination, matches: sourceBefore, comparator: TreeComparator(checks: .data), setup.rawValue)
            assertContents(of: folder, are: ["existing.bin"], setup.rawValue)
            XCTAssertEqual(provider.replaceCalls.count, sameVolume ? 1 : 0, "\(setup.rawValue): same-volume moves replace by rename")
            XCTAssertTrue(provider.deleteCalls.allSatisfy { $0 == source }, "\(setup.rawValue): nothing but the source deleted")
        }
    }

    func testFailedMoveReplacingTheDestinationKeepsBoth() async throws {
        for setup in Setup.allCases {
            let folder = try prepare(setup)
            let (destination, original) = try makeOriginal(in: folder)
            let source = tempDir.appendingPathComponent("move-source-\(setup.rawValue).bin")
            try HarnessPOSIX.writeFile(source.path, data: FixtureTree.content(for: "move", size: 3 * Self.chunkSize + 7, seed: 2))
            let sourceBefore = try TreeSnapshot.capture(source)
            let sameVolume = setup == .sameVolume || setup == .sameVolumeWithoutRenameFlags
            if sameVolume {
                provider.moveFaults = [source: InjectedFault(message: "rename failed")]
            } else {
                provider.corruptions = [destination: 7]
            }

            let outcome = await run(.move, source, to: destination)

            XCTAssertNotNil(outcome.error, setup.rawValue)
            assertTree(source, matches: sourceBefore, "\(setup.rawValue): source unchanged")
            assertTree(destination, matches: original, comparator: TreeComparator(checks: .data),
                       "\(setup.rawValue): original destination intact")
            assertContents(of: folder, are: ["existing.bin"], setup.rawValue)
            XCTAssertFalse(provider.deleteCalls.contains(source), "\(setup.rawValue): source never deleted")
        }
    }

    /// The copy has replaced the destination when the move is cancelled: the
    /// original is gone, so the verified copy is kept, and the source is not deleted.
    func testCancelAfterCrossVolumeMoveReplacedTheDestinationKeepsTheCopyAndTheSource() async throws {
        let folder = try prepare(.crossVolumeAPFS)
        let (destination, _) = try makeOriginal(in: folder)
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.multiChunk)
        let sourceBefore = try TreeSnapshot.capture(source)
        provider.finalizeHooks = [destination: { withUnsafeCurrentTask { $0?.cancel() } }]

        let outcome = await run(.move, source, to: destination, checksum: false)

        XCTAssertTrue(outcome.isCancelled, "\(String(describing: outcome.error))")
        assertTree(source, matches: sourceBefore, "source unchanged")
        XCTAssertTrue(provider.deleteCalls.isEmpty, "nothing deleted: \(provider.deleteCalls)")
        assertTreesEqual(expected: source, actual: destination, comparator: TreeComparator(checks: .data))
        assertContents(of: folder, are: ["existing.bin"], "no partial or .old file left")
    }

    // MARK: - Dangling symlink at the destination

    /// A dangling symlink at the destination is an existing item (`lstat`):
    /// `.skip` keeps it, `.rename` picks another name, `.overwrite` replaces
    /// the link itself (never its missing target).
    func testDanglingSymlinkAtTheDestinationIsAnExistingItem() async throws {
        let tree = try makeFixture()
        let source = tree.url(FixtureTree.Path.chunkPlusOne)
        let folder = try prepare(.sameVolume)
        let destination = folder.appendingPathComponent("link.bin")
        let missingTarget = folder.appendingPathComponent("missing-target").path

        try HarnessPOSIX.symlink(missingTarget, at: destination.path)
        let skipped = await run(.copy, source, to: destination, conflict: .skip)
        XCTAssertNil(skipped.error)
        if case .skipped? = skipped.result {} else { XCTFail("expected .skipped, got \(String(describing: skipped.result))") }
        XCTAssertEqual(try HarnessPOSIX.readLink(destination.path), Array(missingTarget.utf8), "link kept")

        let renamed = await run(.copy, source, to: destination, conflict: .rename)
        XCTAssertNil(renamed.error)
        assertTreesEqual(expected: source, actual: folder.appendingPathComponent("link-2.bin"),
                         comparator: TreeComparator(checks: .data))
        XCTAssertEqual(try HarnessPOSIX.readLink(destination.path), Array(missingTarget.utf8), "link kept")

        let replaced = await run(.copy, source, to: destination, conflict: .overwrite)
        XCTAssertNil(replaced.error)
        assertTreesEqual(expected: source, actual: destination, comparator: TreeComparator(checks: .data))
        XCTAssertFalse(fm.fileExists(atPath: missingTarget), "the link's target was never created")
        assertContents(of: folder, are: ["link.bin", "link-2.bin"], "no partial or .old file left")
    }

    // MARK: - Copy onto itself

    /// Overwriting a file with itself used to delete it before reading it.
    func testOverwritingAFileWithItselfKeepsIt() async throws {
        let folder = try prepare(.sameVolume)
        let (file, original) = try makeOriginal(in: folder)

        let outcome = await run(.copy, file, to: file)

        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.isVerified)
        assertTree(file, matches: original, comparator: TreeComparator(checks: .data))
        assertContents(of: folder, are: ["existing.bin"], "no partial or .old file left")
    }
}
