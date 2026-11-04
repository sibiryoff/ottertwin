import SwiftUI

struct OperationProgressView: View {
    let operation: FileOperation
    let state: OperationState
    /// Cancel was requested; the operation is still stopping and cleaning up.
    var isCancelling = false
    /// Requests cancellation of the running operation (#6). The sheet stays open.
    let onCancel: () -> Void
    /// Closes the sheet once the operation has ended (done, failed or cancelled).
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(operation.kind == .copy ? "Copying…" : "Moving…")
                .font(.headline)

            Text(operation.source.lastPathComponent)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            switch state {
            case .pending:
                ProgressView(value: 0)
                Text("Pending…").font(.caption).foregroundStyle(.secondary)

            case .copying(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Copying").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                }

            case .verifying(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Copying").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: 1.0)
                    Text("Verifying").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                }

            case .complete(let result):
                completionView(result: result)

            case .partiallyComplete(_, let issue):
                partialCompletionView(issue: issue)

            case .failed(let error):
                failureView(error: error)

            case .cancelled:
                Label("Cancelled", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("progress.cancelled")
            }

            if isCancelling, !isFinished {
                Text("Cancelling…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("progress.cancelling")
            }

            Spacer()

            HStack {
                Spacer()
                if case .complete = state {
                    Button("Done") { onDismiss() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("progress.done")
                } else if isFinished {
                    Button("Close") { onDismiss() }
                        .accessibilityIdentifier("progress.close")
                } else {
                    Button("Cancel", role: .cancel) { onCancel() }
                        .disabled(isCancelling)
                        .accessibilityIdentifier("progress.cancel")
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 260)
    }

    /// The operation has ended: the sheet offers to close instead of to cancel.
    private var isFinished: Bool {
        switch state {
        case .complete, .partiallyComplete, .failed, .cancelled: return true
        case .pending, .copying, .verifying: return false
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func completionView(result: VerificationResult) -> some View {
        switch result {
        case .verified(let srcHash, let destHash, _, _):
            VStack(alignment: .leading, spacing: 8) {
                Label("Verified", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.bold())

                VStack(alignment: .leading, spacing: 2) {
                    hashRow(label: "Source", hash: srcHash, match: true)
                    hashRow(label: "Dest  ", hash: destHash, match: true)
                }
                .font(.system(.caption, design: .monospaced))
            }

        case .skipped:
            Label("Complete (checksum skipped)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)

        case .renamed:
            Label("Moved (renamed on the same volume)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func partialCompletionView(issue: PartialCompletionIssue) -> some View {
        switch issue {
        case .sourceNotRemoved(let error):
            VStack(alignment: .leading, spacing: 8) {
                Label("Copied and verified — source not removed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.bold())
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("progress.sourceNotRemoved")
        }
    }

    @ViewBuilder
    private func failureView(error: OperationError) -> some View {
        switch error {
        case .checksumMismatch(let src, let dest):
            VStack(alignment: .leading, spacing: 8) {
                Label("Checksum mismatch — destination deleted", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.bold())

                VStack(alignment: .leading, spacing: 2) {
                    hashRow(label: "Source", hash: src,  match: false)
                    hashRow(label: "Dest  ", hash: dest, match: false)
                }
                .font(.system(.caption, design: .monospaced))
            }

        case .ioError(let err):
            Label("I/O error: \(err.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)

        case .conflict(let url):
            Label("Conflict: \(url.lastPathComponent) already exists", systemImage: "doc.badge.plus")
                .foregroundStyle(.orange)

        case .originalNotRestored(let parked, let underlying):
            let text = originalNotRestoredText(parked: parked)
            VStack(alignment: .leading, spacing: 4) {
                Label(text.title, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.bold())
                Text(text.detail)
                    .font(.caption)
                    .textSelection(.enabled)
                Text(underlying.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("progress.originalNotRestored")

        case .sourceChanged:
            VStack(alignment: .leading, spacing: 4) {
                Label("Source changed while it was being copied", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.bold())
                Text(sourceChangedDetail)
                    .font(.caption)
            }
            .accessibilityIdentifier("progress.sourceChanged")
        }
    }

    /// #52 (moves) and #54 (copies): the replaced original could not be put
    /// back (`parked`: where it is kept), or it was no longer there.
    private func originalNotRestoredText(parked: URL?) -> (title: String, detail: String) {
        let isCopy = operation.kind == .copy
        let failed = isCopy ? "Copy failed" : "Move failed"
        let sourceNote = isCopy ? "" : " The source was not moved."
        if let parked {
            return ("\(failed) — the replaced item could not be put back",
                    "It is kept as \(parked.path).\(sourceNote)")
        }
        // Nothing was parked: the destination item had vanished.
        return (failed, "The destination item is no longer there.\(sourceNote)")
    }

    /// #54: the copy was discarded; nothing was changed at the destination.
    private var sourceChangedDetail: String {
        let sourceNote = operation.kind == .copy ? "" : " The source was not removed."
        return "Its size or modification date changed during the copy, so the copy was discarded and the destination was left unchanged.\(sourceNote) Try again once the file is no longer being changed."
    }

    private func hashRow(label: String, hash: String, match: Bool) -> some View {
        HStack(spacing: 4) {
            Text("\(label):").foregroundStyle(.secondary)
            Text(hash).foregroundStyle(match ? .green : .red)
        }
    }
}
