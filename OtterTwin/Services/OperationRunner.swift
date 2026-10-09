import Foundation
import Observation

/// Runs a copy or move of the selected files and owns its task, so the
/// progress sheet's Cancel stops the real file operation instead of only
/// hiding the sheet (#6).
///
/// - `cancel()` cancels the running task. The service stops at the next chunk,
///   removes the partial or unverified file and never deletes a move's source;
///   the run ends only after that cleanup, and files not yet started are not
///   started at all.
/// - The sheet stays presented after the run ends, showing the final state
///   (`complete`, `partiallyComplete`, `failed` or `cancelled`) until the user
///   dismisses it. `partiallyComplete` (#28) is not a failure: e.g. a move
///   whose verified copy is kept while its source could not be removed.
@MainActor
@Observable
final class OperationRunner {
    /// The operation the progress sheet shows: the current file, or the last one.
    private(set) var currentOperation: FileOperation?
    /// Whether the progress sheet is shown.
    private(set) var isPresented = false
    /// Cancel was requested and the run has not finished its cleanup yet.
    private(set) var isCancelling = false
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Copies or moves `sources` into `destinationDirectory`, one after another.
    /// Ignored while another run is active. `onFinish` runs on the main actor
    /// once the run is over, whatever its outcome (after any cleanup).
    func start(
        kind: OperationKind,
        sources: [URL],
        destinationDirectory: URL,
        provider: any VFSProvider,
        service: FileOperationService,
        onFinish: @escaping @MainActor () -> Void = {}
    ) {
        guard task == nil, !sources.isEmpty else { return }
        isCancelling = false
        isPresented = true
        task = Task {
            await self.run(kind: kind, sources: sources, destinationDirectory: destinationDirectory,
                           provider: provider, service: service)
            self.task = nil
            self.isCancelling = false
            onFinish()
        }
    }

    /// Requests cancellation of the running operation. The sheet stays open and
    /// shows "Cancelled" once the cleanup has finished.
    func cancel() {
        guard let task else { return }
        isCancelling = true
        task.cancel()
    }

    /// Closes the progress sheet. Ignored while a run is active: hiding the
    /// sheet must never leave a file operation running unseen.
    func dismiss() {
        guard task == nil else { return }
        isPresented = false
        currentOperation = nil
    }

    /// Waits until the current run (if any) has finished, including cleanup.
    func waitUntilFinished() async {
        await task?.value
    }

    // MARK: - Private

    private func run(
        kind: OperationKind,
        sources: [URL],
        destinationDirectory: URL,
        provider: any VFSProvider,
        service: FileOperationService
    ) async {
        for source in sources {
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            var operation = FileOperation(source: source, destination: destination, kind: kind)
            // Cancelled between files: the remaining ones are never started.
            if Task.isCancelled {
                operation.state = .cancelled
                currentOperation = operation
                return
            }
            currentOperation = operation

            let (states, sink) = AsyncStream.makeStream(of: OperationState.self)
            // A child task: cancelling this run cancels the operation itself.
            async let outcome = Self.perform(kind, source: source, destination: destination,
                                             provider: provider, service: service, sink: sink)
            // Ends early when the run is cancelled; `outcome` then waits for the cleanup.
            for await state in states {
                operation.state = state
                currentOperation = operation
            }
            // The stream may have stopped before the last states arrived, so the
            // final state comes from the operation's own outcome.
            operation.state = await outcome
            currentOperation = operation
            if case .cancelled = operation.state { return }
        }
    }

    /// Runs one operation; returns its final state (`.complete`,
    /// `.partiallyComplete`, `.failed` or `.cancelled`) once it has finished,
    /// including any cleanup.
    private nonisolated static func perform(
        _ kind: OperationKind,
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        service: FileOperationService,
        sink: AsyncStream<OperationState>.Continuation
    ) async -> OperationState {
        defer { sink.finish() }
        let last = LastState()
        let onState: FileOperationService.StateHandler = { state in
            last.set(state)
            _ = sink.yield(state)
        }
        do {
            switch kind {
            case .copy:
                try await service.copy(source: source, destination: destination, provider: provider, onState: onState)
            case .move:
                try await service.move(source: source, destination: destination, provider: provider, onState: onState)
            }
            return last.get() ?? .complete(result: .skipped)
        } catch {
            return finalState(for: error)
        }
    }

    nonisolated static func finalState(for error: Error) -> OperationState {
        if error is CancellationError { return .cancelled }
        if case .cancelled? = error as? OperationError { return .cancelled }
        return .failed((error as? OperationError) ?? .ioError(error))
    }
}

/// The last state an operation reported; written by the service, read once it is done.
private final class LastState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OperationState?

    func set(_ state: OperationState) { lock.withLock { value = state } }
    func get() -> OperationState? { lock.withLock { value } }
}
