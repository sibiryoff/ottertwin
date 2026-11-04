import XCTest
@testable import OtterTwin

/// #52: source reads (`LocalProvider.readChunks`) and verification reads
/// (`UncachedFileReader.chunks`, via `LocalProvider.openForVerification`) never
/// hold more than a bounded number of chunks ahead of a slow consumer, and the
/// pull-based stream keeps the descriptor lifetime rules of #51: closed
/// exactly once, only after the last read, also on cancel and early stop.
final class BoundedReadAheadTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    private static let chunkSize = 64 * 1024
    /// 32 MiB + a tail: far more than any bound, and more than an unbounded
    /// reader needs to fill memory while the consumer sleeps.
    private static let chunkCount = 512
    /// N: the most chunks a reader may have read beyond what the consumer has
    /// received. The readers are pull-based (they read only the chunk being
    /// asked for), so they actually stay at 0.
    private static let maxChunksAhead = 1

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("BoundedReadAheadTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeLargeFixture() throws -> (url: URL, data: Data) {
        let url = tempDir.appendingPathComponent("large.bin")
        let data = FixtureTree.content(for: "large.bin", size: Self.chunkCount * Self.chunkSize + 7, seed: 52)
        try HarnessPOSIX.writeFile(url.path, data: data)
        return (url, data)
    }

    /// Consumes `stream` slowly (a long pause after the first chunk, a short
    /// one after every other) and, after each pause, checks how many chunks
    /// the reader has read. Returns the data received.
    private func consumeSlowly(_ stream: AsyncThrowingStream<Data, Error>, reads: ReadCounter,
                               _ label: String) async throws -> Data {
        var received = Data()
        var chunksReceived = 0
        var worstAhead = 0
        for try await chunk in stream {
            received.append(chunk)
            chunksReceived += 1
            // An unbounded reader on local storage reads the whole fixture
            // in far less than this first pause.
            let pause: UInt64 = chunksReceived == 1 ? 300_000_000 : 1_000_000
            try await Task.sleep(nanoseconds: pause)
            let ahead = reads.count - chunksReceived
            worstAhead = max(worstAhead, ahead)
            XCTAssertLessThanOrEqual(ahead, Self.maxChunksAhead,
                                     "\(label): \(reads.count) chunks read, \(chunksReceived) received")
            if ahead > Self.maxChunksAhead { break }  // one failure is enough
        }
        XCTAssertLessThanOrEqual(worstAhead, Self.maxChunksAhead, label)
        return received
    }

    // MARK: - Slow consumer over a large fixture

    func testSourceReaderNeverReadsMoreThanNChunksAheadOfASlowConsumer() async throws {
        let (url, expected) = try makeLargeFixture()
        let reads = ReadCounter()
        let provider = LocalProvider(readObserver: { _ in reads.record() })

        let received = try await consumeSlowly(provider.readChunks(of: url, chunkSize: Self.chunkSize),
                                               reads: reads, "source")

        XCTAssertEqual(received.count, expected.count, "source")
        XCTAssertTrue(received == expected, "source: every byte delivered, in order")
    }

    func testVerificationReaderNeverReadsMoreThanNChunksAheadOfASlowConsumer() async throws {
        let (url, expected) = try makeLargeFixture()
        let reads = ReadCounter()
        let provider = LocalProvider(readObserver: { _ in reads.record() })

        let read = try provider.openForVerification(url, chunkSize: Self.chunkSize)
        let received = try await consumeSlowly(read.chunks, reads: reads, "verification")

        XCTAssertTrue(read.cacheBypassed)
        XCTAssertEqual(received.count, expected.count, "verification")
        XCTAssertTrue(received == expected, "verification: every byte delivered, in order")
    }

    // MARK: - Descriptor lifetime (#51 rules)

    func testReaderIsOpenedOnFirstPullAndClosedOnceAfterTheLastReadAtEndOfFile() async throws {
        let reader = FakeChunkReader(chunks: 5)
        let opens = ReadCounter()
        let stream = PullChunkStream.make(chunkSize: 4) { opens.record(); return reader }
        XCTAssertEqual(opens.count, 0, "nothing is opened before the first pull")

        var count = 0
        for try await _ in stream { count += 1 }

        XCTAssertEqual(count, 5)
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(reader.reads, 6, "5 chunks and the read that found end of file")
        XCTAssertEqual(reader.closeCount, 1)
        XCTAssertFalse(reader.readAfterClose)
    }

    func testReaderIsClosedWhenTheConsumerStopsEarly() async throws {
        let reader = FakeChunkReader(chunks: 100)
        let count = try await consumeFirst(2, of: reader)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(reader.reads, 2, "nothing read beyond what the consumer took")
        XCTAssertEqual(reader.closeCount, 1, "closed when the stream was released")
        XCTAssertFalse(reader.readAfterClose)
    }

    func testReaderIsClosedWithoutAnotherReadWhenTheConsumerIsCancelled() async throws {
        let reader = FakeChunkReader(chunks: 100)
        let stream = PullChunkStream.make(chunkSize: 4) { reader }
        let task = Task { () -> (Int, Error?) in
            var count = 0
            do {
                for try await _ in stream {
                    count += 1
                    if count == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return (count, nil)
            } catch {
                return (count, error)
            }
        }
        let (count, error) = await task.value

        XCTAssertEqual(count, 3)
        // The stream either throws `CancellationError` or (AsyncThrowingStream's
        // own cancellation handling) ends; the service never takes such an end
        // for end of file (FileOperationCancellationTests).
        XCTAssertTrue(error == nil || error is CancellationError, "\(String(describing: error))")
        XCTAssertEqual(reader.reads, 3, "no read after the cancel")
        XCTAssertEqual(reader.closeCount, 1)
        XCTAssertFalse(reader.readAfterClose)
    }

    func testReaderIsClosedOnceWhenAReadFails() async throws {
        let reader = FakeChunkReader(chunks: 100, failingAtRead: 4)
        let stream = PullChunkStream.make(chunkSize: 4) { reader }

        var count = 0
        do {
            for try await _ in stream { count += 1 }
            XCTFail("the read error must reach the consumer")
        } catch {
            XCTAssertEqual(error as? InjectedFault, FakeChunkReader.fault)
        }

        XCTAssertEqual(count, 3)
        XCTAssertEqual(reader.closeCount, 1)
        XCTAssertFalse(reader.readAfterClose)
    }

    func testOpenErrorIsTheStreamsError() async throws {
        let fault = InjectedFault(message: "open failed")
        let stream = PullChunkStream.make(chunkSize: 4) { () throws -> any ChunkReader in throw fault }

        do {
            for try await _ in stream { XCTFail("no chunk expected") }
            XCTFail("the open error must reach the consumer")
        } catch {
            XCTAssertEqual(error as? InjectedFault, fault)
        }
    }

    func testLocalProviderSourceReadOfAMissingFileThrows() async throws {
        let missing = tempDir.appendingPathComponent("missing.bin")
        do {
            for try await _ in LocalProvider().readChunks(of: missing, chunkSize: 4096) { XCTFail("no chunk expected") }
            XCTFail("expected an error")
        } catch {
            // Any open error; what matters is that it is not a silent, empty end.
        }
    }

    /// Takes `count` chunks, then stops; the stream is released when this returns.
    private func consumeFirst(_ count: Int, of reader: FakeChunkReader) async throws -> Int {
        let stream = PullChunkStream.make(chunkSize: 4) { reader }
        var taken = 0
        for try await _ in stream {
            taken += 1
            if taken == count { break }
        }
        return taken
    }
}

