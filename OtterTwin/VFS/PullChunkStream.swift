import Foundation

// MARK: - Pull-based chunk reads (#52)

/// Reads a file one chunk at a time through a descriptor of its own.
protocol ChunkReader: AnyObject {
    /// The next chunk of at most `count` bytes; nil at end of file.
    func read(upToCount count: Int) throws -> Data?
    /// Closes the descriptor. `PullChunkStream` calls it exactly once, never
    /// while a `read` is in progress.
    func close()
}

/// A pull-based stream of a file's chunks (#52), used for source reads
/// (`LocalProvider.readChunks`) and verification reads
/// (`UncachedFileReader.chunks`).
///
/// Bounded read-ahead: a chunk is read only when the consumer asks for it
/// (one read per `next()`, in the consumer's task), so the reader is never
/// ahead of the consumer and at most one chunk is in flight. A reader that
/// buffers into an unbounded stream instead can get far ahead of hashing and
/// writing and hold a large part of a multi-GB file in memory.
///
/// Reader lifetime: `open` runs on the first pull; its error is the stream's
/// error (or the reader is already open: `make(opened:…)`). The reader is closed exactly once, after its last read:
/// - at end of file, or when a read throws;
/// - when the consuming task is cancelled: the next pull throws
///   `CancellationError` without reading;
/// - when the consumer stops early or drops the stream: when the stream is
///   released. A pull in progress keeps the stream alive, so the reader is
///   never closed during a read.
/// `keepAlive` (e.g. a scoped-access token) is retained until the reader is closed.
enum PullChunkStream {
    static func make(
        chunkSize: Int,
        keepAlive: AnyObject? = nil,
        willRead: (@Sendable () -> Void)? = nil,
        open: @escaping () throws -> any ChunkReader
    ) -> AsyncThrowingStream<Data, Error> {
        let state = PullState(chunkSize: chunkSize, keepAlive: keepAlive, willRead: willRead,
                              reader: nil, open: open)
        return AsyncThrowingStream<Data, Error>(unfolding: { try state.next() })
    }

    /// The same for a reader that is already open (e.g. a verification read,
    /// whose descriptor is opened before the stream exists). The stream owns
    /// it from the start, so it is closed explicitly even if the stream is
    /// dropped, or its consumer cancelled, before the first pull.
    static func make(
        opened reader: any ChunkReader,
        chunkSize: Int,
        keepAlive: AnyObject? = nil,
        willRead: (@Sendable () -> Void)? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        let state = PullState(chunkSize: chunkSize, keepAlive: keepAlive, willRead: willRead,
                              reader: reader, open: nil)
        return AsyncThrowingStream<Data, Error>(unfolding: { try state.next() })
    }
}

/// The state of one pull-based stream. Every pull runs under `lock`, so reads
/// never overlap each other or the close; hence `@unchecked Sendable`.
private final class PullState: @unchecked Sendable {
    private let lock = NSLock()
    private let chunkSize: Int
    private let willRead: (@Sendable () -> Void)?
    private var open: (() throws -> any ChunkReader)?
    private var reader: (any ChunkReader)?
    private var keepAlive: AnyObject?
    private var finished = false

    /// Exactly one of `reader` (already open) and `open` (opens on the first pull) is non-nil.
    init(chunkSize: Int, keepAlive: AnyObject?, willRead: (@Sendable () -> Void)?,
         reader: (any ChunkReader)?, open: (() throws -> any ChunkReader)?) {
        self.chunkSize = chunkSize
        self.keepAlive = keepAlive
        self.willRead = willRead
        self.reader = reader
        self.open = open
    }

    /// Reads and returns the next chunk; nil at end of file (and after the stream finished).
    func next() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if finished { return nil }
        do {
            try Task.checkCancellation()
            if reader == nil, let open {
                self.open = nil
                reader = try open()
            }
            guard let current = reader else {
                finish()
                return nil
            }
            willRead?()
            guard let chunk = try current.read(upToCount: chunkSize) else {
                finish()
                return nil
            }
            return chunk
        } catch {
            finish()
            throw error
        }
    }

    /// Closes the reader (if it was opened) and releases `keepAlive`. Called with `lock` held.
    private func finish() {
        finished = true
        open = nil
        reader?.close()
        reader = nil
        keepAlive = nil
    }

    /// The consumer stopped early or dropped the stream: no pull is in
    /// progress (a pull keeps this object alive), so closing is safe.
    deinit {
        reader?.close()
    }
}
