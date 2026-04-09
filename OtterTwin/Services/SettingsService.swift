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
    // MARK: Stored properties backed by UserDefaults

    var checksumEnabled: Bool {
        didSet { UserDefaults.standard.set(checksumEnabled, forKey: Keys.checksumEnabled) }
    }

    var checksumAlgorithm: ChecksumAlgorithm {
        didSet { UserDefaults.standard.set(checksumAlgorithm.rawValue, forKey: Keys.checksumAlgorithm) }
    }

    var chunkSizeBytes: Int {
        didSet { UserDefaults.standard.set(chunkSizeBytes, forKey: Keys.chunkSizeBytes) }
    }

    // MARK: Init

    init() {
        let defaults = UserDefaults.standard
        checksumEnabled = defaults.object(forKey: Keys.checksumEnabled) as? Bool ?? true
        let algRaw = defaults.string(forKey: Keys.checksumAlgorithm) ?? ""
        checksumAlgorithm = ChecksumAlgorithm(rawValue: algRaw) ?? .sha256
        let storedChunk = defaults.integer(forKey: Keys.chunkSizeBytes)
        chunkSizeBytes = storedChunk > 0 ? storedChunk : 1_048_576  // default 1 MB
    }

    // MARK: Private

    private enum Keys {
        static let checksumEnabled   = "checksumEnabled"
        static let checksumAlgorithm = "checksumAlgorithm"
        static let chunkSizeBytes    = "chunkSizeBytes"
    }
}
