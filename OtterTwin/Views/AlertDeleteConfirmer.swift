import AppKit

/// `DeleteConfirming` backed by NSAlert sheets on the key window (app-modal
/// alert when there is no key window, so a delete is never silently dropped).
@MainActor
struct AlertDeleteConfirmer: DeleteConfirming {
    private static let previewLimit = 5
    private static let failureLimit = 15

    func confirmTrash(_ urls: [URL]) async -> TrashConfirmation {
        let alert = NSAlert()
        alert.messageText = "Move \(Self.itemCount(urls.count)) to Trash?"
        alert.informativeText = Self.previewNames(urls)
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        let permanent = alert.addButton(withTitle: "Delete Permanently\u{2026}")
        permanent.hasDestructiveAction = true

        switch await present(alert) {
        case .alertFirstButtonReturn: return .moveToTrash
        case .alertThirdButtonReturn: return .deletePermanently
        default:                      return .cancel
        }
    }

    func confirmPermanentDelete(_ urls: [URL], reason: PermanentDeleteReason) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permanently delete \(Self.itemCount(urls.count))?"
        let why: String = switch reason {
        case .requestedByUser:  ""
        case .trashUnsupported: "This location does not support the Trash.\n\n"
        case .trashFailed:      "These items could not be moved to the Trash.\n\n"
        }
        alert.informativeText = why + Self.previewNames(urls)
            + "\n\nThis cannot be undone. The items will not be in the Trash."
        // Cancel is the first (default, Return) button so a stray keypress
        // can never confirm an irreversible delete.
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete Permanently")
        delete.hasDestructiveAction = true

        return await present(alert) == .alertSecondButtonReturn
    }

    func showResult(_ result: DeleteResult, offerPermanentDelete: Bool) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(Self.itemCount(result.failures.count)) could not be deleted"

        var lines: [String] = []
        if !result.trashedURLs.isEmpty { lines.append("Moved to Trash: \(result.trashedURLs.count)") }
        if !result.deletedURLs.isEmpty { lines.append("Deleted permanently: \(result.deletedURLs.count)") }
        lines.append("Failed: \(result.failures.count)")
        lines.append("")
        lines += result.failures.prefix(Self.failureLimit).map {
            "\($0.url.lastPathComponent): \($0.error.localizedDescription)"
        }
        if result.failures.count > Self.failureLimit {
            lines.append("\u{2026} and \(result.failures.count - Self.failureLimit) more")
        }
        alert.informativeText = lines.joined(separator: "\n")

        alert.addButton(withTitle: "OK")
        if offerPermanentDelete {
            let delete = alert.addButton(withTitle: "Delete Permanently\u{2026}")
            delete.hasDestructiveAction = true
        }
        return await present(alert) == .alertSecondButtonReturn && offerPermanentDelete
    }

    // MARK: - Helpers

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return alert.runModal()
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private static func itemCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "item" : "items")"
    }

    static func previewNames(_ urls: [URL]) -> String {
        let names = urls.prefix(previewLimit).map(\.lastPathComponent).joined(separator: "\n")
        guard urls.count > previewLimit else { return names }
        return names + "\n\u{2026} and \(urls.count - previewLimit) more"
    }
}
