import Foundation

final class LocalProvider: VFSProvider {
    /// Moves an item to the Trash and returns its new location, if known.
    typealias Trasher = (URL) throws -> URL?

    /// Runs before each chunk read of `url` (source and verification reads).
    typealias ReadObserver = @Sendable (_ url: URL) -> Void

    private let fm = FileManager.default
    private let trasher: Trasher
    private let readObserver: ReadObserver?

    /// `trasher` is a seam for tests, so they never touch the real `~/.Trash`.
    /// `readObserver` is a test hook (#52) that counts chunk reads; nil in production.
    init(trasher: @escaping Trasher = LocalProvider.systemTrash, readObserver: ReadObserver? = nil) {
        self.trasher = trasher
        self.readObserver = readObserver
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

    /// Pull-based (#52, see `PullChunkStream`): one chunk is read per
    /// `next()`, so the source is never read ahead of hashing and writing.
    /// The file is opened on the first pull and closed after the last read:
    /// at end of file, on error, on cancellation (#6), or when the consumer
    /// stops early.
    func readChunks(of url: URL, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
        PullChunkStream.make(chunkSize: chunkSize, willRead: readHook(for: url)) {
            try SourceFileReader(url: url)
        }
    }

    // MARK: - Verification read (#28)

    func openForVerification(_ url: URL, chunkSize: Int) throws -> VerificationRead {
        let access = try ScopedAccess(url: url)
        let reader: UncachedFileReader
        do {
            reader = try UncachedFileReader(url: url)
        } catch {
            access.stop()
            throw error
        }
        return VerificationRead(chunks: reader.chunks(chunkSize: chunkSize, keepAlive: access,
                                                      willRead: readHook(for: url)),
                                cacheBypassed: reader.cacheBypassed)
    }

    // MARK: - Write

    func makeWriter(at url: URL, replacingExisting: Bool) throws -> ChunkedWriter {
        try ChunkedWriter(url: url, replacingExisting: replacingExisting)
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

    /// A rename and nothing else (#28): never replaces an existing item
    /// (`AtomicRename.moveExclusively`) and never copies. Across volumes it
    /// fails with `EXDEV`, unlike `FileManager.moveItem`, which would silently
    /// copy and delete without verification.
    func move(from: URL, to: URL) async throws {
        let sourceAccess = try ScopedAccess(url: from)
        let destinationAccess = try ScopedAccess(url: to.deletingLastPathComponent())
        defer {
            sourceAccess.stop()
            destinationAccess.stop()
        }
        try AtomicRename.system.moveExclusively(from: from, to: to)
    }

    /// Replace for same-volume moves (#27): the existing item is parked under a
    /// hidden `.old` name, never deleted before `source` is in its place, and
    /// restored if that fails. No `RENAME_SWAP`: it would leave the old item at
    /// the user-visible source path until removed (see `AtomicRename.replace`).
    func replaceItem(at destination: URL, withItemAt source: URL) async throws {
        let sourceAccess = try ScopedAccess(url: source)
        let destinationAccess = try ScopedAccess(url: destination.deletingLastPathComponent())
        defer {
            sourceAccess.stop()
            destinationAccess.stop()
        }
        try AtomicRename.system.replace(destination, with: source, backup: ChunkedWriter.backupURL(for: destination), swapping: false)
    }

    // MARK: - Private helpers

    private func readHook(for url: URL) -> (@Sendable () -> Void)? {
        guard let readObserver else { return nil }
        return { readObserver(url) }
    }

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

/// A source read (#52): a plain FileHandle. The scoped access lasts as long
/// as the reader (`ScopedAccess` stops when released; `PullChunkStream`
/// releases the reader right after closing it).
private final class SourceFileReader: ChunkReader {
    private let access: ScopedAccess
    private let handle: FileHandle

    init(url: URL) throws {
        access = try ScopedAccess(url: url)
        handle = try FileHandle(forReadingFrom: url)
    }

    func read(upToCount count: Int) throws -> Data? {
        let chunk = try handle.read(upToCount: count) ?? Data()
        return chunk.isEmpty ? nil : chunk
    }

    func close() {
        // Read-only handle: nothing to flush, a close error cannot lose data.
        try? handle.close()
    }
}
