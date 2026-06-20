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
}

// MARK: - ChunkedWriter

/// A write sink that accepts successive Data chunks and finalises on close().
final class ChunkedWriter {
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
