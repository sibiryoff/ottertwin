import Foundation
import Darwin
import OSLog

protocol VFSProvider {
    func listDirectory(_ url: URL) async throws -> [FileItem]
    func attributes(of url: URL) async throws -> FileItem
    func readChunks(of url: URL, chunkSize: Int) -> AsyncThrowingStream<Data, Error>
    func createDirectory(at url: URL) async throws
    func delete(_ url: URL) async throws
    func move(from: URL, to: URL) async throws
    /// Writer target — returns a continuation that the caller pushes chunks into.
    func makeWriter(at url: URL) throws -> ChunkedWriter

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
}

/// Thrown by `trash(_:)` of providers whose `supportsTrash` is false.
struct TrashNotSupportedError: Error, LocalizedError {
    var errorDescription: String? { "Moving to Trash is not supported for this location" }
}


// MARK: - ChunkedWriter

/// A write sink that accepts successive Data chunks and finalises on close().
///
/// Partial files (#6): the data goes to a hidden temporary file in the
/// destination folder, `.<name>.ottertwin-<uuid>.part`, unique per writer (and
/// so per operation). Nothing exists under the final name until `close()` has
/// written everything and moved the temporary file into place without
/// replacing anything. `abort()` removes the temporary file, never the final
/// one. A cancelled or failed copy therefore never leaves a final-looking
/// partial file, and two operations can never touch each other's partial file.
/// The temporary file is created exclusively (`O_EXCL`) with owner-only
/// permissions (0600), as the destination itself was before (#1).
///
/// Test hook (#24): deliberately not `final`, so the data-safety harness
/// (`FaultInjectingWriter` in OtterTwinTests) can subclass it to inject write,
/// corruption and close faults. Production code never subclasses it.
class ChunkedWriter {
    /// Where the file appears once `close()` succeeds.
    let destinationURL: URL
    /// Where the data is written until then.
    let temporaryURL: URL

    private static let logger = Logger(subsystem: "OtterTwin", category: "ChunkedWriter")
    private static let temporaryMarker = ".ottertwin-"
    private static let temporarySuffix = ".part"

    private let handle: FileHandle
    private let scopedAccess: ScopedAccess?
    private var isFinalized = false

    init(url: URL) throws {
        let access = try? ScopedAccess(url: url.deletingLastPathComponent())
        scopedAccess = access
        destinationURL = url
        temporaryURL = Self.makeTemporaryURL(for: url)
        // `deinit` does not run when `init` throws: stop the scoped access here.
        // Fail before any data is copied when the destination already exists
        // (reported as a conflict). `close()` re-checks atomically.
        var info = stat()
        if lstat(url.path, &info) == 0 {
            access?.stop()
            throw POSIXError(.EEXIST)
        }
        let fd = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            let code = errno
            access?.stop()
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func write(_ chunk: Data) throws {
        try handle.write(contentsOf: chunk)
    }

    /// Closes the temporary file and moves it to `destinationURL`. Never
    /// replaces an existing item: if something appeared at the destination in
    /// the meantime, this throws `EEXIST` and the temporary file stays until
    /// `abort()`. On any error the caller must call `abort()`.
    func close() throws {
        try handle.close()
        try Self.moveIntoPlaceExclusively(from: temporaryURL, to: destinationURL)
        isFinalized = true
    }

    /// Discards the written data: closes the handle and removes the temporary
    /// file. Does nothing after a successful `close()`; never touches
    /// `destinationURL`.
    func abort() {
        guard !isFinalized else { return }
        // The data is being discarded, so a failing close cannot lose anything;
        // after a successful `close()` (whose rename then failed) it throws
        // because the handle is already closed.
        try? handle.close()
        if unlink(temporaryURL.path) != 0, errno != ENOENT {
            let code = errno
            Self.logger.error("Could not remove partial file \(self.temporaryURL.lastPathComponent, privacy: .private): errno \(code, privacy: .public)")
        }
    }

    deinit {
        scopedAccess?.stop()
    }

    // MARK: Temporary names

    /// True for names of temporary files made by `ChunkedWriter`.
    static func isTemporaryFileName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.contains(temporaryMarker) && name.hasSuffix(temporarySuffix)
    }

    private static func makeTemporaryURL(for url: URL) -> URL {
        // Keep the name well under NAME_MAX (255 bytes) even for 255-byte
        // destination names: at most 100 bytes of the original name.
        var prefix = ""
        for character in url.lastPathComponent {
            guard prefix.utf8.count + String(character).utf8.count <= 100 else { break }
            prefix.append(character)
        }
        let name = "." + prefix + temporaryMarker + UUID().uuidString + temporarySuffix
        return url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    /// Renames without ever replacing an existing destination.
    private static func moveIntoPlaceExclusively(from source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // Some file systems (e.g. smbfs, FAT) do not support RENAME_EXCL. Fall
        // back to check-then-rename; the window between the check and the rename
        // is a known limitation that #27 (atomic finalize) addresses.
        var info = stat()
        if lstat(destination.path, &info) == 0 { throw POSIXError(.EEXIST) }
        guard rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
