import Foundation

/// Names shared by the app and the UI-test target (this file is compiled into
/// both, see `project.yml`) for the #57 defaults hook: a UI test must never read
/// or write the app's real preferences domain.
///
/// The XCUITest runner is sandboxed, so it cannot see or clean up the app's
/// (unsandboxed) preferences. The app therefore does the cleanup itself: in a
/// Debug build launched with `suiteEnvironmentKey`, it stores settings in that
/// suite and empties the suite at launch unless `keepEnvironmentKey` is "1".
enum UITestDefaultsHook {
    /// Launch-environment variable naming the defaults suite to use.
    static let suiteEnvironmentKey = "OTTERTWIN_UITEST_DEFAULTS_SUITE"
    /// Launch-environment variable; "1" keeps the suite's contents at launch, so
    /// a UI test can relaunch the app and see what the previous launch stored.
    static let keepEnvironmentKey = "OTTERTWIN_UITEST_KEEP_DEFAULTS"
    /// The one suite UI tests use. Only this name, or a name below it
    /// (`<suiteName>.<anything>`), is accepted, so the app can never be pointed
    /// at (and empty) its real domain or another app's domain.
    static let suiteName = "com.mas.ottertwin.uitests"

    static func isAllowedSuiteName(_ name: String) -> Bool {
        name == suiteName || name.hasPrefix(suiteName + ".")
    }
}
