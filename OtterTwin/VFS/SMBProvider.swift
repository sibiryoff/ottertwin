import Foundation

/// SMBProvider mounts an SMB share and delegates all VFS operations to a
/// LocalProvider rooted at the mount point.
final class SMBProvider: VFSProvider {
    private let connection: ConnectionInfo
    private let smbService = SMBService()
    private var localProvider: LocalProvider?
    private var mountURL: URL?

    init(connection: ConnectionInfo) {
        self.connection = connection
    }

    // MARK: - Connection lifecycle

    func connect(password: String) async throws {
        guard let smbURL = connection.smbURL else {
            throw SMBService.SMBError.invalidURL
        }
        let url = try await smbService.mount(
            smbURL: smbURL,
            username: connection.username,
            password: password
        )
        mountURL = url
        localProvider = LocalProvider()
    }

    func disconnect() throws {
        try smbService.unmount()
        localProvider = nil
        mountURL = nil
    }

    var isConnected: Bool { smbService.isConnected }

    // MARK: - VFSProvider — delegate to LocalProvider

    func listDirectory(_ url: URL) async throws -> [FileItem] {
        try await provider().listDirectory(url)
    }

    func attributes(of url: URL) async throws -> FileItem {
        try await provider().attributes(of: url)
    }

    func readChunks(of url: URL, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
        guard let lp = localProvider else {
            return AsyncThrowingStream { $0.finish(throwing: NotConnectedError()) }
        }
        return lp.readChunks(of: url, chunkSize: chunkSize)
    }

    func makeWriter(at url: URL, replacingExisting: Bool) throws -> ChunkedWriter {
        try provider().makeWriter(at: url, replacingExisting: replacingExisting)
    }

    func createDirectory(at url: URL) async throws {
        try await provider().createDirectory(at: url)
    }

    /// macOS can Trash on some SMB servers but not others. Trash is attempted;
    /// when it fails, the delete flow reports it and offers an explicitly
    /// confirmed permanent delete — never a silent fallback.
    var supportsTrash: Bool { true }

    func trash(_ url: URL) async throws -> URL? {
        try await provider().trash(url)
    }

    /// Only paths inside the current mount point belong to this share.
    func manages(_ url: URL) -> Bool {
        guard let mountURL else { return false }
        return url.isContained(in: mountURL)
    }

    func delete(_ url: URL) async throws {
        try await provider().delete(url)
    }

    func move(from: URL, to: URL) async throws {
        try await provider().move(from: from, to: to)
    }

    func replaceItem(at destination: URL, withItemAt source: URL) async throws {
        try await provider().replaceItem(at: destination, withItemAt: source)
    }

    // MARK: - Root URL

    var rootURL: URL {
        get throws {
            guard let url = mountURL else { throw NotConnectedError() }
            return url
        }
    }

    // MARK: - Private

    private func provider() throws -> LocalProvider {
        guard let lp = localProvider else { throw NotConnectedError() }
        return lp
    }
}

struct NotConnectedError: Error, LocalizedError {
    var errorDescription: String? { "Not connected to SMB share" }
}

