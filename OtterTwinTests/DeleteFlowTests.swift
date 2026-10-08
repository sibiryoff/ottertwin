import XCTest
@testable import OtterTwin

/// #5: the confirm → delete → refresh → report flow behind the toolbar's Delete.
/// All fixtures live in a per-test temp directory.
final class DeleteFlowTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var panelDir: URL!
    private var appState: AppState!
    private var confirmer: ScriptedDeleteConfirmer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("DeleteFlowTests-\(UUID().uuidString)", isDirectory: true)
        panelDir = tempDir.appendingPathComponent("panel", isDirectory: true)
        try fm.createDirectory(at: panelDir, withIntermediateDirectories: true)
        appState = AppState()
        appState.leftPath = panelDir
        appState.rightPath = panelDir
        appState.activePanel = .left
        // XCTest runs lifecycle methods on the main thread.
        confirmer = MainActor.assumeIsolated { ScriptedDeleteConfirmer() }
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        appState = nil
        confirmer = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeFiles(_ names: [String]) throws -> [URL] {
        try names.map { name in
            let url = panelDir.appendingPathComponent(name)
            try Data("content of \(name)".utf8).write(to: url)
            return url
        }
    }

    private func makeProvider(supportsTrash: Bool = true) -> FaultInjectingDeleteProvider {
        FaultInjectingDeleteProvider(
            fakeTrash: tempDir.appendingPathComponent("FakeTrash", isDirectory: true),
            supportsTrash: supportsTrash
        )
    }

    @MainActor
    private func runFlow() async -> DeleteResult? {
        await DeleteFlow(
            appState: appState,
            service: FileOperationService(settings: SettingsService()),
            confirmer: confirmer
        ).run()
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    // MARK: - Confirmation is always required

    @MainActor
    func testCancelFromConfirmationDeletesNothingAndKeepsUIState() async throws {
        let files = try makeFiles(["a.txt", "b.txt"])
        let provider = makeProvider()
        appState.leftProvider = provider
        appState.leftSelection = Set(files)

        confirmer.trashAnswer = .cancel
        let result = await runFlow()

        XCTAssertNil(result)
        XCTAssertEqual(confirmer.trashQuestions.count, 1, "Delete must ask before doing anything")
        XCTAssertEqual(Set(confirmer.trashQuestions[0]), Set(files), "Dialog lists the selected items")
        XCTAssertTrue(confirmer.permanentQuestions.isEmpty)
        XCTAssertTrue(provider.trashCalls.isEmpty)
        XCTAssertTrue(provider.deleteCalls.isEmpty)
        XCTAssertTrue(files.allSatisfy(exists))
        XCTAssertEqual(appState.leftSelection, Set(files), "Cancel must keep the selection")
        XCTAssertEqual(appState.leftReloadToken, 0)
    }

    @MainActor
    func testFilesStillExistWhenConfirmationIsAsked() async throws {
        let files = try makeFiles(["a.txt"])
        appState.leftProvider = makeProvider()
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .moveToTrash

        _ = await runFlow()

        XCTAssertEqual(confirmer.trashQuestions.count, 1)
        XCTAssertTrue(confirmer.allItemsExistedWhenAsked, "Nothing may be removed before the user confirms")
    }

    @MainActor
    func testEmptySelectionAsksNothingAndDoesNothing() async throws {
        let provider = makeProvider()
        appState.leftProvider = provider

        let result = await runFlow()

        XCTAssertNil(result)
        XCTAssertTrue(confirmer.trashQuestions.isEmpty)
        XCTAssertTrue(confirmer.permanentQuestions.isEmpty)
        XCTAssertTrue(provider.trashCalls.isEmpty)
    }

    // MARK: - Trash by default

    @MainActor
    func testConfirmedDeleteMovesToTrashNotPermanent() async throws {
        let files = try makeFiles(["a.txt", "b.txt"])
        let provider = makeProvider()
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .moveToTrash

        let outcome = await runFlow()
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(Set(result.trashedURLs), Set(files))
        XCTAssertTrue(result.deletedURLs.isEmpty)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(Set(provider.trashCalls), Set(files))
        XCTAssertTrue(provider.deleteCalls.isEmpty, "Permanent delete must not be used by default")
        XCTAssertTrue(confirmer.permanentQuestions.isEmpty)
        XCTAssertTrue(confirmer.shownResults.isEmpty, "No failure summary on full success")
        XCTAssertFalse(files.contains(where: exists))
    }

    /// End-to-end with the real `LocalProvider`: a local file ends up in the
    /// user's Trash with identical content. The trashed item is removed again.
    @MainActor
    func testLocalFileIsMovedToRealTrashByDefault() async throws {
        let unique = "OtterTwin-DeleteFlowTests-\(UUID().uuidString).txt"
        let file = try makeFiles([unique])[0]
        let original = try Data(contentsOf: file)
        appState.leftSelection = [file]  // default provider: LocalProvider
        XCTAssertTrue(appState.sourceProvider is LocalProvider)
        confirmer.trashAnswer = .moveToTrash

        let outcome = await runFlow()
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.trashedURLs, [file])
        XCTAssertFalse(exists(file))
        let trashDir = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: file, create: false)
        let trashed = trashDir.appendingPathComponent(unique)
        XCTAssertTrue(exists(trashed), "Item must be in the Trash, not permanently deleted")
        if exists(trashed) {
            XCTAssertEqual(try Data(contentsOf: trashed), original)
            try fm.removeItem(at: trashed)
        }
    }

    // MARK: - Permanent delete needs its own confirmation

    @MainActor
    func testPermanentDeleteFromTrashDialogNeedsSecondConfirmation_declined() async throws {
        let files = try makeFiles(["a.txt"])
        let provider = makeProvider()
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .deletePermanently
        confirmer.permanentAnswers = [false]

        let result = await runFlow()

        XCTAssertNil(result)
        XCTAssertEqual(confirmer.permanentQuestions.map { $0.reason }, [.requestedByUser])
        XCTAssertTrue(provider.deleteCalls.isEmpty)
        XCTAssertTrue(provider.trashCalls.isEmpty)
        XCTAssertTrue(files.allSatisfy(exists))
        XCTAssertEqual(appState.leftSelection, Set(files))
    }

    @MainActor
    func testPermanentDeleteFromTrashDialogNeedsSecondConfirmation_confirmed() async throws {
        let files = try makeFiles(["a.txt"])
        let provider = makeProvider()
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .deletePermanently
        confirmer.permanentAnswers = [true]

        let outcome = await runFlow()
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.deletedURLs, files)
        XCTAssertTrue(provider.trashCalls.isEmpty)
        XCTAssertFalse(exists(files[0]))
    }

    @MainActor
    func testProviderWithoutTrashAsksForPermanentConfirmation() async throws {
        let files = try makeFiles(["a.txt"])
        let provider = makeProvider(supportsTrash: false)
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.permanentAnswers = [false]

        let result = await runFlow()

        XCTAssertNil(result)
        XCTAssertTrue(confirmer.trashQuestions.isEmpty, "Trash must not be offered when unsupported")
        XCTAssertEqual(confirmer.permanentQuestions.map { $0.reason }, [.trashUnsupported])
        XCTAssertTrue(provider.deleteCalls.isEmpty)
        XCTAssertTrue(files.allSatisfy(exists))
    }

    // MARK: - Trash failure → explicit permanent delete, never silent

    @MainActor
    func testTrashFailureIsReportedAndNotSilentlyDeletedPermanently() async throws {
        let files = try makeFiles(["a.txt"])
        let provider = makeProvider()
        provider.trashFaults[files[0]] = InjectedFault(message: "Volume has no Trash")
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .moveToTrash
        confirmer.resultAnswer = false  // user just acknowledges the summary

        let outcome = await runFlow()
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.failures.map(\.url), files)
        XCTAssertEqual(confirmer.shownResults.count, 1)
        XCTAssertTrue(confirmer.shownResults[0].offeredPermanent, "Summary offers permanent delete as an explicit choice")
        XCTAssertTrue(confirmer.permanentQuestions.isEmpty)
        XCTAssertTrue(provider.deleteCalls.isEmpty, "No silent fallback to permanent delete")
        XCTAssertTrue(exists(files[0]))
        XCTAssertEqual(appState.leftSelection, Set(files), "Failed item stays selected")
    }

    @MainActor
    func testTrashFailureFallbackToPermanentRequiresStrongConfirmation() async throws {
        let files = try makeFiles(["ok.txt", "nas.txt"])
        let provider = makeProvider()
        provider.trashFaults[files[1]] = InjectedFault(message: "Volume has no Trash")
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .moveToTrash
        confirmer.resultAnswer = true
        confirmer.permanentAnswers = [true]

        let outcome = await runFlow()
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(confirmer.permanentQuestions.count, 1)
        XCTAssertEqual(confirmer.permanentQuestions[0].reason, .trashFailed)
        XCTAssertEqual(confirmer.permanentQuestions[0].urls, [files[1]], "Only the failed item is proposed")
        XCTAssertEqual(provider.deleteCalls, [files[1]])
        XCTAssertEqual(result.trashedURLs, [files[0]])
        XCTAssertEqual(result.deletedURLs, [files[1]])
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(confirmer.shownResults.count, 1, "No second summary when the retry succeeded")
        XCTAssertFalse(files.contains(where: exists))
        XCTAssertTrue(appState.leftSelection.isEmpty)
    }

    @MainActor
    func testTrashFailureFallbackDeclinedAtStrongConfirmationKeepsFile() async throws {
        let files = try makeFiles(["nas.txt"])
        let provider = makeProvider()
        provider.trashFaults[files[0]] = InjectedFault(message: "Volume has no Trash")
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .moveToTrash
        confirmer.resultAnswer = true
        confirmer.permanentAnswers = [false]

        let outcome = await runFlow()
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.failures.map(\.url), files)
        XCTAssertTrue(provider.deleteCalls.isEmpty)
        XCTAssertTrue(exists(files[0]))
    }

    // MARK: - Partial failures, provider failures, UI consistency

    @MainActor
    func testMultiSelectionPartialFailureIsReportedPerItem() async throws {
        let files = try makeFiles(["a.txt", "b.txt", "c.txt"])
        let provider = makeProvider()
        let fault = InjectedFault(message: "Permission denied")
        provider.trashFaults[files[1]] = fault
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .moveToTrash

        let outcome = await runFlow()
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(Set(result.trashedURLs), [files[0], files[2]], "A failure must not stop the other items")
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].url, files[1])
        XCTAssertEqual(result.failures[0].error as? InjectedFault, fault)
        XCTAssertEqual(confirmer.shownResults.count, 1, "Partial failure must be reported")
        XCTAssertEqual(confirmer.shownResults[0].result.failures.count, 1)
        XCTAssertEqual(confirmer.shownResults[0].result.trashedURLs.count, 2)
        // UI consistency: only the item that still exists stays selected.
        XCTAssertEqual(appState.leftSelection, [files[1]])
        XCTAssertTrue(exists(files[1]))
    }

    @MainActor
    func testProviderFailureOnPermanentDeleteIsReportedWithoutFallbackOffer() async throws {
        let files = try makeFiles(["a.txt"])
        let provider = makeProvider(supportsTrash: false)
        provider.deleteFaults[files[0]] = InjectedFault(message: "Connection lost")
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.permanentAnswers = [true]

        let outcome = await runFlow()
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.failures.map(\.url), files)
        XCTAssertEqual(result.failures[0].mode, .permanent)
        XCTAssertEqual(confirmer.shownResults.count, 1)
        XCTAssertFalse(confirmer.shownResults[0].offeredPermanent)
        XCTAssertEqual(confirmer.permanentQuestions.count, 1, "No extra confirmation loop")
        XCTAssertTrue(exists(files[0]))
        XCTAssertEqual(appState.leftSelection, Set(files))
        XCTAssertGreaterThan(appState.leftReloadToken, 0, "Panel refreshed even when everything failed")
    }

    // MARK: - Refresh

    @MainActor
    func testPanelsRefreshAfterSuccessfulDelete() async throws {
        let files = try makeFiles(["a.txt"])
        appState.leftProvider = makeProvider()
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .moveToTrash

        _ = await runFlow()

        XCTAssertGreaterThan(appState.leftReloadToken, 0, "Source panel must refresh")
        XCTAssertGreaterThan(appState.rightReloadToken, 0, "Other panel shows the same folder and must refresh")
        XCTAssertTrue(appState.leftSelection.isEmpty)
    }

    @MainActor
    func testPanelsRefreshAfterPartialFailure() async throws {
        let files = try makeFiles(["a.txt", "b.txt"])
        let provider = makeProvider()
        provider.trashFaults[files[0]] = InjectedFault(message: "Busy")
        appState.leftProvider = provider
        appState.leftSelection = Set(files)
        confirmer.trashAnswer = .moveToTrash

        _ = await runFlow()

        XCTAssertGreaterThan(appState.leftReloadToken, 0)
    }

    @MainActor
    func testRightPanelDeleteUsesRightPanelSelectionOnly() async throws {
        let files = try makeFiles(["left.txt", "right.txt"])
        let provider = makeProvider()
        appState.rightProvider = provider
        appState.leftSelection = [files[0]]
        appState.rightSelection = [files[1]]
        appState.activePanel = .right
        confirmer.trashAnswer = .moveToTrash

        let outcome = await runFlow()
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.trashedURLs, [files[1]])
        XCTAssertTrue(exists(files[0]))
        XCTAssertEqual(appState.leftSelection, [files[0]], "Other panel's selection is untouched")
        XCTAssertTrue(appState.rightSelection.isEmpty)
    }
}
