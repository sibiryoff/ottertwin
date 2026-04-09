import Foundation

struct ConnectionInfo: Identifiable, Codable, Hashable {
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
        URL(string: "smb://\(host)/\(share)")
    }
}
