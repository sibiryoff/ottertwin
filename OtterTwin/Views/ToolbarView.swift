import SwiftUI

struct ToolbarView: View {
    @Bindable var appState: AppState
    let onCopy: () -> Void
    let onMove: () -> Void
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

            Button("F8  Delete") { deleteSelected() }
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

    private func deleteSelected() {
        let provider = LocalProvider()
        let urls = appState.sourceSelection
        Task {
            await withThrowingTaskGroup(of: Void.self) { group in
                for url in urls { group.addTask { try await provider.delete(url) } }
                try? await group.waitForAll()
            }
            appState.leftSelection = []
            appState.rightSelection = []
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
