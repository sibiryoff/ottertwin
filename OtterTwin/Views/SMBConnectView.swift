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
                    .accessibilityIdentifier("smb.host")
                TextField("Share", text: $share)
                    .accessibilityIdentifier("smb.share")
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .accessibilityIdentifier("smb.username")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("smb.password")
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
                    .accessibilityIdentifier("smb.cancel")
                Button("Connect") { Task { await connect() } }
                    .disabled(!canConnect)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("smb.connect")
            }

            if isConnecting {
                ProgressView("Connecting…")
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { loadSavedCredentials() }
        .onChange(of: host) { _, _ in loadSavedCredentials() }
        .onChange(of: share) { _, _ in loadSavedCredentials() }
        .onChange(of: username) { _, _ in loadSavedCredentials() }
    }

    // MARK: - Connect

    private func connect() async {
        isConnecting = true
        errorMessage = nil

        let info = ConnectionInfo(host: normalizedHost, share: normalizedShare, username: normalizedUsername)
        guard info.smbURL != nil else {
            errorMessage = "Host and share may contain only letters, numbers, dots, underscores, and hyphens."
            isConnecting = false
            return
        }

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

    private var normalizedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedShare: String { share.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canConnect: Bool {
        !isConnecting &&
        !normalizedHost.isEmpty &&
        !normalizedShare.isEmpty &&
        !normalizedUsername.isEmpty &&
        ConnectionInfo.isValidSMBComponent(normalizedHost) &&
        ConnectionInfo.isValidSMBComponent(normalizedShare)
    }

    private func keychainAccount() -> String {
        "\(normalizedUsername)@\(normalizedHost)/\(normalizedShare)"
    }

    private func saveCredentials() {
        let account = keychainAccount()
        let data = password.data(using: .utf8)!

        let lookupQuery: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: normalizedHost,
            kSecAttrAccount: account
        ]
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: normalizedHost,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data
        ]
        SecItemDelete(lookupQuery as CFDictionary)
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadSavedCredentials() {
        guard !normalizedHost.isEmpty, !normalizedShare.isEmpty, !normalizedUsername.isEmpty else { return }
        let account = keychainAccount()
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: normalizedHost,
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
