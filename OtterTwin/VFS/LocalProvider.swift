import Foundation

final class LocalProvider: VFSProvider {
    private let fm = FileManager.default

    // MARK: - List

    func listDirectory(_ url: URL) async throws -> [FileItem] {
        let access = try ScopedAccess(url: url)
        defer { access.stop() }
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .fileSizeKey, .contentModificationDateKey, .isDirectoryKey
            ],
            options: [.skipsHiddenFiles]
        )
        return try contents.map { try makeFileItem(url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Attributes

    func attributes(of url: URL) async throws -> FileItem {
        let access = try ScopedAccess(url: url)
        defer { access.stop() }
        return try makeFileItem(url: url)
    }

    // MARK: - Read chunks

    func readChunks(of url: URL, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                do {
                    let access = try ScopedAccess(url: url)
                    defer { access.stop() }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    while true {
                        try Task.checkCancellation()
                        let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                        if chunk.isEmpty { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Write

    func makeWriter(at url: URL) throws -> ChunkedWriter {
        try ChunkedWriter(url: url)
    }

    // MARK: - Directory

    func createDirectory(at url: URL) async throws {
        let access = try ScopedAccess(url: url.deletingLastPathComponent())
        defer { access.stop() }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Delete

    func delete(_ url: URL) async throws {
        let access = try ScopedAccess(url: url)
        defer { access.stop() }
        try fm.removeItem(at: url)
    }

    // MARK: - Move (same-volume rename)

    func move(from: URL, to: URL) async throws {
        let sourceAccess = try ScopedAccess(url: from)
        let destinationAccess = try ScopedAccess(url: to.deletingLastPathComponent())
        defer {
            sourceAccess.stop()
            destinationAccess.stop()
        }
        try fm.moveItem(at: from, to: to)
    }

    // MARK: - Private helpers

    private func makeFileItem(url: URL) throws -> FileItem {
        let rv = try url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .isDirectoryKey
        ])
        return FileItem(
            id: url,
            name: url.lastPathComponent,
            size: Int64(rv.fileSize ?? 0),
            modificationDate: rv.contentModificationDate ?? .distantPast,
            isDirectory: rv.isDirectory ?? false
        )
    }
}
