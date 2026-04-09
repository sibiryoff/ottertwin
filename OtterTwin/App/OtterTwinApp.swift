import SwiftUI

@main
struct OtterTwinApp: App {
    @State private var settings = SettingsService()

    /// Returns true when running under XCTest — used to skip UI setup so the
    /// test runner can boot without the SwiftUI lifecycle blocking it.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            // Skip real content when running under XCTest so the test runner
            // can boot the host app without the SwiftUI lifecycle blocking it.
            if Self.isRunningTests {
                EmptyView()
            } else {
                MainView()
                    .environment(settings)
            }
        }
        .defaultSize(width: 1100, height: 680)

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
