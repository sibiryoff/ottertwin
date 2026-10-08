import Foundation

/// Identifies the running build: the git commit and build date stamped into
/// Info.plist (`OTGitSHA`, `OTBuildDate`) by `scripts/install-local.sh` and the
/// CI release build. Plain Xcode builds do not set them and show "unknown".
struct BuildInfo: Equatable {
    static let unknown = "unknown"

    let gitSHA: String
    let buildDate: String

    init(gitSHA: String, buildDate: String) {
        self.gitSHA = gitSHA
        self.buildDate = buildDate
    }

    init(infoDictionary: [String: Any]) {
        gitSHA = Self.value(infoDictionary["OTGitSHA"])
        buildDate = Self.value(infoDictionary["OTBuildDate"])
    }

    /// The build information of the running app.
    static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])

    /// One-line summary for the Settings "About this build" row.
    var summary: String {
        "\(gitSHA) · \(buildDate)"
    }

    private static func value(_ raw: Any?) -> String {
        let trimmed = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An unexpanded "$(VAR)" means the build setting was never defined.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return unknown }
        return trimmed
    }
}
