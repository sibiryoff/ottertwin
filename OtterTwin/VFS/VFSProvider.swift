import Foundation

protocol VFSProvider {
    func listDirectory(_ url: URL) async throws -> [FileItem]
    func attributes(of url: URL) async throws -> FileItem
    func readChunks(of url: URL, chunkSize: Int) -> AsyncThrowingStream<Data, Error>
    func createDirectory(at url: URL) async throws
    func delete(_ url: URL) async throws
    func move(from: URL, to: URL) async throws
    /// Writer target — returns a continuation that the caller pushes chunks into.
    func makeWriter(at url: URL) throws -> ChunkedWriter

    /// Whether this provider can move items to the macOS Trash.
    var supportsTrash: Bool { get }
    /// Move `url` to the macOS Trash. Throws if Trash is not supported or the
    /// operation fails.
    func trash(_ url: URL) async throws
}

// MARK: - ChunkedWriter

/// A write sink that accepts successive Data chunks and finalises on close().
final class ChunkedWriter {
    private let handle: FileHandle
    private let url: URL

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
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
        try? FileManager.default.removeItem(at: url)
    }
}
