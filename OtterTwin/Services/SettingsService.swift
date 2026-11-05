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

    /// The suite name to store settings in, or `nil` for `UserDefaults.standard`.
    /// Only a Debug build honours `OTTERTWIN_UITEST_DEFAULTS_SUITE`, and only when
    /// it is non-empty. See `UITestDefaultsHook`.
    static func defaultsSuiteName(environment: [String: String]) -> String? {
        #if DEBUG
        if let suite = environment[UITestDefaultsHook.suiteEnvironmentKey], !suite.isEmpty {
            return suite
        }
        #endif
        return nil
    }

    /// Whether launch empties the UI-test suite before reading it: only when a
    /// suite is in use and `OTTERTWIN_UITEST_KEEP_DEFAULTS` is not "1". A default
    /// launch (no suite) never resets anything.
    static func shouldResetDefaultsSuite(environment: [String: String]) -> Bool {
        defaultsSuiteName(environment: environment) != nil
            && environment[UITestDefaultsHook.keepEnvironmentKey] != "1"
    }

    /// `UserDefaults.standard`, unless `defaultsSuiteName(environment:)` names a
    /// suite; that suite is emptied first unless the keep flag is set, so every
    /// UI-test launch starts from the default settings and at most one suite
    /// file exists. A suite name outside `com.mas.ottertwin.uitests[.*]`, or one
    /// that cannot be opened, stops the app instead of falling back to the real
    /// domain or emptying another domain; this can only happen in a Debug build
    /// launched with the variable.
    static func resolvedDefaults(environment: [String: String]) -> UserDefaults {
        guard let suite = defaultsSuiteName(environment: environment) else { return .standard }
        guard UITestDefaultsHook.isAllowedSuiteName(suite),
              let defaults = UserDefaults(suiteName: suite) else {
            fatalError("\(UITestDefaultsHook.suiteEnvironmentKey)='\(suite)' is not an allowed UI-test defaults suite")
        }
        if shouldResetDefaultsSuite(environment: environment) {
            defaults.removePersistentDomain(forName: suite)
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
