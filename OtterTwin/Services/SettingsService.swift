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
        didSet { defaults.set(checksumEnabled, forKey: Keys.checksumEnabled) }
    }

    var checksumAlgorithm: ChecksumAlgorithm {
        didSet { defaults.set(checksumAlgorithm.rawValue, forKey: Keys.checksumAlgorithm) }
    }

    private(set) var chunkSizeBytes: Int {
        didSet { defaults.set(chunkSizeBytes, forKey: Keys.chunkSizeBytes) }
    }

    private(set) var checksumDisableAcknowledged: Bool {
        didSet { defaults.set(checksumDisableAcknowledged, forKey: Keys.checksumDisableAcknowledged) }
    }

    /// Where the settings are stored: `.standard` in a normal launch, a throwaway
    /// suite when a Debug build is launched by a UI test (see `resolvedDefaults`).
    private let defaults: UserDefaults

    // MARK: Init

    /// Settings stored in the domain chosen by `resolvedDefaults(environment:)`.
    /// Without `OTTERTWIN_UITEST_DEFAULTS_SUITE` (every normal launch) that is
    /// `UserDefaults.standard`.
    convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(defaults: SettingsService.resolvedDefaults(environment: environment))
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
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

    // MARK: UI-test defaults suite (#57)

    /// Launch-environment variable that UI tests set to a unique suite name, so a
    /// UI test never reads or writes the app's real preferences domain (a test
    /// that turns verification off must not leave it off for real copies).
    static let defaultsSuiteEnvironmentKey = "OTTERTWIN_UITEST_DEFAULTS_SUITE"

    /// The suite name to store settings in, or `nil` for `UserDefaults.standard`.
    /// Only a Debug build honours the variable, and only when it is non-empty.
    static func defaultsSuiteName(environment: [String: String]) -> String? {
        #if DEBUG
        if let suite = environment[defaultsSuiteEnvironmentKey], !suite.isEmpty {
            return suite
        }
        #endif
        return nil
    }

    /// `UserDefaults.standard`, unless `defaultsSuiteName(environment:)` names a
    /// suite. A named suite that cannot be opened (e.g. it equals the app's own
    /// bundle identifier) stops the app instead of silently falling back to the
    /// real domain; this can only happen in a Debug build launched by a test.
    static func resolvedDefaults(environment: [String: String],
                                 bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> UserDefaults {
        guard let suite = defaultsSuiteName(environment: environment) else { return .standard }
        guard suite != bundleIdentifier, let defaults = UserDefaults(suiteName: suite) else {
            fatalError("\(defaultsSuiteEnvironmentKey)='\(suite)' cannot be used as a separate defaults suite")
        }
        return defaults
    }

    // MARK: Private

    private enum Keys {
        static let checksumEnabled   = "checksumEnabled"
        static let checksumAlgorithm = "checksumAlgorithm"
        static let chunkSizeBytes    = "chunkSizeBytes"
        static let checksumDisableAcknowledged = "checksumDisableAcknowledged"
    }
}
