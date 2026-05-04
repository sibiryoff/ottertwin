import SwiftUI

enum Panel { case left, right }

@Observable
final class AppState {
    var activePanel: Panel = .left
    var leftPath: URL = FileManager.default.homeDirectoryForCurrentUser
    var rightPath: URL = FileManager.default.homeDirectoryForCurrentUser
    var leftSelection: Set<URL> = []
    var rightSelection: Set<URL> = []

    var sourcePath: URL { activePanel == .left ? leftPath : rightPath }
    var destPath: URL { activePanel == .left ? rightPath : leftPath }
    var sourceSelection: Set<URL> { activePanel == .left ? leftSelection : rightSelection }

    func togglePanel() { activePanel = activePanel == .left ? .right : .left }
}

struct MainView: View {
    @Environment(SettingsService.self) private var settings
    @State private var appState = AppState()
    @State private var showProgress = false
    @State private var currentOperation: FileOperation?

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(appState: appState, onCopy: triggerCopy, onMove: triggerMove)
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
                    onTabKey: { appState.togglePanel() }
                )

                FilePanelView(
                    panelID: "right",
                    path: $appState.rightPath,
                    selection: $appState.rightSelection,
                    isActive: appState.activePanel == .right,
                    onActivate: { appState.activePanel = .right },
                    onTabKey: { appState.togglePanel() }
                )
            }
        }
        .sheet(isPresented: $showProgress) {
            if let op = currentOperation {
                OperationProgressView(
                    operation: op,
                    state: op.state,
                    onCancel: { showProgress = false }
                )
            }
        }
    }

    // MARK: - Operations

    private func triggerCopy() {
        guard !appState.sourceSelection.isEmpty else { return }
        Task { await runOperations(kind: .copy) }
    }

    private func triggerMove() {
        guard !appState.sourceSelection.isEmpty else { return }
        Task { await runOperations(kind: .move) }
    }

    @MainActor
    private func runOperations(kind: OperationKind) async {
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
            } catch {
                let opError: OperationError = (error as? OperationError) ?? .ioError(error)
                op.state = .failed(opError)
                currentOperation = op
            }
        }
        appState.leftSelection = []
        appState.rightSelection = []
    }
}
