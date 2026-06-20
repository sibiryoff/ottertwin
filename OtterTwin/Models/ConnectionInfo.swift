import Foundation

struct ConnectionInfo: Identifiable, Codable, Hashable {
    private static let validComponentPattern = /^[A-Za-z0-9._-]+$/

    let id: UUID
    var host: String
    var share: String
    var username: String

    init(id: UUID = UUID(), host: String, share: String, username: String) {
        self.id = id
        self.host = host
        self.share = share
        self.username = username
    }

    var smbURL: URL? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSMBComponent(normalizedHost),
              Self.isValidSMBComponent(normalizedShare) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "smb"
        components.host = normalizedHost
        components.path = "/" + normalizedShare
        return components.url
    }

    static func isValidSMBComponent(_ value: String) -> Bool {
        value.wholeMatch(of: validComponentPattern) != nil
    }
}
