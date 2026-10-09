import SwiftUI
import os

struct SMBConnectView: View {
    private static let logger = Logger(subsystem: "OtterTwin", category: "SMBConnectView")

    @State private var host = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var credentialStore: any CredentialStore = KeychainCredentialStore()
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

        let info = normalizedConnection
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

    private var normalizedConnection: ConnectionInfo {
        ConnectionInfo(host: normalizedHost, share: normalizedShare, username: normalizedUsername)
    }

    private func saveCredentials() {
        do {
            try credentialStore.savePassword(password, for: normalizedConnection)
        } catch {
            // The connection already succeeded; only remembering the password failed.
            // Logged without host/user/password details.
            Self.logger.error("Could not save SMB password: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadSavedCredentials() {
        guard !normalizedHost.isEmpty, !normalizedShare.isEmpty, !normalizedUsername.isEmpty else { return }
        do {
            if let saved = try credentialStore.loadPassword(for: normalizedConnection) {
                password = saved
            }
        } catch {
            // Not a data path: the user can still type the password.
            Self.logger.error("Could not load SMB password: \(error.localizedDescription, privacy: .public)")
        }
    }
}
