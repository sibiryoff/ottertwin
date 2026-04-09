import Foundation

/// RAII wrapper for security-scoped resource access.
/// Usage:
///   let token = try ScopedAccess(url: someURL)
///   defer { token.stop() }
///   // ... use url safely
final class ScopedAccess {
    let url: URL
    private let active: Bool

    init(url: URL) throws {
        self.url = url
        active = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        if active {
            url.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        stop()
    }
}
