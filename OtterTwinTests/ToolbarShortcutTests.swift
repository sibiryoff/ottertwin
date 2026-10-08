import XCTest
import SwiftUI
import AppKit
@testable import OtterTwin

/// #25: no toolbar action may be triggered by an unmodified key press.
///
/// The toolbar is hosted in a test window with a selection, and every printable
/// ASCII key plus Return/Escape/Tab/Delete is sent as an unmodified key
/// equivalent. A control button with a known unmodified shortcut sits in the
/// same window and must fire exactly once, proving the dispatch path works, so
/// the negative assertions cannot pass vacuously.
final class ToolbarShortcutTests: XCTestCase {
    private var tempDir: URL!
    private var window: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolbarShortcutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // XCTest runs test lifecycle methods on the main thread.
        MainActor.assumeIsolated {
            window?.orderOut(nil)
            window = nil
        }
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @MainActor
    private func host<V: View>(_ view: V) -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 60)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        self.window = window
        spinRunLoop()
        return window
    }

    @MainActor
    private func spinRunLoop(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func keyEvent(_ character: String, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        )!
    }

    /// Sends an unmodified key the way AppKit routes key equivalents.
    @MainActor
    private func press(_ character: String, in window: NSWindow) {
        let event = keyEvent(character, in: window)
        _ = window.performKeyEquivalent(with: event)
        spinRunLoop(0.05)
    }

    private static let unmodifiedKeys: [String] =
        (UInt8(ascii: " ")...UInt8(ascii: "~")).map { String(UnicodeScalar($0)) }
        + ["\r", "\u{1b}", "\t", "\u{7f}"]  // Return, Escape, Tab, Delete

    // MARK: - #25

    @MainActor
    func testNoUnmodifiedKeyTriggersAnyToolbarAction() throws {
        // Real files in a temp dir, selected in the active panel: if any key
        // triggered Delete, they would disappear.
        let fileA = tempDir.appendingPathComponent("a.txt")
        let fileB = tempDir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)

        let appState = AppState()
        appState.leftPath = tempDir
        appState.rightPath = tempDir
        appState.activePanel = .left
        appState.leftSelection = [fileA, fileB]

        var copyCount = 0
        var moveCount = 0
        var controlCount = 0
        let window = host(
            HStack {
                ToolbarView(appState: appState, onCopy: { copyCount += 1 }, onMove: { moveCount += 1 })
                // Control: proves this harness delivers unmodified key equivalents.
                Button("Control") { controlCount += 1 }
                    .keyboardShortcut("x", modifiers: [])
            }
        )

        for key in Self.unmodifiedKeys {
            press(key, in: window)
        }
        spinRunLoop(0.3)

        XCTAssertEqual(controlCount, 1, "Harness did not deliver the control key equivalent; the assertions below would be vacuous")
        XCTAssertEqual(copyCount, 0, "An unmodified key started a copy")
        XCTAssertEqual(moveCount, 0, "An unmodified key started a move")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileA.path), "An unmodified key started a delete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path), "An unmodified key started a delete")
        XCTAssertEqual(appState.leftSelection, [fileA, fileB], "Selection changed: some toolbar action ran")
    }
}
