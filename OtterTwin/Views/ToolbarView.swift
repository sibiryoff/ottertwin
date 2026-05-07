import AppKit
import SwiftUI

struct ToolbarView: View {
    @Bindable var appState: AppState
    let onCopy: () -> Void
    let onMove: () -> Void
    @Environment(SettingsService.self) private var settings
    @Environment(\.openSettings) private var openSettings

    private var hasSelection: Bool { !appState.sourceSelection.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Button("F5  Copy") { onCopy() }
                .disabled(!hasSelection)
                .keyboardShortcut("c", modifiers: [])  // F5 handled via onKeyPress below
                .accessibilityIdentifier("toolbar.copy")

            Button("F6  Move") { onMove() }
                .disabled(!hasSelection)
                .accessibilityIdentifier("toolbar.move")

            Button("F8  Delete") { Task { await deleteSelected() } }
                .disabled(!hasSelection)
                .accessibilityIdentifier("toolbar.delete")

            Spacer()

            Button {
                Task { await refreshBothPanels() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
            .accessibilityIdentifier("toolbar.refresh")

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gear")
                    .labelStyle(.iconOnly)
            }
            .help("Settings (⌘,)")
            .accessibilityIdentifier("toolbar.settings")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Delete flow

    @MainActor
    private func deleteSelected() async {
        let urls = Array(appState.sourceSelection)
        guard !urls.isEmpty else { return }

        let provider = appState.sourceProvider

        guard let mode = await confirmDelete(urls: urls, provider: provider) else { return }

        let service = FileOperationService(settings: settings)
        let result = await service.deleteItems(urls: urls, mode: mode, provider: provider)

        refreshSourcePanel()
        appState.leftSelection = []
        appState.rightSelection = []

        if result.hasFailures {
            await showDeleteResult(result)
        }
    }

    // MARK: - Confirmation dialogs

    @MainActor
    private func confirmDelete(urls: [URL], provider: any VFSProvider) async -> DeleteMode? {
        guard let window = NSApp.keyWindow else { return nil }

        if provider.supportsTrash {
            let primary = await showTrashConfirmation(urls: urls, window: window)
            switch primary {
            case .trash:     return .trash
            case .permanent: return await confirmPermanentDelete(urls: urls, window: window) ? .permanent : nil
            case nil:        return nil
            }
        } else {
            return await confirmPermanentDelete(urls: urls, window: window) ? .permanent : nil
        }
    }

    @MainActor
    private func showTrashConfirmation(urls: [URL], window: NSWindow) async -> DeleteMode? {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            let count = urls.count
            alert.messageText = "Move \(count) \(count == 1 ? "item" : "items") to Trash?"
            alert.informativeText = previewNames(urls)
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            let permButton = alert.addButton(withTitle: "Delete Permanently\u{2026}")
            permButton.hasDestructiveAction = true

            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn:  continuation.resume(returning: .trash)
                case .alertThirdButtonReturn:  continuation.resume(returning: .permanent)
                default:                       continuation.resume(returning: nil)
                }
            }
        }
    }

    @MainActor
    private func confirmPermanentDelete(urls: [URL], window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            let count = urls.count
            alert.messageText = "Permanently delete \(count) \(count == 1 ? "item" : "items")?"
            alert.informativeText = previewNames(urls) + "\n\nThis cannot be undone."
            alert.alertStyle = .critical
            let deleteButton = alert.addButton(withTitle: "Delete Permanently")
            deleteButton.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")

            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    // MARK: - Result summary

    @MainActor
    private func showDeleteResult(_ result: DeleteResult) async {
        guard let window = NSApp.keyWindow else { return }
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            let failCount = result.failedURLs.count
            let succCount = result.succeededURLs.count
            alert.messageText = "\(failCount) \(failCount == 1 ? "item" : "items") could not be deleted"
            var lines: [String] = []
            if succCount > 0 {
                let verb = result.mode == .trash ? "Moved to Trash" : "Deleted"
                lines.append("\(verb): \(succCount)")
            }
            lines.append(contentsOf: result.failedURLs.map {
                "\($0.url.lastPathComponent): \($0.error.localizedDescription)"
            })
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: "OK")

            alert.beginSheetModal(for: window) { _ in continuation.resume() }
        }
    }

    // MARK: - Helpers

    private func previewNames(_ urls: [URL]) -> String {
        let names = urls.prefix(5).map(\.lastPathComponent).joined(separator: "\n")
        if urls.count > 5 {
            return names + "\n\u{2026} and \(urls.count - 5) more"
        }
        return names
    }

    private func refreshSourcePanel() {
        if appState.activePanel == .left {
            let p = appState.leftPath
            appState.leftPath = p
        } else {
            let p = appState.rightPath
            appState.rightPath = p
        }
    }

    private func refreshBothPanels() async {
        // Reassign same paths to retrigger .task(id: path) in each FilePanelView.
        let l = appState.leftPath
        let r = appState.rightPath
        appState.leftPath = l
        appState.rightPath = r
    }
}
