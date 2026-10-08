import Foundation

// MARK: - Confirmation contract

/// Answer to the first (Trash) confirmation dialog.
enum TrashConfirmation {
    case moveToTrash
    case deletePermanently  // still requires `confirmPermanentDelete` afterwards
    case cancel
}

/// Why a permanent delete is being proposed; drives the dialog wording.
enum PermanentDeleteReason {
    case requestedByUser   // user chose "Delete Permanently…" instead of Trash
    case trashUnsupported  // provider cannot Trash (e.g. SMB share)
    case trashFailed       // Trash was attempted and failed (e.g. network volume)
}

/// The dialogs the delete flow needs. The app uses `AlertDeleteConfirmer`
/// (NSAlert); tests inject a scripted implementation.
@MainActor
protocol DeleteConfirming {
    func confirmTrash(_ urls: [URL]) async -> TrashConfirmation
    /// Separate, stronger confirmation. Returns true only on explicit consent.
    func confirmPermanentDelete(_ urls: [URL], reason: PermanentDeleteReason) async -> Bool
    /// Shows the per-item summary of a delete that had failures. When
    /// `offerPermanentDelete` is true, the summary also offers to permanently
    /// delete the items that could not be moved to Trash; returns true if the
    /// user picked that option (it is still followed by `confirmPermanentDelete`).
    func showResult(_ result: DeleteResult, offerPermanentDelete: Bool) async -> Bool
}

// MARK: - DeleteFlow

/// Deletes the active panel's selection: confirm → delete → refresh → report.
///
/// Safety rules enforced here:
/// - nothing is deleted before the user confirms;
/// - Trash is the default whenever the provider supports it;
/// - permanent deletion always goes through its own explicit confirmation,
///   including the fallback after a failed Trash — never silently;
/// - every per-item failure is reported; panels are refreshed and the
///   selection keeps only the items that still exist.
@MainActor
struct DeleteFlow {
    let appState: AppState
    let service: FileOperationService
    let confirmer: any DeleteConfirming

    /// Returns nil when there was nothing to delete or the user cancelled.
    @discardableResult
    func run() async -> DeleteResult? {
        // Capture the panel up front so focus changes while a dialog is open
        // cannot redirect the operation to the other panel.
        let panel = appState.activePanel
        let urls = appState.selection(for: panel).sorted { $0.path < $1.path }
        guard !urls.isEmpty else { return nil }
        let provider = appState.provider(for: panel)

        let mode: DeleteMode
        if provider.supportsTrash {
            switch await confirmer.confirmTrash(urls) {
            case .moveToTrash:
                mode = .trash
            case .deletePermanently:
                guard await confirmer.confirmPermanentDelete(urls, reason: .requestedByUser) else { return nil }
                mode = .permanent
            case .cancel:
                return nil
            }
        } else {
            guard await confirmer.confirmPermanentDelete(urls, reason: .trashUnsupported) else { return nil }
            mode = .permanent
        }

        var result = await service.deleteItems(urls: urls, mode: mode, provider: provider)
        // Refresh even on total failure: a failed directory removal may have
        // removed part of its contents.
        applyToUI(result, panel: panel)

        guard result.hasFailures else { return result }

        let canFallBack = mode == .trash
        let wantsPermanent = await confirmer.showResult(result, offerPermanentDelete: canFallBack)
        guard canFallBack, wantsPermanent else { return result }

        let retryURLs = result.failures.map(\.url)
        guard await confirmer.confirmPermanentDelete(retryURLs, reason: .trashFailed) else { return result }

        let retry = await service.deleteItems(urls: retryURLs, mode: .permanent, provider: provider)
        applyToUI(retry, panel: panel)
        result = result.applyingRetry(retry)
        if retry.hasFailures {
            _ = await confirmer.showResult(result, offerPermanentDelete: false)
        }
        return result
    }

    private func applyToUI(_ result: DeleteResult, panel: Panel) {
        appState.deselect(result.succeededURLs, in: panel)
        // The other panel may show the same folder or a folder inside a deleted
        // item, so both are refreshed.
        appState.reload(.left)
        appState.reload(.right)
    }
}
