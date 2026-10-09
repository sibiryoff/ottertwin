import Foundation
import Darwin

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
/// Test hook (#24): deliberately not `final`, so the data-safety harness
/// (`FaultInjectingWriter` in OtterTwinTests) can subclass it to inject write,
/// corruption and close faults. Production code never subclasses it.
class ChunkedWriter {
    private let handle: FileHandle
    private let url: URL
    private let scopedAccess: ScopedAccess?

    init(url: URL) throws {
        scopedAccess = try? ScopedAccess(url: url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.url = url
    }

    func write(_ chunk: Data) throws {
        try handle.write(contentsOf: chunk)
    }

    func close() throws {
        try handle.close()
    }

    func abort() {
        try? handle.close()
    }

    deinit {
        scopedAccess?.stop()
    }
}
