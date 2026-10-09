import Foundation

final class LocalProvider: VFSProvider {
    /// Moves an item to the Trash and returns its new location, if known.
    typealias Trasher = (URL) throws -> URL?

    private let fm = FileManager.default
    private let trasher: Trasher

    /// `trasher` is a seam for tests, so they never touch the real `~/.Trash`.
    init(trasher: @escaping Trasher = LocalProvider.systemTrash) {
        self.trasher = trasher
    }

    /// The real macOS Trash via `FileManager.trashItem`.
    static func systemTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

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
            let reader = Task.detached {
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
            // Stop reading and close the file as soon as the consumer goes away
            // (e.g. its operation was cancelled, #6), instead of reading to EOF.
            continuation.onTermination = { _ in reader.cancel() }
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

    var supportsTrash: Bool { true }

    @discardableResult
    func trash(_ url: URL) async throws -> URL? {
        let access = try ScopedAccess(url: url)
        defer { access.stop() }
        return try trasher(url)
    }

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
