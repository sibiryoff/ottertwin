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
        case .complete, .failed, .cancelled: return true
        case .pending, .copying, .verifying: return false
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func completionView(result: VerificationResult) -> some View {
        switch result {
        case .verified(let srcHash, let destHash):
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
        }
    }

    private func hashRow(label: String, hash: String, match: Bool) -> some View {
        HStack(spacing: 4) {
            Text("\(label):").foregroundStyle(.secondary)
            Text(hash).foregroundStyle(match ? .green : .red)
        }
    }
}
