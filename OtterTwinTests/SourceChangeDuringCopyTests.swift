import XCTest
import Darwin
@testable import OtterTwin

/// #54: a copy must fail when its source changes while it is copied. Both
/// hashes cover only the bytes that were read, so without a check a truncated
/// (or grown, or rewritten) source gave a "verified" copy. Also: a copy whose
/// replace cannot put the original back says where the original is kept
/// (`.originalNotRestored`), as moves do since #52.
///
/// Uses the data-safety harness: `FaultInjectingProvider` pause points stop the
/// copy exactly between two chunk reads (or exactly at the start of
/// verification), the test changes the source there, then lets it continue.
final class SourceChangeDuringCopyTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var provider: FaultInjectingProvider!

    private static let chunkSize = 64 * 1024
    private static let sourceSize = 3 * chunkSize + 11
    /// A fixed, old mtime for every source, so any write during the copy changes it.
    private static let sourceMtime = timespec(tv_sec: 1_000_000_000, tv_nsec: 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("SourceChangeDuringCopyTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        resetProvider()
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

    private func resetProvider() {
        provider = FaultInjectingProvider(fakeTrash: tempDir.appendingPathComponent("FakeTrash", isDirectory: true))
    }

    private func makeService(checksumEnabled: Bool) -> FileOperationService {
        let settings = SettingsService()
        settings.setChecksumEnabled(checksumEnabled, userConfirmedDisable: !checksumEnabled)
        settings.setChunkSizeBytes(Self.chunkSize)
        return FileOperationService(settings: settings)
    }

    /// A source file in its own folder, with an old, fixed mtime.
    private func makeSource(_ label: String) throws -> URL {
        let folder = tempDir.appendingPathComponent("src-\(label)", isDirectory: true)
        try HarnessPOSIX.makeDirectory(folder.path)
        let url = folder.appendingPathComponent("source.bin")
        try HarnessPOSIX.writeFile(url.path, data: FixtureTree.content(for: label, size: Self.sourceSize, seed: 54))
        try HarnessPOSIX.setMtime(url.path, Self.sourceMtime)
        return url
    }

    /// An empty destination folder.
    private func makeFolder(_ label: String) throws -> URL {
        let folder = tempDir.appendingPathComponent("out-\(label)", isDirectory: true)
        try HarnessPOSIX.makeDirectory(folder.path)
        return folder
    }

    /// The existing destination file for `.overwrite`, and a snapshot of it.
    private func makeOriginal(in folder: URL) throws -> (URL, TreeSnapshot) {
        let url = folder.appendingPathComponent("existing.bin")
        try HarnessPOSIX.writeFile(url.path, data: FixtureTree.content(for: "original", size: 5_000, seed: 1))
        return (url, try TreeSnapshot.capture(url))
    }

    /// How the test changes the source while it is being copied.
    enum Change: String, CaseIterable {
        /// Truncated to one and a half chunks (fewer bytes left to read).
        case truncate
        /// 5000 bytes appended (more bytes than at the start).
        case grow
        /// Same size, bytes after the current read position rewritten: only the mtime tells.
        case rewriteSameSize
        /// Replaced by a rename (like `rsync -a` or `cp -p` via a temporary
        /// file) with a file of the same size and mtime: only device and inode
        /// tell. The copy keeps reading the old file through its open descriptor.
        case replaceSameSizeAndMtime

        /// What `.replaceSameSizeAndMtime` puts at the source path.
        static let replacement = Data(repeating: 0x3C, count: SourceChangeDuringCopyTests.sourceSize)

        func apply(to url: URL) throws {
            if self == .replaceSameSizeAndMtime {
                let staging = url.deletingLastPathComponent().appendingPathComponent(".replacement.tmp")
                try HarnessPOSIX.writeFile(staging.path, data: Self.replacement)
                try HarnessPOSIX.setMtime(staging.path, SourceChangeDuringCopyTests.sourceMtime)
                guard Darwin.rename(staging.path, url.path) == 0 else {
                    throw HarnessError.posix("rename", staging.path)
                }
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }  // test helper; the write itself already threw if it failed
            switch self {
            case .truncate:
                try handle.truncate(atOffset: UInt64(SourceChangeDuringCopyTests.chunkSize * 3 / 2))
            case .grow:
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0xA5, count: 5_000))
            case .rewriteSameSize:
                try handle.seek(toOffset: UInt64(2 * SourceChangeDuringCopyTests.chunkSize))
                try handle.write(contentsOf: Data(repeating: 0x5A, count: 1_000))
            case .replaceSameSizeAndMtime:
                break  // handled above
            }
            try handle.synchronize()
        }
    }

    final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [OperationState] = []
        var states: [OperationState] { lock.withLock { _states } }
        func record(_ state: OperationState) { lock.withLock { _states.append(state) } }

        /// Whether the operation ever reported success.
        var reportedSuccess: Bool {
            states.contains { state in
                switch state {
                case .complete, .partiallyComplete: return true
                default: return false
                }
            }
        }
    }

    private struct Outcome {
        var error: Error?
        var log: StateLog

        var isSourceChanged: Bool {
            if case .sourceChanged? = error as? OperationError { return true }
            return false
        }
    }

    /// Runs a copy (or a move) in its own task, in the awaited form: the task
    /// ends only once the operation and its cleanup are over.
    private func start(_ kind: OperationKind, _ source: URL, to destination: URL,
                       conflict: ConflictResolution, checksum: Bool = true) -> Task<Outcome, Never> {
        let service = makeService(checksumEnabled: checksum)
        let provider = provider!
        return Task {
            let log = StateLog()
            do {
                switch kind {
                case .copy:
                    try await service.copy(source: source, destination: destination, provider: provider,
                                           conflictResolution: conflict, onState: { log.record($0) })
                case .move:
                    try await service.move(source: source, destination: destination, provider: provider,
                                           conflictResolution: conflict, onState: { log.record($0) })
                }
                return Outcome(error: nil, log: log)
            } catch {
                return Outcome(error: error, log: log)
            }
        }
    }

    /// Starts the operation, waits at `pause`, changes the source there, lets it continue.
    private func runChanging(_ source: URL, by change: Change, at pause: PausePoint,
                             _ operation: Task<Outcome, Never>, _ label: String) async throws -> Outcome {
        let reached = await pause.waitUntilReached()
        XCTAssertTrue(reached, "\(label): pause point reached")
        do {
            try change.apply(to: source)
        } catch {
            pause.release()
            _ = await operation.value
            throw error
        }
        pause.release()
        return await operation.value
    }

    /// The folder holds exactly `names`: no partial (`.part`) or parked
    /// original (`.old`), nothing else.
    private func assertContents(of folder: URL, are names: [String], _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        do {
            let found = try fm.contentsOfDirectory(atPath: folder.path).sorted()
            XCTAssertEqual(found, names.sorted(), message, file: file, line: line)
        } catch {
            XCTFail("\(message): cannot list \(folder.path): \(error)", file: file, line: line)
        }
    }

    // MARK: - Source changes while it is copied

    /// Truncate, grow or rewrite the source after its first chunk was copied,
    /// for a new destination and for `.overwrite`, with checksums on and off:
    /// the copy fails with `.sourceChanged`, nothing appears at a new
    /// destination, an existing one stays byte-identical, and no partial file
    /// is left.
    func testSourceChangedMidCopyFailsAndLeavesTheDestinationUntouched() async throws {
        for change in Change.allCases {
            for overwrite in [false, true] {
                for checksum in [true, false] {
                    let label = "\(change.rawValue)-\(overwrite ? "overwrite" : "new")-\(checksum ? "verify" : "noverify")"
                    resetProvider()
                    let source = try makeSource(label)
                    let folder = try makeFolder(label)
                    var original: TreeSnapshot?
                    let destination: URL
                    if overwrite {
                        let (url, snapshot) = try makeOriginal(in: folder)
                        destination = url
                        original = snapshot
                    } else {
                        destination = folder.appendingPathComponent("copy.bin")
                    }
                    let duringCopy = provider.pauseRead(of: source, beforeChunk: 1)
                    let operation = start(.copy, source, to: destination,
                                          conflict: overwrite ? .overwrite : .skip, checksum: checksum)

                    let outcome = try await runChanging(source, by: change, at: duringCopy, operation, label)

                    XCTAssertTrue(outcome.isSourceChanged, "\(label): \(String(describing: outcome.error))")
                    XCTAssertFalse(outcome.log.reportedSuccess, "\(label): never reported as success: \(outcome.log.states)")
                    XCTAssertTrue(provider.verificationOpens.isEmpty,
                                  "\(label): caught by the check after the last chunk, before verification")
                    if let original {
                        assertTree(destination, matches: original, comparator: TreeComparator(checks: .data),
                                   "\(label): original destination byte-identical")
                        assertContents(of: folder, are: ["existing.bin"], "\(label): no partial or .old file left")
                    } else {
                        XCTAssertFalse(fm.fileExists(atPath: destination.path), "\(label): no destination created")
                        assertContents(of: folder, are: [], "\(label): no partial file left")
                    }
                }
            }
        }
    }

    /// The source is truncated while the finished copy is being verified (the
    /// copy itself read the whole, unchanged file): the check before `commit()`
    /// catches it, so the destination is never touched.
    func testSourceChangedDuringVerificationFailsBeforeCommit() async throws {
        for overwrite in [false, true] {
            let label = "verification-\(overwrite ? "overwrite" : "new")"
            resetProvider()
            let source = try makeSource(label)
            let folder = try makeFolder(label)
            var original: TreeSnapshot?
            let destination: URL
            if overwrite {
                let (url, snapshot) = try makeOriginal(in: folder)
                destination = url
                original = snapshot
            } else {
                destination = folder.appendingPathComponent("copy.bin")
            }
            let atVerification = provider.pauseRead(of: destination, beforeChunk: 0)
            let operation = start(.copy, source, to: destination, conflict: overwrite ? .overwrite : .skip)

            let outcome = try await runChanging(source, by: .truncate, at: atVerification, operation, label)

            XCTAssertEqual(provider.verificationOpens.count, 1, "\(label): the copy reached verification")
            XCTAssertTrue(outcome.isSourceChanged, "\(label): \(String(describing: outcome.error))")
            XCTAssertFalse(outcome.log.reportedSuccess, "\(label): never reported as success: \(outcome.log.states)")
            if let original {
                assertTree(destination, matches: original, comparator: TreeComparator(checks: .data),
                           "\(label): original destination byte-identical")
                assertContents(of: folder, are: ["existing.bin"], "\(label): no partial or .old file left")
            } else {
                XCTAssertFalse(fm.fileExists(atPath: destination.path), "\(label): no destination created")
                assertContents(of: folder, are: [], "\(label): no partial file left")
            }
        }
    }

    /// A move that copies (here: the rename reports `EXDEV`, so it falls back
    /// to the verified copy) never deletes a source that changed while it was
    /// copied.
    func testMoveKeepsASourceThatChangedMidCopy() async throws {
        let label = "move"
        let source = try makeSource(label)
        let folder = try makeFolder(label)
        let destination = folder.appendingPathComponent("moved.bin")
        provider.moveErrors = [source: POSIXError(.EXDEV)]
        let duringCopy = provider.pauseRead(of: source, beforeChunk: 1)
        let operation = start(.move, source, to: destination, conflict: .skip, checksum: false)

        let outcome = try await runChanging(source, by: .truncate, at: duringCopy, operation, label)

        XCTAssertTrue(outcome.isSourceChanged, String(describing: outcome.error))
        XCTAssertFalse(outcome.log.reportedSuccess, "never reported as success: \(outcome.log.states)")
        XCTAssertEqual(provider.moveCalls.count, 1, "the rename was tried first")
        XCTAssertTrue(provider.deleteCalls.isEmpty, "the source is not deleted")
        XCTAssertTrue(fm.fileExists(atPath: source.path), "the source is kept")
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "no destination created")
        assertContents(of: folder, are: [], "no partial file left")
    }

    /// A move whose source is replaced by a rename (same size, same mtime)
    /// mid-copy fails, and the new file at the source path survives.
    func testMoveKeepsASourceReplacedWithTheSameSizeAndMtime() async throws {
        let label = "move-replaced"
        let source = try makeSource(label)
        let folder = try makeFolder(label)
        let destination = folder.appendingPathComponent("moved.bin")
        provider.moveErrors = [source: POSIXError(.EXDEV)]
        let duringCopy = provider.pauseRead(of: source, beforeChunk: 1)
        let operation = start(.move, source, to: destination, conflict: .skip, checksum: false)

        let outcome = try await runChanging(source, by: .replaceSameSizeAndMtime, at: duringCopy, operation, label)

        XCTAssertTrue(outcome.isSourceChanged, String(describing: outcome.error))
        XCTAssertFalse(outcome.log.reportedSuccess, "never reported as success: \(outcome.log.states)")
        XCTAssertTrue(provider.verificationOpens.isEmpty, "caught before verification")
        XCTAssertTrue(provider.deleteCalls.isEmpty, "the source is not deleted")
        XCTAssertEqual(try Data(contentsOf: source), Change.replacement, "the new file at the source path survives")
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "no destination created")
        assertContents(of: folder, are: [], "no partial file left")
    }

    /// A move whose source changes while the copy is verified (the copy read
    /// the whole, unchanged file): the check before `commit()` fails it, the
    /// source is not deleted and the destination is untouched.
    func testMoveKeepsASourceThatChangedDuringVerification() async throws {
        for overwrite in [false, true] {
            let label = "move-verification-\(overwrite ? "overwrite" : "new")"
            resetProvider()
            let source = try makeSource(label)
            let folder = try makeFolder(label)
            var original: TreeSnapshot?
            let destination: URL
            if overwrite {
                let (url, snapshot) = try makeOriginal(in: folder)
                destination = url
                original = snapshot
            } else {
                destination = folder.appendingPathComponent("moved.bin")
            }
            provider.moveErrors = [source: POSIXError(.EXDEV)]
            let atVerification = provider.pauseRead(of: destination, beforeChunk: 0)
            let operation = start(.move, source, to: destination,
                                  conflict: overwrite ? .overwrite : .skip, checksum: false)

            let outcome = try await runChanging(source, by: .grow, at: atVerification, operation, label)

            XCTAssertEqual(provider.verificationOpens.count, 1, "\(label): the copy reached verification")
            XCTAssertTrue(outcome.isSourceChanged, "\(label): \(String(describing: outcome.error))")
            XCTAssertFalse(outcome.log.reportedSuccess, "\(label): never reported as success: \(outcome.log.states)")
            XCTAssertTrue(provider.deleteCalls.isEmpty, "\(label): the source is not deleted")
            XCTAssertEqual(try HarnessPOSIX.lstat(source.path).st_size, Int64(Self.sourceSize + 5_000),
                           "\(label): the changed source is kept")
            if let original {
                assertTree(destination, matches: original, comparator: TreeComparator(checks: .data),
                           "\(label): original destination byte-identical")
                assertContents(of: folder, are: ["existing.bin"], "\(label): no partial or .old file left")
            } else {
                XCTAssertFalse(fm.fileExists(atPath: destination.path), "\(label): no destination created")
                assertContents(of: folder, are: [], "\(label): no partial file left")
            }
        }
    }

    /// The source changes after the copy was committed, right before a move
    /// would delete it (`finalizeHooks` runs right after `commit()`): the
    /// verified copy and the changed source are both kept, and the move ends
    /// `.partiallyComplete(…, .sourceNotRemoved)`, not as a plain success.
    func testMoveKeepsASourceThatChangedAfterTheCommit() async throws {
        for change in [Change.grow, .replaceSameSizeAndMtime] {
            let label = "move-after-commit-\(change.rawValue)"
            resetProvider()
            let source = try makeSource(label)
            let copied = try TreeSnapshot.capture(source)
            let folder = try makeFolder(label)
            let destination = folder.appendingPathComponent("moved.bin")
            provider.moveErrors = [source: POSIXError(.EXDEV)]
            let hookErrors = HookErrors()
            provider.finalizeHooks = [destination: {
                do { try change.apply(to: source) } catch { hookErrors.record(error) }
            }]

            let outcome = await start(.move, source, to: destination, conflict: .skip, checksum: false).value

            XCTAssertTrue(hookErrors.errors.isEmpty, "\(label): \(hookErrors.errors)")
            XCTAssertNil(outcome.error, "\(label): not a failure")
            guard case .partiallyComplete(let result, let issue)? = outcome.log.states.last else {
                XCTFail("\(label): expected .partiallyComplete, got \(String(describing: outcome.log.states.last))")
                continue
            }
            guard case .verified = result else {
                XCTFail("\(label): expected a verified copy, got \(result)")
                continue
            }
            guard case .sourceNotRemoved(let error) = issue else {
                XCTFail("\(label): expected .sourceNotRemoved, got \(issue)")
                continue
            }
            XCTAssertTrue(error is SourceChangedAfterCopyError, "\(label): \(error)")
            XCTAssertFalse(outcome.log.states.contains { if case .complete = $0 { return true } else { return false } },
                           "\(label): never reported as plain success")
            XCTAssertTrue(provider.deleteCalls.isEmpty, "\(label): the source is not deleted")
            XCTAssertTrue(fm.fileExists(atPath: source.path), "\(label): the changed source is kept")
            if change == .replaceSameSizeAndMtime {
                XCTAssertEqual(try Data(contentsOf: source), Change.replacement, "\(label): the new file survives")
            }
            assertTree(destination, matches: copied, comparator: TreeComparator(checks: .data),
                       "\(label): the verified copy of the original source is kept")
        }
    }

    /// Errors thrown inside a `finalizeHooks` closure.
    final class HookErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors: [Error] = []
        var errors: [Error] { lock.withLock { _errors } }
        func record(_ error: Error) { lock.withLock { _errors.append(error) } }
    }

    /// Control: an unchanged source with the same old mtime copies and verifies as before.
    func testUnchangedSourceStillCopies() async throws {
        let source = try makeSource("unchanged")
        let before = try TreeSnapshot.capture(source)
        let folder = try makeFolder("unchanged")
        let destination = folder.appendingPathComponent("copy.bin")

        let outcome = await start(.copy, source, to: destination, conflict: .skip).value

        XCTAssertNil(outcome.error)
        guard case .complete(result: .verified)? = outcome.log.states.last else {
            return XCTFail("expected .verified, got \(String(describing: outcome.log.states.last))")
        }
        assertTree(destination, matches: before, comparator: TreeComparator(checks: .data), "byte-exact copy")
        assertTree(source, matches: before, "source untouched")
        assertContents(of: folder, are: ["copy.bin"], "no partial file left")
    }

    // MARK: - Failed commit whose restore fails (copy)

    /// `.overwrite` without `RENAME_SWAP` (smbfs, ExFAT): the original is
    /// parked as `.old`, moving the verified copy in fails, and putting the
    /// original back fails too. The copy fails with `.originalNotRestored`
    /// naming where the original is kept, which still holds it byte-identical;
    /// the partial file is removed and the source is untouched.
    func testCopyOverwriteWhoseCommitAndRestoreFailReportsTheParkedOriginal() async throws {
        let source = try makeSource("restore")
        let sourceBefore = try TreeSnapshot.capture(source)
        let folder = try makeFolder("restore")
        let (destination, _) = try makeOriginal(in: folder)
        let original = try Data(contentsOf: destination)
        provider.rename = .withoutRenameFlags { from, _ in
            if ChunkedWriter.isDiscardablePartialFileName(from.lastPathComponent) { return EIO }  // the move-in fails
            if ChunkedWriter.isParkedOriginalFileName(from.lastPathComponent) { return EIO }  // the restore fails
            return nil
        }

        let outcome = await start(.copy, source, to: destination, conflict: .overwrite).value

        guard case .originalNotRestored(let parked, let underlying)? = outcome.error as? OperationError else {
            return XCTFail("expected OperationError.originalNotRestored, got \(String(describing: outcome.error))")
        }
        XCTAssertEqual((underlying as? POSIXError)?.code, .EIO, "\(underlying)")
        XCTAssertFalse(outcome.log.reportedSuccess, "never reported as success: \(outcome.log.states)")
        XCTAssertEqual(provider.verificationOpens.count, 1, "the copy was verified before the commit")
        let parkedURL = try XCTUnwrap(parked, "the error names where the original is kept")
        XCTAssertTrue(ChunkedWriter.isParkedOriginalFileName(parkedURL.lastPathComponent), parkedURL.lastPathComponent)
        XCTAssertEqual(parkedURL.deletingLastPathComponent().standardizedFileURL.path,
                       folder.standardizedFileURL.path, "in the destination folder")
        XCTAssertEqual(try Data(contentsOf: parkedURL), original, "the original survives, byte-identical")
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "nothing was put in the original's place")
        assertContents(of: folder, are: [parkedURL.lastPathComponent], "only the parked original; no partial file left")
        assertTree(source, matches: sourceBefore, "source untouched")
    }
}
