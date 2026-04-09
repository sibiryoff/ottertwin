import Foundation
import NetFS

// MARK: - SMBService

final class SMBService {
    enum SMBError: Error, LocalizedError {
        case mountFailed(Int32)
        case unmountFailed
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .mountFailed(let code): return "SMB mount failed (error \(code))"
            case .unmountFailed:         return "SMB unmount failed"
            case .invalidURL:            return "Invalid SMB URL"
            }
        }
    }

    private(set) var mountPath: URL?

    // MARK: - Mount

    /// Mount `smbURL` (e.g. smb://host/share) and return the local mount URL.
    func mount(smbURL: URL, username: String, password: String) async throws -> URL {
        if let existing = mountPath, FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }

        return try await withCheckedThrowingContinuation { continuation in
            let mountDir = URL(fileURLWithPath: "/Volumes")
            var asyncRequestID: AsyncRequestID?

            // NetFS wants mutable CF dictionaries
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
            let mountOptions = NSMutableDictionary()

            let status = NetFSMountURLAsync(
                smbURL as CFURL,
                mountDir as CFURL,
                username as CFString,
                password as CFString,
                openOptions as CFMutableDictionary,
                mountOptions as CFMutableDictionary,
                &asyncRequestID,
                nil,            // use default queue
                { status, _, mountpoints in
                    if status == 0,
                       let pts = mountpoints as? [String],
                       let first = pts.first {
                        continuation.resume(returning: URL(fileURLWithPath: first))
                    } else {
                        continuation.resume(throwing: SMBError.mountFailed(status))
                    }
                }
            )

            if status != 0 {
                continuation.resume(throwing: SMBError.mountFailed(status))
            }
        }.also { [weak self] url in
            self?.mountPath = url
        }
    }

    // MARK: - Unmount

    func unmount() throws {
        guard let path = mountPath else { return }
        let result = Darwin.unmount(path.path, 0)
        if result != 0 { throw SMBError.unmountFailed }
        mountPath = nil
    }

    // MARK: - Probe

    var isConnected: Bool {
        guard let path = mountPath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }
}

// MARK: - Tap helper

private extension URL {
    /// Apply a side-effect and return self (for chaining after async throws).
    func also(_ body: (URL) -> Void) -> URL {
        body(self)
        return self
    }
}
