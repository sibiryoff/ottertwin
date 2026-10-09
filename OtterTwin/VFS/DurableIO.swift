import Foundation
import Darwin
import OSLog

// MARK: - Flush to storage (#28)

/// How a written file was pushed to storage before it was verified (#28).
enum FlushMode: String, Equatable, Sendable {
    /// `fcntl(F_FULLFSYNC)`: the data was written and the drive was asked to
    /// flush its own cache to permanent storage.
    case fullFsync
    /// `fsync`: the data was handed to the device (or, on smbfs, the server),
    /// whose own cache may still hold it. Used where `F_FULLFSYNC` is reported
    /// unsupported (`ENOTSUP`, `EOPNOTSUPP`, `EINVAL` or `ENOTTY`; e.g. smbfs).
    /// On the CI runner the macOS ExFAT and FAT32 drivers do support `F_FULLFSYNC`.
    case fsync
}

/// Flushes a written file to storage: `F_FULLFSYNC`, falling back to `fsync`
/// only where `F_FULLFSYNC` is unsupported. Any other error is a failed flush
/// and is thrown: the data may not be on storage, so the copy must not be
/// verified or finalized.
///
/// Test hook (#28): the data-safety harness replaces the primitives to simulate
/// a file system without `F_FULLFSYNC` or a failing flush. Production code
/// always uses `.system`.
struct FileFlush {
    private static let logger = Logger(subsystem: "OtterTwin", category: "FileFlush")

    /// `fcntl(fd, F_FULLFSYNC)`; returns 0 on success, otherwise the `errno`.
    var fullFsync: (_ fd: Int32) -> Int32
    /// `fsync(fd)`; returns 0 on success, otherwise the `errno`.
    var fsync: (_ fd: Int32) -> Int32

    static let system = FileFlush(
        fullFsync: { fd in fcntl(fd, F_FULLFSYNC) == -1 ? errno : 0 },
        fsync: { fd in Darwin.fsync(fd) == -1 ? errno : 0 }
    )

    /// Flushes `fd` and returns the mode that succeeded.
    func flush(_ fd: Int32) throws -> FlushMode {
        let full = Self.retryingInterrupted { fullFsync(fd) }
        if full == 0 { return .fullFsync }
        guard Self.isUnsupported(full) else { throw Self.error(full) }
        Self.logger.info("F_FULLFSYNC is not supported here (errno \(full, privacy: .public)); flushing with fsync")
        let plain = Self.retryingInterrupted { fsync(fd) }
        guard plain == 0 else { throw Self.error(plain) }
        return .fsync
    }

    /// Errors with which file systems report that `F_FULLFSYNC` is unsupported.
    static func isUnsupported(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL || code == ENOTTY
    }

    private static func retryingInterrupted(_ call: () -> Int32) -> Int32 {
        var result = call()
        while result == EINTR { result = call() }
        return result
    }

    private static func error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

// MARK: - Uncached read for verification (#28)

/// Reads a file for verification (#28) through a descriptor of its own, opened
/// when the reader is created (so after the writer was flushed and closed),
/// with `F_NOCACHE` set: reads go to the storage (or the server) instead of
/// being served from new entries in the unified buffer cache.
///
/// Limits (see docs/testing.md): `F_NOCACHE` cannot bypass caches outside this
/// Mac, e.g. a NAS's own RAM cache or a drive's cache.
///
/// Used by one consumer at a time (one read stream), hence `@unchecked Sendable`.
final class UncachedFileReader: @unchecked Sendable {
    private static let logger = Logger(subsystem: "OtterTwin", category: "UncachedFileReader")

    let url: URL
    /// Whether `F_NOCACHE` was set on the descriptor.
    let cacheBypassed: Bool
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if fcntl(fd, F_NOCACHE, 1) == -1 {
            let code = errno
            Self.logger.error("Could not bypass the cache for verification of \(url.lastPathComponent, privacy: .private): errno \(code, privacy: .public)")
            cacheBypassed = false
        } else {
            cacheBypassed = true
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// The next chunk of at most `count` bytes; nil at end of file.
    func read(upToCount count: Int) throws -> Data? {
        let chunk = try handle.read(upToCount: count) ?? Data()
        return chunk.isEmpty ? nil : chunk
    }

    func close() {
        // Read-only descriptor: nothing to flush, a close error cannot lose data.
        try? handle.close()
    }
}

/// A verification read (#28): the file's chunks, read through a fresh
/// descriptor that was opened when this value was made.
struct VerificationRead {
    let chunks: AsyncThrowingStream<Data, Error>
    /// Whether the read bypasses this Mac's buffer cache (`F_NOCACHE` was set).
    let cacheBypassed: Bool
}

extension UncachedFileReader {
    /// A pull-based stream of the reader's chunks: nothing is read ahead of the
    /// consumer, and the descriptor is closed at the end (EOF, error or cancel).
    /// `keepAlive` is retained until then (e.g. a scoped-access token).
    func chunks(chunkSize: Int, keepAlive: AnyObject? = nil) -> AsyncThrowingStream<Data, Error> {
        let state = StreamState(reader: self, keepAlive: keepAlive)
        return AsyncThrowingStream(unfolding: {
            guard !state.finished else { return nil }
            do {
                try Task.checkCancellation()
                if let chunk = try self.read(upToCount: chunkSize) { return chunk }
                state.finish()
                return nil
            } catch {
                state.finish()
                throw error
            }
        })
    }

    private final class StreamState: @unchecked Sendable {
        private let reader: UncachedFileReader
        private var keepAlive: AnyObject?
        private(set) var finished = false

        init(reader: UncachedFileReader, keepAlive: AnyObject?) {
            self.reader = reader
            self.keepAlive = keepAlive
        }

        func finish() {
            guard !finished else { return }
            finished = true
            reader.close()
            keepAlive = nil
        }
    }
}
