import Foundation
import Security

/// Stores SMB passwords. The app uses `KeychainCredentialStore`; tests use an
/// in-memory fake so they never touch the real Keychain.
protocol CredentialStore {
    /// Saves `password`, replacing any existing password for the same server/account.
    func savePassword(_ password: String, server: String, account: String) throws
    /// Returns the saved password, or `nil` when none is stored.
    func loadPassword(server: String, account: String) throws -> String?
}

extension CredentialStore {
    func savePassword(_ password: String, for connection: ConnectionInfo) throws {
        try savePassword(password, server: connection.host, account: connection.credentialAccount)
    }

    func loadPassword(for connection: ConnectionInfo) throws -> String? {
        try loadPassword(server: connection.host, account: connection.credentialAccount)
    }
}

extension ConnectionInfo {
    /// Keychain account for an SMB connection: `user@host/share`.
    var credentialAccount: String {
        "\(username)@\(host)/\(share)"
    }
}

enum CredentialStoreError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .invalidData:
            return "The saved password could not be decoded."
        }
    }
}

/// `kSecClassInternetPassword` items in the user's default keychain.
/// No access group is used: the app is not sandboxed and is ad-hoc signed, so
/// `keychain-access-groups` (which needs a development team) is not available.
struct KeychainCredentialStore: CredentialStore {
    /// Attributes identifying one item. Deliberately has no `kSecAttrAccessGroup`.
    static func itemQuery(server: String, account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: server,
            kSecAttrAccount: account
        ]
    }

    func savePassword(_ password: String, server: String, account: String) throws {
        let query = Self.itemQuery(server: server, account: account)
        let data = Data(password.utf8)

        // Update in place first so an existing password is never deleted before
        // its replacement is stored.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
        default:
            throw CredentialStoreError.keychain(updateStatus)
        }
    }

    func loadPassword(server: String, account: String) throws -> String? {
        var query = Self.itemQuery(server: server, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.invalidData
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status)
        }
    }
}
