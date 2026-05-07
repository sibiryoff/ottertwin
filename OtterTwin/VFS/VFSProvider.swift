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
}

// MARK: - ChunkedWriter

/// A write sink that accepts successive Data chunks and finalises on close().
/// Writes to a hidden `.part` temp file in the same directory; close() renames
/// it to the final URL so a crash or cancellation never leaves a partial file
/// at the destination.
final class ChunkedWriter {
    private let handle: FileHandle
    private let tempURL: URL
    private let finalURL: URL

    init(url: URL) throws {
        finalURL = url
        tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".part")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: tempURL)
    }

    func write(_ chunk: Data) throws {
        try handle.write(contentsOf: chunk)
    }

    func close() throws {
        try handle.close()
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }

    func abort() {
        try? handle.close()
        try? FileManager.default.removeItem(at: tempURL)
    }
}
