import Foundation

/// RAII wrapper for security-scoped resource access.
///
/// OtterTwin is not sandboxed (personal build, see #23), so ordinary file URLs
/// are not security-scoped: `startAccessingSecurityScopedResource()` returns
/// `false` and this wrapper is a harmless no-op. It is kept so URLs that *are*
/// security-scoped (e.g. from a future open panel or bookmark) keep working,
/// and so re-enabling the sandbox later would not need call-site changes.
///
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
