import XCTest
@testable import OtterTwin

/// #5: the delete flow must use the provider that matches each panel's current
/// path, including after leaving an SMB share for a local folder.
final class AppStateProviderTests: XCTestCase {
    private let shareRoot = URL(fileURLWithPath: "/Volumes/share", isDirectory: true)
    private let fakeTrash = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString)")

    private func makeShareProvider() -> FaultInjectingDeleteProvider {
        let provider = FaultInjectingDeleteProvider(fakeTrash: fakeTrash, supportsTrash: false)
        provider.managedRoot = shareRoot
        return provider
    }

    func testDefaultProviderIsLocalWithTrash() {
        let state = AppState()
        XCTAssertTrue(state.sourceProvider is LocalProvider)
        XCTAssertTrue(state.sourceProvider.supportsTrash)
        XCTAssertTrue(state.provider(for: .right) is LocalProvider)
    }

    func testAttachedShareProviderIsUsedInsideTheShare() {
        let state = AppState()
        let share = makeShareProvider()
        state.leftProvider = share
        state.leftPath = shareRoot.appendingPathComponent("photos/2024", isDirectory: true)

        XCTAssertTrue(state.sourceProvider as AnyObject === share)
        XCTAssertFalse(state.sourceProvider.supportsTrash)
    }

    func testLeavingTheShareRestoresLocalTrashBehaviour() {
        let state = AppState()
        state.leftProvider = makeShareProvider()
        state.leftPath = shareRoot

        state.leftPath = FileManager.default.temporaryDirectory

        XCTAssertTrue(state.sourceProvider is LocalProvider)
        XCTAssertTrue(state.sourceProvider.supportsTrash)
    }

    func testSiblingVolumeWithSharedPrefixIsNotTheShare() {
        let state = AppState()
        state.leftProvider = makeShareProvider()
        state.leftPath = URL(fileURLWithPath: "/Volumes/share2", isDirectory: true)

        XCTAssertTrue(state.sourceProvider is LocalProvider)
    }

    func testProviderIsResolvedPerPanel() {
        let state = AppState()
        let share = makeShareProvider()
        state.rightProvider = share
        state.rightPath = shareRoot
        state.leftPath = FileManager.default.temporaryDirectory

        state.activePanel = .left
        XCTAssertTrue(state.sourceProvider is LocalProvider)
        state.activePanel = .right
        XCTAssertTrue(state.sourceProvider as AnyObject === share)
    }

    func testDisconnectedSMBProviderManagesNothing() {
        let smb = SMBProvider(connection: ConnectionInfo(host: "nas", share: "s", username: "u"))
        XCTAssertFalse(smb.manages(shareRoot))

        let state = AppState()
        state.leftProvider = smb
        state.leftPath = shareRoot
        XCTAssertTrue(state.sourceProvider is LocalProvider)
    }

    func testReloadBumpsOnlyThatPanel() {
        let state = AppState()
        state.reload(.left)
        XCTAssertEqual(state.leftReloadToken, 1)
        XCTAssertEqual(state.rightReloadToken, 0)
        state.reload(.right)
        XCTAssertEqual(state.rightReloadToken, 1)
    }

    func testDeselectRemovesOnlyGivenURLsFromThatPanel() {
        let state = AppState()
        let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b")
        state.leftSelection = [a, b]
        state.rightSelection = [a]

        state.deselect([a], in: .left)

        XCTAssertEqual(state.leftSelection, [b])
        XCTAssertEqual(state.rightSelection, [a])
    }

    func testIsContainedUsesPathComponents() {
        XCTAssertTrue(URL(fileURLWithPath: "/Volumes/share/x").isContained(in: shareRoot))
        XCTAssertTrue(shareRoot.isContained(in: shareRoot))
        XCTAssertFalse(URL(fileURLWithPath: "/Volumes/share2/x").isContained(in: shareRoot))
        XCTAssertFalse(URL(fileURLWithPath: "/Volumes").isContained(in: shareRoot))
    }
}
