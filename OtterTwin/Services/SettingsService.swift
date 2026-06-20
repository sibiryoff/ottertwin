import Foundation
import Observation

// MARK: - Algorithm

enum ChecksumAlgorithm: String, CaseIterable, Identifiable {
    case sha256 = "SHA-256"

    var id: String { rawValue }
}

// MARK: - SettingsService

@Observable
final class SettingsService {
    static let defaultChunkSizeBytes = 1_048_576
    static let minimumChunkSizeBytes = 1_024
    static let maximumChunkSizeBytes = 1_073_741_824

    // MARK: Stored properties backed by UserDefaults

    private(set) var checksumEnabled: Bool {
        didSet { UserDefaults.standard.set(checksumEnabled, forKey: Keys.checksumEnabled) }
    }

    var checksumAlgorithm: ChecksumAlgorithm {
        didSet { UserDefaults.standard.set(checksumAlgorithm.rawValue, forKey: Keys.checksumAlgorithm) }
    }

    private(set) var chunkSizeBytes: Int {
        didSet { UserDefaults.standard.set(chunkSizeBytes, forKey: Keys.chunkSizeBytes) }
    }

    private(set) var checksumDisableAcknowledged: Bool {
        didSet { UserDefaults.standard.set(checksumDisableAcknowledged, forKey: Keys.checksumDisableAcknowledged) }
    }

    // MARK: Init

    init() {
        let defaults = UserDefaults.standard
        let storedChecksumEnabled = defaults.object(forKey: Keys.checksumEnabled) as? Bool ?? true
        let storedDisableAcknowledged = defaults.bool(forKey: Keys.checksumDisableAcknowledged)
        checksumDisableAcknowledged = storedDisableAcknowledged
        checksumEnabled = storedChecksumEnabled || !storedDisableAcknowledged
        let algRaw = defaults.string(forKey: Keys.checksumAlgorithm) ?? ""
        checksumAlgorithm = ChecksumAlgorithm(rawValue: algRaw) ?? .sha256
        let storedChunk = defaults.integer(forKey: Keys.chunkSizeBytes)
        chunkSizeBytes = Self.clampedChunkSize(storedChunk)

        if !storedChecksumEnabled, !storedDisableAcknowledged {
            defaults.set(true, forKey: Keys.checksumEnabled)
        }
        if chunkSizeBytes != storedChunk {
            defaults.set(chunkSizeBytes, forKey: Keys.chunkSizeBytes)
        }
    }

    // MARK: Updates

    func setChecksumEnabled(_ enabled: Bool, userConfirmedDisable: Bool = false) {
        if enabled {
            checksumDisableAcknowledged = false
            checksumEnabled = true
        } else if userConfirmedDisable {
            checksumDisableAcknowledged = true
            checksumEnabled = false
        } else {
            checksumDisableAcknowledged = false
            checksumEnabled = true
        }
    }

    func setChunkSizeBytes(_ bytes: Int) {
        chunkSizeBytes = Self.clampedChunkSize(bytes)
    }

    static func clampedChunkSize(_ bytes: Int) -> Int {
        guard bytes > 0 else { return defaultChunkSizeBytes }
        return min(max(bytes, minimumChunkSizeBytes), maximumChunkSizeBytes)
    }

    // MARK: Private

    private enum Keys {
        static let checksumEnabled   = "checksumEnabled"
        static let checksumAlgorithm = "checksumAlgorithm"
        static let chunkSizeBytes    = "chunkSizeBytes"
        static let checksumDisableAcknowledged = "checksumDisableAcknowledged"
    }
}
