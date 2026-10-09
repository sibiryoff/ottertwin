import SwiftUI

enum Panel { case left, right }

@Observable
final class AppState {
    var activePanel: Panel = .left
    var leftPath: URL = FileManager.default.homeDirectoryForCurrentUser
    var rightPath: URL = FileManager.default.homeDirectoryForCurrentUser
    var leftSelection: Set<URL> = []
    var rightSelection: Set<URL> = []
    /// Last provider attached to each panel (e.g. an SMB share after connecting).
    /// Use `provider(for:)` to get the one matching the panel's current path.
    var leftProvider: any VFSProvider = LocalProvider()
    var rightProvider: any VFSProvider = LocalProvider()
    /// Bumped to force a panel to re-list its directory without changing path.
    var leftReloadToken = 0
    var rightReloadToken = 0

    var sourcePath: URL { activePanel == .left ? leftPath : rightPath }
    var destPath: URL { activePanel == .left ? rightPath : leftPath }
    var sourceSelection: Set<URL> { activePanel == .left ? leftSelection : rightSelection }
    var sourceProvider: any VFSProvider { provider(for: activePanel) }

    init() {
        #if DEBUG
        // UI tests point both panels at a disposable temp folder so they never
        // operate on the real home folder.
        if let start = ProcessInfo.processInfo.environment["OTTERTWIN_UITEST_START_DIR"] {
            leftPath = URL(fileURLWithPath: start, isDirectory: true)
            rightPath = leftPath
        }
        #endif
    }

    func togglePanel() { activePanel = activePanel == .left ? .right : .left }

    func path(for panel: Panel) -> URL { panel == .left ? leftPath : rightPath }

    func selection(for panel: Panel) -> Set<URL> { panel == .left ? leftSelection : rightSelection }

    /// The provider that serves the panel's *current* path: the attached provider
    /// while the path is inside it (e.g. inside a mounted SMB share), otherwise
    /// the local file system — so leaving a share restores local/Trash behaviour.
    func provider(for panel: Panel) -> any VFSProvider {
        let attached = panel == .left ? leftProvider : rightProvider
        return attached.manages(path(for: panel)) ? attached : LocalProvider()
    }

    func deselect(_ urls: [URL], in panel: Panel) {
        switch panel {
        case .left:  leftSelection.subtract(urls)
        case .right: rightSelection.subtract(urls)
        }
    }

    func reload(_ panel: Panel) {
        switch panel {
        case .left:  leftReloadToken += 1
        case .right: rightReloadToken += 1
        }
    }
}

struct MainView: View {
    @Environment(SettingsService.self) private var settings
    @State private var appState = AppState()
    /// Owns the running copy/move task, so Cancel stops the real operation (#6).
    @State private var operations = OperationRunner()

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(appState: appState, onCopy: triggerCopy, onMove: triggerMove, onDelete: triggerDelete)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            Divider()
            HSplitView {
                FilePanelView(
                    panelID: "left",
                    path: $appState.leftPath,
                    selection: $appState.leftSelection,
                    isActive: appState.activePanel == .left,
                    onActivate: { appState.activePanel = .left },
                    onProviderChange: { appState.leftProvider = $0 },
                    reloadToken: appState.leftReloadToken
                )

                FilePanelView(
                    panelID: "right",
                    path: $appState.rightPath,
                    selection: $appState.rightSelection,
                    isActive: appState.activePanel == .right,
                    onActivate: { appState.activePanel = .right },
                    onProviderChange: { appState.rightProvider = $0 },
                    reloadToken: appState.rightReloadToken
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { operations.isPresented },
            set: { if !$0 { operations.dismiss() } }
        )) {
            if let op = operations.currentOperation {
                OperationProgressView(
                    operation: op,
                    state: op.state,
                    isCancelling: operations.isCancelling,
                    onCancel: { operations.cancel() },
                    onDismiss: { operations.dismiss() }
                )
            }
        }
        .onKeyPress(.tab) {
            appState.togglePanel()
            return .handled
        }
        .focusable()
    }

    // MARK: - Operations

    @MainActor
    private func triggerCopy() {
        runOperations(kind: .copy)
    }

    @MainActor
    private func triggerMove() {
        runOperations(kind: .move)
    }

    /// Confirm → Trash (or explicitly confirmed permanent delete) → refresh → report.
    @MainActor
    private func triggerDelete() {
        guard !appState.sourceSelection.isEmpty else { return }
        let flow = DeleteFlow(
            appState: appState,
            service: FileOperationService(settings: settings),
            confirmer: AlertDeleteConfirmer()
        )
        Task { await flow.run() }
    }

    @MainActor
    private func runOperations(kind: OperationKind) {
        let sources = appState.sourceSelection.sorted { $0.path < $1.path }
        guard !sources.isEmpty, !operations.isRunning else { return }
        let appState = appState
        operations.start(
            kind: kind,
            sources: sources,
            destinationDirectory: appState.destPath,
            provider: LocalProvider(),
            // Create service with the live environment settings so chunk size / checksum
            // preferences take effect immediately without requiring an app restart.
            service: FileOperationService(settings: settings),
            onFinish: {
                appState.leftSelection = []
                appState.rightSelection = []
                // Show the result in both panels, including after a cancel or a
                // failure (whose cleanup removed the partial file).
                appState.reload(.left)
                appState.reload(.right)
            }
        )
    }
}
