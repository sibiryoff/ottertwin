import XCTest
import SnapshotTesting
import SwiftUI
import AppKit
@testable import OtterTwin

// Snapshot tests for SwiftUI views in isolation.
// Run once with `isRecording = true` to generate reference images,
// then switch back to `false` for regression detection.
final class SnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearSettingsDefaults()
        // Set to true to regenerate reference snapshots:
        // isRecording = true
    }

    override func tearDown() {
        clearSettingsDefaults()
        super.tearDown()
    }

    // MARK: - OperationProgressView states

    func testProgressViewPending() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .pending,
            onCancel: {},
            onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewCopyingHalf() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .copying(progress: 0.5),
            onCancel: {},
            onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewVerifying() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .verifying(progress: 0.75),
            onCancel: {},
            onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewComplete() {
        let srcHash = "a3b4c5d6e7f80001a3b4c5d6e7f80001a3b4c5d6e7f80001a3b4c5d6e7f80001"
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .complete(result: .verified(sourceHash: srcHash, destHash: srcHash, flushMode: .fullFsync, cacheBypassed: true)),
            onCancel: {},
            onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewChecksumSkipped() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .complete(result: .skipped),
            onCancel: {},
            onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewFailed() {
        let srcHash = "aabbccdd00112233aabbccdd00112233aabbccdd00112233aabbccdd00112233"
        let destHash = "00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff"
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .failed(.checksumMismatch(sourceHash: srcHash, destHash: destHash)),
            onCancel: {},
            onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewCancelled() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .cancelled,
            onCancel: {},
            onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    /// #6: Cancel was pressed; the operation is still stopping (Cancel disabled).
    func testProgressViewCancelling() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .copying(progress: 0.5),
            isCancelling: true,
            onCancel: {},
            onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    // MARK: - SMBConnectView

    func testSMBConnectViewEmpty() {
        let view = SMBConnectView(onConnect: { _ in })
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 380, height: 400)))
    }

    // MARK: - SettingsView

    func testSettingsViewDefaults() {
        let settings = SettingsService()
        let view = SettingsView(buildInfo: fixedBuildInfo).environment(settings)
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 420, height: 400)))
    }

    func testSettingsViewChecksumDisabled() {
        let settings = SettingsService()
        settings.setChecksumEnabled(false, userConfirmedDisable: true)
        let view = SettingsView(buildInfo: fixedBuildInfo).environment(settings)
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 420, height: 400)))
    }

    // MARK: - Helpers

    /// Fixed so the "About this build" row does not change with every commit.
    private let fixedBuildInfo = BuildInfo(gitSHA: "1a2b3c4", buildDate: "2026-10-08 12:00 UTC")

    private func makeOperation(kind: OperationKind = .copy) -> FileOperation {
        FileOperation(
            source: URL(fileURLWithPath: "/tmp/source/document.pdf"),
            destination: URL(fileURLWithPath: "/tmp/dest/document.pdf"),
            kind: kind
        )
    }

    private func clearSettingsDefaults() {
        UserDefaults.standard.removeObject(forKey: "checksumEnabled")
        UserDefaults.standard.removeObject(forKey: "checksumAlgorithm")
        UserDefaults.standard.removeObject(forKey: "chunkSizeBytes")
        UserDefaults.standard.removeObject(forKey: "checksumDisableAcknowledged")
    }
}
