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
        // Set to true to regenerate reference snapshots:
        // isRecording = true
    }

    // MARK: - OperationProgressView states

    func testProgressViewPending() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .pending,
            onRequestCancel: {}, onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewCopyingHalf() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .copying(progress: 0.5),
            onRequestCancel: {}, onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewVerifying() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .verifying(progress: 0.75),
            onRequestCancel: {}, onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewComplete() {
        let srcHash = "a3b4c5d6e7f80001a3b4c5d6e7f80001a3b4c5d6e7f80001a3b4c5d6e7f80001"
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .complete(result: .verified(sourceHash: srcHash, destHash: srcHash)),
            onRequestCancel: {}, onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewChecksumSkipped() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .complete(result: .skipped),
            onRequestCancel: {}, onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewFailed() {
        let srcHash = "aabbccdd00112233aabbccdd00112233aabbccdd00112233aabbccdd00112233"
        let destHash = "00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff"
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .failed(.checksumMismatch(sourceHash: srcHash, destHash: destHash)),
            onRequestCancel: {}, onDismiss: {}
        )
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 440, height: 260)))
    }

    func testProgressViewCancelled() {
        let view = OperationProgressView(
            operation: makeOperation(),
            state: .cancelled,
            onRequestCancel: {}, onDismiss: {}
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
        let view = SettingsView().environment(settings)
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 420, height: 320)))
    }

    func testSettingsViewChecksumDisabled() {
        let settings = SettingsService()
        settings.checksumEnabled = false
        let view = SettingsView().environment(settings)
        assertSnapshot(of: NSHostingController(rootView: view), as: .image(size: CGSize(width: 420, height: 320)))
    }

    // MARK: - Helpers

    private func makeOperation(kind: OperationKind = .copy) -> FileOperation {
        FileOperation(
            source: URL(fileURLWithPath: "/tmp/source/document.pdf"),
            destination: URL(fileURLWithPath: "/tmp/dest/document.pdf"),
            kind: kind
        )
    }
}
