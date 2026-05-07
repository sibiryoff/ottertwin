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

    func makeWriter(at url: URL) throws -> ChunkedWriter {
        try provider().makeWriter(at: url)
    }

    func createDirectory(at url: URL) async throws {
        try await provider().createDirectory(at: url)
    }

    var supportsTrash: Bool { false }

    func trash(_ url: URL) async throws {
        throw TrashNotSupportedError()
    }

    func delete(_ url: URL) async throws {
        try await provider().delete(url)
    }

    func move(from: URL, to: URL) async throws {
        try await provider().move(from: from, to: to)
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

struct TrashNotSupportedError: Error, LocalizedError {
    var errorDescription: String? { "Moving to Trash is not supported for remote shares" }
}
