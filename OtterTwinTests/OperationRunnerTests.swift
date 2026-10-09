import XCTest
@testable import OtterTwin

/// #6: the progress sheet's Cancel stops the real operation (through
/// `OperationRunner`, which owns the operation's task), the sheet then shows
/// "cancelled" until dismissed, and a cancelled run leaves no stale state.
/// Uses the data-safety harness (#24) to cancel at exact points.
final class OperationRunnerTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var output: URL!
    private var provider: FaultInjectingProvider!
    private var tree: FixtureTree!

    private static let chunkSize = 64 * 1024

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("OperationRunnerTests-\(UUID().uuidString)", isDirectory: true)
        output = tempDir.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        provider = FaultInjectingProvider(fakeTrash: tempDir.appendingPathComponent("FakeTrash", isDirectory: true))
        var options = FixtureTree.Options()
        options.chunkSize = Self.chunkSize
        options.largeFileSize = 1 << 20
        options.includeSymlinks = false
        tree = try FixtureTree.build(at: tempDir.appendingPathComponent("fixture", isDirectory: true), options: options)
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        output = nil
        provider = nil
        tree = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeService() -> FileOperationService {
        let settings = SettingsService()
        settings.setChecksumEnabled(true, userConfirmedDisable: false)
        settings.setChunkSizeBytes(Self.chunkSize)
        return FileOperationService(settings: settings)
    }

    @MainActor
    private func start(_ runner: OperationRunner, _ kind: OperationKind, _ sources: [URL],
                       onFinish: @escaping @MainActor () -> Void = {}) {
        runner.start(kind: kind, sources: sources, destinationDirectory: output,
                     provider: provider, service: makeService(), onFinish: onFinish)
    }

    @MainActor
    private func assertCancelled(_ runner: OperationRunner, file: StaticString = #filePath, line: UInt = #line) {
        guard case .cancelled? = runner.currentOperation?.state else {
            return XCTFail("expected .cancelled, got \(String(describing: runner.currentOperation?.state))", file: file, line: line)
        }
    }

    private func outputEntries() throws -> [String] {
        try fm.contentsOfDirectory(atPath: output.path)
    }

    // MARK: - Cancel

    @MainActor
    func testCancelDuringCopyStopsItReportsCancelledAndKeepsTheSheetOpen() async throws {
        let source = tree.url(FixtureTree.Path.multiChunk)
        let before = try TreeSnapshot.capture(source)
        let duringCopy = provider.pauseRead(of: source, beforeChunk: 1)
        let runner = OperationRunner()
        var finishCalls = 0

        start(runner, .copy, [source], onFinish: { finishCalls += 1 })
        XCTAssertTrue(runner.isPresented)
        XCTAssertTrue(runner.isRunning)
        let reached = await duringCopy.waitUntilReached()
        XCTAssertTrue(reached)

        runner.cancel()
        XCTAssertTrue(runner.isCancelling, "the sheet shows that cancellation is in progress")
        runner.dismiss()
        XCTAssertTrue(runner.isPresented, "the sheet cannot be closed while the operation still runs")
        duringCopy.release()
        await runner.waitUntilFinished()

        assertCancelled(runner)
        XCTAssertFalse(runner.isRunning)
        XCTAssertFalse(runner.isCancelling)
        XCTAssertTrue(runner.isPresented, "the sheet stays open to show the cancellation")
        XCTAssertEqual(finishCalls, 1, "panels are refreshed after the cleanup")
        XCTAssertEqual(try outputEntries(), [], "no destination and no partial file")
        assertTree(source, matches: before, "source unchanged")

        runner.dismiss()
        XCTAssertFalse(runner.isPresented)
        XCTAssertNil(runner.currentOperation, "no stale progress left behind")
    }

    @MainActor
    func testCancelDuringVerificationReportsCancelledAndRemovesTheDestination() async throws {
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = output.appendingPathComponent(source.lastPathComponent)
        let duringVerification = provider.pauseRead(of: destination, beforeChunk: 1)
        let runner = OperationRunner()

        start(runner, .copy, [source])
        let reached = await duringVerification.waitUntilReached()
        XCTAssertTrue(reached)
        runner.cancel()
        duringVerification.release()
        await runner.waitUntilFinished()

        assertCancelled(runner)
        XCTAssertEqual(try outputEntries(), [], "unverified destination removed")
    }

    @MainActor
    func testCancelledMoveKeepsTheSource() async throws {
        let source = tree.url(FixtureTree.Path.multiChunk)
        let before = try TreeSnapshot.capture(source)
        let duringMove = provider.pauseRead(of: source, beforeChunk: 1)
        let runner = OperationRunner()

        start(runner, .move, [source])
        let reached = await duringMove.waitUntilReached()
        XCTAssertTrue(reached)
        runner.cancel()
        duringMove.release()
        await runner.waitUntilFinished()

        assertCancelled(runner)
        XCTAssertTrue(provider.moveCalls.isEmpty)
        XCTAssertTrue(provider.deleteCalls.isEmpty)
        XCTAssertEqual(try outputEntries(), [])
        assertTree(source, matches: before, "source unchanged")
    }

    @MainActor
    func testCancelNeverStartsTheRemainingFiles() async throws {
        let first = tree.url(FixtureTree.Path.multiChunk)
        let second = tree.url(FixtureTree.Path.chunkPlusOne)
        let duringFirst = provider.pauseRead(of: first, beforeChunk: 1)
        let runner = OperationRunner()

        start(runner, .copy, [first, second])
        let reached = await duringFirst.waitUntilReached()
        XCTAssertTrue(reached)
        runner.cancel()
        duringFirst.release()
        await runner.waitUntilFinished()

        assertCancelled(runner)
        XCTAssertFalse(provider.readCalls.contains(second), "the second file is never touched")
        XCTAssertEqual(try outputEntries(), [])
    }

    // MARK: - State after a cancelled run

    @MainActor
    func testANewRunAfterACancelledOneStartsCleanAndCompletes() async throws {
        let source = tree.url(FixtureTree.Path.multiChunk)
        let pause = provider.pauseRead(of: source, beforeChunk: 1)
        let runner = OperationRunner()

        start(runner, .copy, [source])
        let reached = await pause.waitUntilReached()
        XCTAssertTrue(reached)
        runner.cancel()
        pause.release()
        await runner.waitUntilFinished()
        assertCancelled(runner)
        runner.dismiss()

        // The pause point stays released, so the same copy now runs through.
        start(runner, .copy, [source])
        XCTAssertFalse(runner.isCancelling)
        await runner.waitUntilFinished()

        guard case .complete(.verified)? = runner.currentOperation?.state else {
            return XCTFail("expected .complete(.verified), got \(String(describing: runner.currentOperation?.state))")
        }
        XCTAssertTrue(runner.isPresented)
        assertTree(output.appendingPathComponent(source.lastPathComponent), matches: try TreeSnapshot.capture(source),
                   comparator: TreeComparator(checks: .data))
    }

    @MainActor
    func testAFailureIsReportedAsFailedNotCancelled() async throws {
        let source = tree.url(FixtureTree.Path.multiChunk)
        let destination = output.appendingPathComponent(source.lastPathComponent)
        provider.writeFaults = [destination: ByteFault(offset: Int64(Self.chunkSize))]
        let runner = OperationRunner()

        start(runner, .copy, [source])
        await runner.waitUntilFinished()

        guard case .failed(.ioError)? = runner.currentOperation?.state else {
            return XCTFail("expected .failed(.ioError), got \(String(describing: runner.currentOperation?.state))")
        }
        XCTAssertEqual(try outputEntries(), [])
    }
}
