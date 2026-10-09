import Foundation
import Darwin
import OSLog

protocol VFSProvider {
    func listDirectory(_ url: URL) async throws -> [FileItem]
    func attributes(of url: URL) async throws -> FileItem
    func readChunks(of url: URL, chunkSize: Int) -> AsyncThrowingStream<Data, Error>
    /// Verification read (#28): opens `url` now, through a new descriptor with
    /// `F_NOCACHE` set (see `UncachedFileReader`), and streams its chunks.
    /// Callers open it only after the writer was flushed and closed
    /// (`ChunkedWriter.finishWriting()`), so the bytes are read back from
    /// storage rather than from what this Mac still has cached.
    func openForVerification(_ url: URL, chunkSize: Int) throws -> VerificationRead
    func createDirectory(at url: URL) async throws
    func delete(_ url: URL) async throws
    func move(from: URL, to: URL) async throws
    /// Writer target — returns a continuation that the caller pushes chunks into.
    /// With `replacingExisting`, the writer's `commit()` atomically replaces an
    /// existing item at `url` (#27); otherwise an existing item is a conflict.
    func makeWriter(at url: URL, replacingExisting: Bool) throws -> ChunkedWriter
    /// Same-volume replace (#27): moves `source` to `destination`, replacing
    /// the item there without deleting it first and restoring it on failure
    /// (see `AtomicRename.replace(…swapping: false)`).
    func replaceItem(at destination: URL, withItemAt source: URL) async throws

    /// Whether this provider can move items to the macOS Trash. Even when true,
    /// an individual `trash(_:)` call can still fail (e.g. on network volumes
    /// that have no Trash); callers must handle that explicitly.
    var supportsTrash: Bool { get }
    /// Move `url` to the macOS Trash. Throws if Trash is not supported or the
    /// operation fails. Returns the item's new location in the Trash, if known.
    @discardableResult
    func trash(_ url: URL) async throws -> URL?
    /// Whether `url` belongs to the file system this provider serves. Used to
    /// pick the right provider for a panel's current path (e.g. after leaving
    /// a mounted SMB share for a local folder).
    func manages(_ url: URL) -> Bool
}

extension VFSProvider {
    func manages(_ url: URL) -> Bool { true }

    /// A writer that never replaces an existing item.
    func makeWriter(at url: URL) throws -> ChunkedWriter {
        try makeWriter(at: url, replacingExisting: false)
    }
}

/// Thrown by `trash(_:)` of providers whose `supportsTrash` is false.
struct TrashNotSupportedError: Error, LocalizedError {
    var errorDescription: String? { "Moving to Trash is not supported for this location" }
}


// MARK: - ChunkedWriter

/// A write sink that accepts successive Data chunks and finalises on commit.
///
/// Partial files (#6): the data goes to a hidden temporary file in the
/// destination folder, `.<name>.ottertwin-<uuid>.part`, unique per writer (and
/// so per operation). Nothing exists under the final name until the data was
/// written completely (`finishWriting()`) and `commit()` moved the temporary
/// file into place. `abort()` removes the temporary file, never the final one.
/// A cancelled or failed copy therefore never leaves a final-looking partial
/// file, and two operations can never touch each other's partial file.
/// The temporary file is created exclusively (`O_EXCL`) with owner-only
/// permissions (0600), as the destination itself was before (#1).
///
/// Flush (#28): `finishWriting()` flushes the data to storage
/// (`F_FULLFSYNC`, or `fsync` where that is unsupported, see `FileFlush`)
/// before closing, and records how in `flushMode`. The temporary file is also
/// written with `F_NOCACHE`, so its pages do not linger in this Mac's buffer
/// cache, where a verification read could find them instead of the storage.
///
/// Atomic finalize (#27): callers verify `temporaryURL` between
/// `finishWriting()` and `commit()`, so the destination is touched only once
/// the new data is verified. `commit()` uses `AtomicRename`: a new destination
/// is never replaced (`EEXIST` if something appeared meanwhile); a writer made
/// with `replacingExisting` swaps the verified file with the existing item and
/// then removes that item, restoring it if anything fails in between.
///
/// Test hook (#24): deliberately not `final`, so the data-safety harness
/// (`FaultInjectingWriter` in OtterTwinTests) can subclass it to inject write,
/// corruption and close faults. Production code never subclasses it.
class ChunkedWriter {
    /// Where the file appears once `commit()` succeeds.
    let destinationURL: URL
    /// Where the data is written until then.
    let temporaryURL: URL
    /// Where the replace fallback parks the original destination (#27).
    let backupURL: URL
    /// Whether `commit()` replaces an existing item at `destinationURL`.
    let replacesExisting: Bool

    private static let logger = Logger(subsystem: "OtterTwin", category: "ChunkedWriter")
    private static let temporaryMarker = ".ottertwin-"
    private static let temporarySuffix = ".part"
    private static let backupSuffix = ".old"

    private let handle: FileHandle
    private let scopedAccess: ScopedAccess?
    private let rename: AtomicRename
    private let flush: FileFlush
    /// How the data was flushed; set once `finishWriting()` succeeded (#28).
    private(set) var flushMode: FlushMode?
    /// The temporary file's descriptor is closed (finished or aborted).
    private(set) var isWritingFinished = false
    private var isFinalized = false