// MARK: - Test doubles

/// Counts events from any thread.
final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func record() { lock.withLock { _count += 1 } }
}

/// A `ChunkReader` that serves `chunks` 4-byte chunks and records how it was used.
private final class FakeChunkReader: ChunkReader, @unchecked Sendable {
    static let fault = InjectedFault(message: "Injected read fault")

    private let lock = NSLock()
    private let chunks: Int
    private let failingAtRead: Int?
    private var _reads = 0
    private var _closeCount = 0
    private var _readAfterClose = false

    init(chunks: Int, failingAtRead: Int? = nil) {
        self.chunks = chunks
        self.failingAtRead = failingAtRead
    }

    var reads: Int { lock.withLock { _reads } }
    var closeCount: Int { lock.withLock { _closeCount } }
    var readAfterClose: Bool { lock.withLock { _readAfterClose } }

    func read(upToCount count: Int) throws -> Data? {
        let index = lock.withLock { () -> Int in
            if _closeCount > 0 { _readAfterClose = true }
            _reads += 1
            return _reads
        }
        if let failingAtRead, index >= failingAtRead { throw Self.fault }
        return index <= chunks ? Data(repeating: UInt8(truncatingIfNeeded: index), count: min(count, 4)) : nil
    }

    func close() {
        lock.withLock { _closeCount += 1 }
    }
}
