import SwiftUI

struct SettingsView: View {
    @Environment(SettingsService.self) private var settings
    @State private var chunkSizeText: String = ""
    @State private var chunkUnit: ChunkUnit = .mb

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
                Toggle("Verify checksums after copy/move", isOn: $settings.checksumEnabled)

                Picker("Algorithm", selection: $settings.checksumAlgorithm) {
                    ForEach(ChecksumAlgorithm.allCases) { alg in
                        Text(alg.rawValue).tag(alg)
                    }
                }
                .disabled(!settings.checksumEnabled)

                HStack {
                    Text("Read chunk size")
                    Spacer()
                    TextField("", text: $chunkSizeText)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: chunkSizeText) { _, newValue in
                            if let v = Int(newValue), v > 0 {
                                settings.chunkSizeBytes = v * chunkUnit.bytes
                            }
                        }
                    Picker("", selection: $chunkUnit) {
                        ForEach(ChunkUnit.allCases) { u in
                            Text(u.rawValue).tag(u)
                        }
                    }
                    .frame(width: 60)
                    .onChange(of: chunkUnit) { _, newUnit in
                        if let v = Int(chunkSizeText), v > 0 {
                            settings.chunkSizeBytes = v * newUnit.bytes
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
        .onAppear { syncChunkFields() }
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
