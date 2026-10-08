import SwiftUI

struct ToolbarView: View {
    @Bindable var appState: AppState
    let onCopy: () -> Void
    let onMove: () -> Void
    /// Must run the confirmed delete flow (`DeleteFlow`); never delete directly.
    let onDelete: () -> Void
    @Environment(\.openSettings) private var openSettings

    private var hasSelection: Bool { !appState.sourceSelection.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Button("F5  Copy") { onCopy() }
                .disabled(!hasSelection)
                // No keyboard shortcut here on purpose: an unmodified key (e.g. "c")
                // would start a copy on a stray keypress (#25). F5/F6/F8 are #17.
                .accessibilityIdentifier("toolbar.copy")

            Button("F6  Move") { onMove() }
                .disabled(!hasSelection)
                .accessibilityIdentifier("toolbar.move")

            Button("F8  Delete") { onDelete() }
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

    private func refreshBothPanels() async {
        // Reassign same paths to retrigger .task(id: path) in each FilePanelView.
        let l = appState.leftPath
        let r = appState.rightPath
        appState.leftPath = l
        appState.rightPath = r
    }
}
