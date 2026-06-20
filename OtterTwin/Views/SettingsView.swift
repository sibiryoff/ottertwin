import SwiftUI

struct SettingsView: View {
    @Environment(SettingsService.self) private var settings
    @State private var chunkSizeText: String = ""
    @State private var chunkUnit: ChunkUnit = .mb
    @State private var confirmingChecksumDisable = false

    enum ChunkUnit: String, CaseIterable, Identifiable {
        case kb = "KB"
        case mb = "MB"
        var id: String { rawValue }
        var bytes: Int { self == .kb ? 1_024 : 1_048_576 }
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Integrity") {
                Toggle("Verify checksums after copy/move", isOn: checksumEnabledBinding)
                    .accessibilityIdentifier("settings.checksumEnabled")

                if !settings.checksumEnabled {
                    Label("Checksum verification is disabled. Copies and moves can complete without integrity validation.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.checksumWarning")
                }

                Picker("Algorithm", selection: $settings.checksumAlgorithm) {
                    ForEach(ChecksumAlgorithm.allCases) { alg in
                        Text(alg.rawValue).tag(alg)
                    }
                }
                .disabled(!settings.checksumEnabled)
                .accessibilityIdentifier("settings.algorithm")

                HStack {
                    Text("Read chunk size")
                    Spacer()
                    TextField("", text: $chunkSizeText)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settings.chunkSize")
                        .onChange(of: chunkSizeText) { _, newValue in
                            updateChunkSize(valueText: newValue, unit: chunkUnit)
                        }
                    Picker("", selection: $chunkUnit) {
                        ForEach(ChunkUnit.allCases) { u in
                            Text(u.rawValue).tag(u)
                        }
                    }
                    .frame(width: 60)
                    .accessibilityIdentifier("settings.chunkUnit")
                    .onChange(of: chunkUnit) { _, newUnit in
                        updateChunkSize(valueText: chunkSizeText, unit: newUnit)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
        .onAppear { syncChunkFields() }
        .confirmationDialog(
            "Disable checksum verification?",
            isPresented: $confirmingChecksumDisable,
            titleVisibility: .visible
        ) {
            Button("Disable Verification", role: .destructive) {
                settings.setChecksumEnabled(false, userConfirmedDisable: true)
            }
            Button("Keep Verification On", role: .cancel) {
                settings.setChecksumEnabled(true)
            }
        } message: {
            Text("OtterTwin will not verify SHA-256 checksums after copy or move operations.")
        }
    }

    private var checksumEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.checksumEnabled },
            set: { enabled in
                if enabled {
                    settings.setChecksumEnabled(true)
                } else {
                    confirmingChecksumDisable = true
                }
            }
        )
    }

    private func updateChunkSize(valueText: String, unit: ChunkUnit) {
        guard let value = Int(valueText), value > 0 else { return }
        let multiplied = value.multipliedReportingOverflow(by: unit.bytes)
        let bytes = multiplied.overflow ? SettingsService.maximumChunkSizeBytes : multiplied.partialValue
        settings.setChunkSizeBytes(bytes)
        syncChunkFields()
    }

    private func syncChunkFields() {
        let bytes = settings.chunkSizeBytes
        if bytes % ChunkUnit.mb.bytes == 0 {
            chunkUnit = .mb
            chunkSizeText = "\(bytes / ChunkUnit.mb.bytes)"
        } else {
            chunkUnit = .kb
            chunkSizeText = "\(bytes / ChunkUnit.kb.bytes)"
        }
    }
}
