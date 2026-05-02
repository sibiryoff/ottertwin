import SwiftUI
import Security

struct SMBConnectView: View {
    @State private var host = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var onConnect: (SMBProvider) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to SMB Share")
                .font(.headline)

            Form {
                TextField("Host", text: $host)
                    .textContentType(.URL)
                TextField("Share", text: $share)
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .formStyle(.grouped)

            if let err = errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Connect") { Task { await connect() } }
                    .disabled(host.isEmpty || share.isEmpty || isConnecting)
                    .keyboardShortcut(.defaultAction)
            }

            if isConnecting {
                ProgressView("Connecting…")
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { loadSavedCredentials() }
    }

    // MARK: - Connect

    private func connect() async {
        isConnecting = true
        errorMessage = nil

        let info = ConnectionInfo(host: host, share: share, username: username)
        let provider = SMBProvider(connection: info)
        do {
            try await provider.connect(password: password)
            saveCredentials()
            onConnect(provider)
        } catch {
            errorMessage = error.localizedDescription
        }
        isConnecting = false
    }

    // MARK: - Keychain helpers

    private func keychainAccount() -> String { "\(username)@\(host)/\(share)" }

    private func saveCredentials() {
        let account = keychainAccount()
        let data = password.data(using: .utf8)!

        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrAccount: account,
            kSecValueData: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadSavedCredentials() {
        guard !host.isEmpty, !share.isEmpty, !username.isEmpty else { return }
        let account = keychainAccount()
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let pwd = String(data: data, encoding: .utf8) {
            password = pwd
        }
    }
}
