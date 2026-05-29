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
    @State private var showProgress = false
    @State private var currentOperation: FileOperation?
    @State private var activeTask: Task<Void, Never>?

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
        .sheet(isPresented: $showProgress) {
            if let op = currentOperation {
                OperationProgressView(
                    operation: op,
                    state: op.state,
                    onRequestCancel: { activeTask?.cancel() },
                    onDismiss: { showProgress = false }
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

    private func triggerCopy() {
        guard !appState.sourceSelection.isEmpty else { return }
        activeTask = Task { await runOperations(kind: .copy) }
    }

    private func triggerMove() {
        guard !appState.sourceSelection.isEmpty else { return }
        activeTask = Task { await runOperations(kind: .move) }
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
    private func runOperations(kind: OperationKind) async {
        defer { activeTask = nil }
        let provider = LocalProvider()
        // Create service with the live environment settings so chunk size / checksum
        // preferences take effect immediately without requiring an app restart.
        let service = FileOperationService(settings: settings)

        for sourceURL in appState.sourceSelection {
            let destURL = appState.destPath.appendingPathComponent(sourceURL.lastPathComponent)
            var op = FileOperation(source: sourceURL, destination: destURL, kind: kind)
            currentOperation = op
            showProgress = true

            let stream: AsyncThrowingStream<OperationState, Error> = switch kind {
            case .copy: await service.copy(source: sourceURL, destination: destURL, provider: provider)
            case .move: await service.move(source: sourceURL, destination: destURL, provider: provider)
            }

            do {
                for try await state in stream {
                    op.state = state
                    currentOperation = op
                }
                // Stream ended normally but the outer task may already be cancelled
                // (e.g. the cancel button was pressed just as the last chunk arrived).
                if Task.isCancelled {
                    op.state = .cancelled
                    currentOperation = op
                    break
                }
            } catch {
                if error is CancellationError {
                    op.state = .cancelled
                } else if let opError = error as? OperationError, case .cancelled = opError {
                    op.state = .cancelled
                } else {
                    let opError: OperationError = (error as? OperationError) ?? .ioError(error)
                    op.state = .failed(opError)
                }
                currentOperation = op
                if Task.isCancelled { break }
            }
        }
        appState.leftSelection = []
        appState.rightSelection = []
    }
}