    /// Without `replacingExisting`, an existing item at `url` makes this throw
    /// `EEXIST` before any data is copied (reported as a conflict); `commit()`
    /// re-checks atomically. `rename` and `flush` are test hooks (see
    /// `AtomicRename` and `FileFlush`).
    init(url: URL, replacingExisting: Bool = false, rename: AtomicRename = .system, flush: FileFlush = .system) throws {
        let access = try? ScopedAccess(url: url.deletingLastPathComponent())
        scopedAccess = access
        destinationURL = url
        replacesExisting = replacingExisting
        self.rename = rename
        self.flush = flush
        let id = UUID()
        temporaryURL = Self.hiddenSiblingURL(for: url, id: id, suffix: Self.temporarySuffix)
        backupURL = Self.hiddenSiblingURL(for: url, id: id, suffix: Self.backupSuffix)
        // `deinit` does not run when `init` throws: stop the scoped access here.
        var info = stat()
        if !replacingExisting, lstat(url.path, &info) == 0 {
            access?.stop()
            throw POSIXError(.EEXIST)
        }
        let fd = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            let code = errno
            access?.stop()
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // Best effort (#28): only keeps the written pages out of the cache; the
        // verification read sets F_NOCACHE itself and reports whether it could.
        if fcntl(fd, F_NOCACHE, 1) == -1 {
            let code = errno
            Self.logger.info("F_NOCACHE not set for partial file: errno \(code, privacy: .public)")
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func write(_ chunk: Data) throws {
        try handle.write(contentsOf: chunk)
    }

    /// Flushes the temporary file to storage (#28, see `FileFlush`) and closes
    /// it: all data is in `temporaryURL`, ready to be verified through a new
    /// descriptor. Nothing is visible under the final name yet. Returns (and
    /// records in `flushMode`) how the data was flushed. On error, including a
    /// failed flush, the caller must call `abort()`.
    @discardableResult
    func finishWriting() throws -> FlushMode {
        if let flushMode { return flushMode }
        // Aborted: the data is gone, there is nothing to finish.
        guard !isWritingFinished else { throw POSIXError(.EBADF) }
        let mode = try flush.flush(handle.fileDescriptor)
        try handle.close()
        isWritingFinished = true
        flushMode = mode
        return mode
    }

    /// Moves the finished temporary file to `destinationURL` (see the type's
    /// doc). On error the destination is as before and the temporary file stays
    /// until `abort()`; the caller must call `abort()`.
    func commit() throws {
        guard !isFinalized else { return }
        try finishWriting()
        if replacesExisting {
            try rename.replace(destinationURL, with: temporaryURL, backup: backupURL)
        } else {
            try rename.moveExclusively(from: temporaryURL, to: destinationURL)
        }
        isFinalized = true
    }

    /// `finishWriting()` and `commit()` without a verification in between.
    func close() throws {
        try finishWriting()
        try commit()
    }

    /// Discards the written data: closes the handle and removes the temporary
    /// file. Does nothing after a successful `commit()`; never touches
    /// `destinationURL`.
    func abort() {
        guard !isFinalized else { return }
        if !isWritingFinished {
            // The data is being discarded, so a failing close cannot lose anything.
            try? handle.close()
            isWritingFinished = true
        }
        if unlink(temporaryURL.path) != 0, errno != ENOENT {
            let code = errno
            Self.logger.error("Could not remove partial file \(self.temporaryURL.lastPathComponent, privacy: .private): errno \(code, privacy: .public)")
        }
    }

    deinit {
        scopedAccess?.stop()
    }

    // MARK: Temporary names

    /// True for partial copies made by `ChunkedWriter`
    /// (`.<name>.ottertwin-<uuid>.part`). They hold no data that exists
    /// nowhere else: the source still has it, so they may be discarded.
    static func isDiscardablePartialFileName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.contains(temporaryMarker) && name.hasSuffix(temporarySuffix)
    }

    /// True for originals parked by the replace fallback (#27,
    /// `.<name>.ottertwin-<uuid>.old`). Normally removed right after the
    /// replace; one that remains (e.g. after a failed restore) can be the
    /// user's only copy of the original destination and must NEVER be deleted
    /// automatically.
    static func isParkedOriginalFileName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.contains(temporaryMarker) && name.hasSuffix(backupSuffix)
    }

    /// A hidden, operation-unique name for `url`'s replace fallback (#27):
    /// `.<name>.ottertwin-<uuid>.old`, in the same folder.
    static func backupURL(for url: URL) -> URL {
        hiddenSiblingURL(for: url, id: UUID(), suffix: backupSuffix)
    }

    private static func hiddenSiblingURL(for url: URL, id: UUID, suffix: String) -> URL {
        // Keep the name well under NAME_MAX (255 bytes) even for 255-byte
        // destination names: at most 100 bytes of the original name.
        var prefix = ""
        for character in url.lastPathComponent {
            guard prefix.utf8.count + String(character).utf8.count <= 100 else { break }
            prefix.append(character)
        }
        let name = "." + prefix + temporaryMarker + id.uuidString + suffix
        return url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }
}
