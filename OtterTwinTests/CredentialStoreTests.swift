import XCTest
import Security
@testable import OtterTwin

/// In-memory `CredentialStore` so tests never touch the real Keychain.
final class InMemoryCredentialStore: CredentialStore {
    private struct Key: Hashable {
        let server: String
        let account: String
    }

    private var passwords: [Key: String] = [:]

    var count: Int { passwords.count }

    func savePassword(_ password: String, server: String, account: String) throws {
        passwords[Key(server: server, account: account)] = password
    }

    func loadPassword(server: String, account: String) throws -> String? {
        passwords[Key(server: server, account: account)]
    }
}

final class CredentialStoreTests: XCTestCase {
    private let connection = ConnectionInfo(host: "nas.local", share: "media", username: "alice")

    func testSaveThenLoadReturnsPassword() throws {
        let store = InMemoryCredentialStore()

        try store.savePassword("s3cret", for: connection)

        XCTAssertEqual(try store.loadPassword(for: connection), "s3cret")
    }

    func testSaveOverwritesExistingPassword() throws {
        let store = InMemoryCredentialStore()

        try store.savePassword("old", for: connection)
        try store.savePassword("new", for: connection)

        XCTAssertEqual(try store.loadPassword(for: connection), "new")
        XCTAssertEqual(store.count, 1)
    }

    func testLoadMissingPasswordReturnsNil() throws {
        let store = InMemoryCredentialStore()

        XCTAssertNil(try store.loadPassword(for: connection))
    }

    func testPasswordsAreKeyedPerUserHostAndShare() throws {
        let store = InMemoryCredentialStore()
        try store.savePassword("s3cret", for: connection)

        let otherShare = ConnectionInfo(host: "nas.local", share: "backup", username: "alice")
        let otherUser = ConnectionInfo(host: "nas.local", share: "media", username: "bob")
        let otherHost = ConnectionInfo(host: "nas2.local", share: "media", username: "alice")

        XCTAssertNil(try store.loadPassword(for: otherShare))
        XCTAssertNil(try store.loadPassword(for: otherUser))
        XCTAssertNil(try store.loadPassword(for: otherHost))
    }

    func testCredentialAccountFormat() {
        XCTAssertEqual(connection.credentialAccount, "alice@nas.local/media")
    }

    /// The query is inspected only; no Keychain call is made.
    func testKeychainItemQueryUsesInternetPasswordWithoutAccessGroup() {
        let query = KeychainCredentialStore.itemQuery(server: "nas.local", account: "alice@nas.local/media")

        XCTAssertEqual(query[kSecClass] as? String, kSecClassInternetPassword as String)
        XCTAssertEqual(query[kSecAttrServer] as? String, "nas.local")
        XCTAssertEqual(query[kSecAttrAccount] as? String, "alice@nas.local/media")
        XCTAssertNil(query[kSecAttrAccessGroup])
    }
}
