import XCTest
import Darwin
@testable import OtterTwin

/// #28: verification is meaningful. The copy is flushed to storage
/// (`F_FULLFSYNC`, falling back to `fsync` where unsupported) and closed, then
/// read back through a new descriptor with `F_NOCACHE`; the result records the
/// flush mode and whether the cache was bypassed. Uses the data-safety harness:
/// `FaultInjectingProvider` spies on the verification open (it opens with the
/// production `UncachedFileReader`), `ScratchVolume` provides ExFAT and FAT32.
final class VerificationDurabilityTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var provider: FaultInjectingProvider!

    private static let chunkSize = 64 * 1024

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("VerificationDurabilityTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeSource(_ name: String = "source.bin", size: Int = 3 * VerificationDurabilityTests.chunkSize + 11) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try HarnessPOSIX.writeFile(url.path, data: FixtureTree.content(for: name, size: size, seed: 28))
        return url
    }

    private struct Outcome {
        var states: [OperationState] = []
        var error: Error?

        var result: VerificationResult? {
            if case .complete(let result)? = states.last { return result }
            return nil
        }
        var flushMode: FlushMode? {
            if case .verified(_, _, let mode, _)? = result { return mode }
            return nil
        }
        var cacheBypassed: Bool? {
            if case .verified(_, _, _, let bypassed)? = result { return bypassed }
            return nil
        }
    }

    private func copy(_ source: URL, to destination: URL) async -> Outcome {
        var outcome = Outcome()
        do {
            for try await state in await makeService().copy(source: source, destination: destination, provider: provider) {
                outcome.states.append(state)
            }
        } catch {
            outcome.error = error
        }
        return outcome
    }

    private func move(_ source: URL, to destination: URL, conflict: ConflictResolution = .skip) async -> Outcome {
        var outcome = Outcome()
        do {
            // Checksums off: a move must verify whenever it copies anyway.
            for try await state in await makeService(checksumEnabled: false).move(
                source: source, destination: destination, provider: provider, conflictResolution: conflict) {
                outcome.states.append(state)
            }
        } catch {
            outcome.error = error
        }
        return outcome
    }

    private func partialFiles(in directory: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: directory.path).filter(ChunkedWriter.isDiscardablePartialFileName)
    }

    // MARK: - Fresh, uncached descriptor after close and flush

    func testVerificationOpensAFreshUncachedDescriptorAfterTheWriterFlushedAndClosed() async throws {
        let source = try makeSource()
        let destination = tempDir.appendingPathComponent("copy.bin")
        let atVerificationStart = provider.pauseRead(of: destination, beforeChunk: 0)
        let operation = Task { await copy(source, to: destination) }

        let reached = await atVerificationStart.waitUntilReached()
        XCTAssertTrue(reached)
        // Before verification reads its first byte, the descriptor is already open.
        let opens = provider.verificationOpens
        XCTAssertEqual(opens.count, 1)
        if let open = opens.first {
            XCTAssertEqual(open.url, destination)
            XCTAssertTrue(ChunkedWriter.isDiscardablePartialFileName(open.openedURL.lastPathComponent),
                          "the writer's temporary file is verified: \(open.openedURL.lastPathComponent)")
            XCTAssertEqual(open.writerClosed, true, "opened only after the writer closed its descriptor")
            XCTAssertNotNil(open.writerFlushMode, "opened only after the writer flushed")
            XCTAssertEqual(open.writerFlushMode, .fullFsync, "APFS supports F_FULLFSYNC")
            XCTAssertTrue(open.cacheBypassed, "F_NOCACHE set on the verification descriptor")
        }
        atVerificationStart.release()
        let outcome = await operation.value

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.flushMode, .fullFsync)
        XCTAssertEqual(outcome.cacheBypassed, true)
        // The destination is read exactly once, and that read is the verification open.
        XCTAssertEqual(provider.readCalls, [source, destination])
        XCTAssertEqual(provider.verificationOpens.count, 1)
        assertTreesEqual(expected: source, actual: destination, comparator: TreeComparator(checks: .data))
    }

    func testLocalProviderVerificationReadOpensNowAndBypassesTheCache() async throws {
        let file = try makeSource("local.bin")
        let expected = try Data(contentsOf: file)

        let read = try LocalProvider().openForVerification(file, chunkSize: 4096)
        // The descriptor exists from the moment the read was opened: removing
        // the name afterwards does not stop it from reading the file.
        try fm.removeItem(at: file)
        var data = Data()
        for try await chunk in read.chunks { data.append(chunk) }

        XCTAssertTrue(read.cacheBypassed)
        XCTAssertEqual(data, expected)
    }

    func testWriterFlushesBeforeClosingAndRecordsHow() throws {
        let destination = tempDir.appendingPathComponent("flushed.bin")
        let writer = try LocalProvider().makeWriter(at: destination)
        try writer.write(Data(repeating: 7, count: 10_000))
        XCTAssertNil(writer.flushMode)

        let mode = try writer.finishWriting()

        XCTAssertEqual(mode, .fullFsync, "APFS supports F_FULLFSYNC")
        XCTAssertEqual(writer.flushMode, mode)
        XCTAssertTrue(writer.writesBypassCache, "F_NOCACHE set on the partial file")
        XCTAssertTrue(writer.isWritingFinished)
        XCTAssertEqual(try writer.finishWriting(), mode, "finishing twice flushes once")
        try writer.commit()
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 7, count: 10_000))
    }

    // MARK: - F_FULLFSYNC → fsync fallback on ExFAT and FAT32

    func testFlushFallsBackToFsyncOnExFATAndFAT32() async throws {
        for fileSystem in [ScratchVolume.FileSystem.exfat, .fat32] {
            let volume = try makeScratchVolume(fileSystem)

            // As the file system really behaves: whatever it supports is recorded.
            let source = try makeSource("real-\(fileSystem.statfsTypeName).bin")
            let real = volume.mountPoint.appendingPathComponent("real.bin")
            provider.flush = .system
            let realOutcome = await copy(source, to: real)
            XCTAssertNil(realOutcome.error, "\(fileSystem)")
            let realMode = try XCTUnwrap(realOutcome.flushMode, "\(fileSystem): verified")
            XCTAssertEqual(provider.verificationOpens.last?.writerFlushMode, realMode, "\(fileSystem)")
            XCTAssertEqual(realOutcome.cacheBypassed, true, "\(fileSystem)")
            print("#28: \(fileSystem.rawValue) flushed with \(realMode.rawValue)")
            assertTreesEqual(expected: source, actual: real, comparator: TreeComparator(checks: [.type, .size, .content]))

            // Without F_FULLFSYNC (as smbfs reports it; on the CI runner ExFAT and FAT32
            // support F_FULLFSYNC): the real fsync runs on this volume.
            let calls = FlushCalls()
            provider.flush = .withoutFullFsync(calls: calls)
            let fallback = volume.mountPoint.appendingPathComponent("fallback.bin")
            let fallbackOutcome = await copy(source, to: fallback)
            XCTAssertNil(fallbackOutcome.error, "\(fileSystem)")
            XCTAssertEqual(fallbackOutcome.flushMode, .fsync, "\(fileSystem)")
            XCTAssertEqual(provider.verificationOpens.last?.writerFlushMode, .fsync, "\(fileSystem): flushed before verification")
            XCTAssertEqual(provider.verificationOpens.last?.writerClosed, true, "\(fileSystem)")
            XCTAssertEqual(calls.fullFsync, 1, "\(fileSystem)")
            XCTAssertEqual(calls.fsync, 1, "\(fileSystem)")
            assertTreesEqual(expected: source, actual: fallback, comparator: TreeComparator(checks: [.type, .size, .content]))
            XCTAssertEqual(try partialFiles(in: volume.mountPoint), [], "\(fileSystem)")
        }
    }

    // MARK: - A failed flush fails the copy

    func testFailedFsyncFailsTheCopyBeforeVerificationAndLeavesNothing() async throws {
        let source = try makeSource()
        let before = try TreeSnapshot.capture(source)
        let destination = tempDir.appendingPathComponent("unflushed.bin")
        provider.flush = .withoutFullFsync(fsyncError: EIO)

        let outcome = await copy(source, to: destination)

        guard case .ioError(let underlying)? = outcome.error as? OperationError else {
            return XCTFail("expected .ioError, got \(String(describing: outcome.error))")
        }
        XCTAssertEqual((underlying as? POSIXError)?.code, .EIO)
        XCTAssertTrue(provider.verificationOpens.isEmpty, "never verified")
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(try partialFiles(in: tempDir), [])
        assertTree(source, matches: before, "source unchanged")
    }

    func testFullFsyncFailureThatIsNotUnsupportedIsAnErrorWithoutFallback() throws {
        let calls = FlushCalls()
        let flush = FileFlush(
            fullFsync: { _ in calls.recordFullFsync(); return EIO },
            fsync: { _ in calls.recordFsync(); return 0 }
        )
        XCTAssertThrowsError(try flush.flush(-1)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
        XCTAssertEqual(calls.fullFsync, 1)
        XCTAssertEqual(calls.fsync, 0, "a real flush error is not hidden by fsync")
    }

    func testUnsupportedFullFsyncFallsBackToFsync() throws {
        for code in [ENOTSUP, EOPNOTSUPP, EINVAL, ENOTTY] {
            let calls = FlushCalls()
            let flush = FileFlush.withoutFullFsync(fullFsyncError: code, fsyncError: 0, calls: calls)
            XCTAssertEqual(try flush.flush(-1), .fsync, "errno \(code)")
            XCTAssertEqual(calls.fsync, 1, "errno \(code)")
        }
    }

    func testInterruptedFlushIsRetried() throws {
        let calls = FlushCalls()
        let flush = FileFlush(
            fullFsync: { _ in calls.recordFullFsync(); return calls.fullFsync < 3 ? EINTR : 0 },
            fsync: { _ in calls.recordFsync(); return 0 }
        )
        XCTAssertEqual(try flush.flush(-1), .fullFsync)
        XCTAssertEqual(calls.fullFsync, 3)
        XCTAssertEqual(calls.fsync, 0)
    }

    // MARK: - Moves that look like renames but cross volumes

    /// A destination folder that is a symlink to another volume: the move must
    /// copy, verify and only then delete the source; never a bare rename.
    func testMoveIntoASymlinkedFolderOnAnotherVolumeIsAVerifiedCopy() async throws {
        let volume = try makeScratchVolume(.apfs)
        let linkedFolder = tempDir.appendingPathComponent("linked", isDirectory: true)
        try HarnessPOSIX.symlink(volume.mountPoint.path, at: linkedFolder.path)
        let source = try makeSource()
        let before = try TreeSnapshot.capture(source)
        let destination = linkedFolder.appendingPathComponent("moved.bin")
        let atVerificationStart = provider.pauseRead(of: destination, beforeChunk: 0)
        let operation = Task { await move(source, to: destination) }

        let reached = await atVerificationStart.waitUntilReached()
        XCTAssertTrue(reached, "the move verifies its copy")
        XCTAssertTrue(provider.deleteCalls.isEmpty, "source not deleted before verification")
        assertTree(source, matches: before, "source intact while verifying")
        atVerificationStart.release()
        let outcome = await operation.value

        XCTAssertNil(outcome.error)
        guard case .verified? = outcome.result else {
            return XCTFail("expected .verified, got \(String(describing: outcome.states.last))")
        }
        XCTAssertTrue(provider.moveCalls.isEmpty, "never treated as a rename")
        XCTAssertEqual(provider.deleteCalls, [source])
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        assertTree(volume.mountPoint.appendingPathComponent("moved.bin"), matches: before,
                   comparator: TreeComparator(checks: .data), "moved file intact on the other volume")
    }

    /// If the rename reports `EXDEV` (the destination is on another volume
    /// after all), nothing was changed and the move falls back to the verified copy.
    func testRenameThatCrossesVolumesFallsBackToAVerifiedCopy() async throws {
        for conflict in [ConflictResolution.skip, .overwrite] {
            let source = try makeSource("exdev-\(conflict).bin")
            let before = try TreeSnapshot.capture(source)
            let destination = tempDir.appendingPathComponent("moved-\(conflict).bin")
            if conflict == .overwrite {
                try HarnessPOSIX.writeFile(destination.path, data: Data("original".utf8))
            }
            provider.moveErrors = [source: POSIXError(.EXDEV)]

            let outcome = await move(source, to: destination, conflict: conflict)

            XCTAssertNil(outcome.error, "\(conflict)")
            guard case .verified? = outcome.result else {
                XCTFail("\(conflict): expected .verified, got \(String(describing: outcome.states.last))")
                continue
            }
            XCTAssertEqual(provider.moveCalls.count + provider.replaceCalls.count, conflict == .overwrite ? 2 : 1,
                           "\(conflict): one rename attempt per move so far")
            XCTAssertEqual(provider.verificationOpens.last?.url, destination, "\(conflict)")
            XCTAssertEqual(provider.deleteCalls.last, source, "\(conflict)")
            XCTAssertFalse(fm.fileExists(atPath: source.path), "\(conflict)")
            assertTree(destination, matches: before, comparator: TreeComparator(checks: .data), "\(conflict)")
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: tempDir.path).filter {
                ChunkedWriter.isDiscardablePartialFileName($0) || ChunkedWriter.isParkedOriginalFileName($0)
            }, [], "\(conflict): no partial or .old file left")
        }
    }

    /// `LocalProvider.move` is a rename only: across volumes it throws `EXDEV`
    /// and copies nothing (`FileManager.moveItem` would copy and delete).
    func testLocalProviderMoveAcrossVolumesThrowsInsteadOfCopying() async throws {
        let volume = try makeScratchVolume(.apfs)
        let source = try makeSource()
        let before = try TreeSnapshot.capture(source)
        let destination = volume.mountPoint.appendingPathComponent("moved.bin")

        do {
            try await LocalProvider().move(from: source, to: destination)
            XCTFail("expected EXDEV")
        } catch {
            XCTAssertEqual((error as? POSIXError)?.code, .EXDEV, "\(error)")
        }

        assertTree(source, matches: before, "source untouched")
        XCTAssertFalse(fm.fileExists(atPath: destination.path), "nothing copied")
    }
}
