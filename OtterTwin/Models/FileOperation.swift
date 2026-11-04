import Foundation

// MARK: - FileOperation

struct FileOperation: Identifiable {
    let id: UUID
    let source: URL
    let destination: URL
    let kind: OperationKind
    var state: OperationState

    init(id: UUID = UUID(), source: URL, destination: URL, kind: OperationKind) {
        self.id = id
        self.source = source
        self.destination = destination
        self.kind = kind
        self.state = .pending
    }
}

// MARK: - Supporting enums

enum OperationKind {
    case copy
    case move
}

enum OperationState {
    case pending
    case copying(progress: Double)    // 0–1, source-read / write phase
    case verifying(progress: Double)  // 0–1, dest-read phase
    case complete(result: VerificationResult)
    /// Everything that keeps the data safe succeeded, but not all of the
    /// operation (#28): e.g. a move whose verified copy is kept while its
    /// source could not be removed. Not a failure: nothing is cleaned up.
    case partiallyComplete(result: VerificationResult, issue: PartialCompletionIssue)
    case failed(OperationError)
    case cancelled
}

enum VerificationResult {
    /// The destination was flushed to storage (`flushMode`), then read back
    /// through a new descriptor (`cacheBypassed`: with `F_NOCACHE`), and its
    /// SHA-256 matched the source's (#28).
    case verified(sourceHash: String, destHash: String, flushMode: FlushMode, cacheBypassed: Bool)
    case skipped  // checksumEnabled == false (copies only), or conflict skipped
    /// Same-volume move (#28): an atomic rename. The data was not rewritten,
    /// so there was nothing to verify.
    case renamed
}

/// What was left undone by a `.partiallyComplete` operation (#28).
enum PartialCompletionIssue {
    /// A cross-volume move copied and verified the file, but deleting the
    /// source failed. Both copies exist.
    case sourceNotRemoved(Error)
}

/// Why a cross-volume move kept its source after a verified copy (#54): the
/// source changed (or was replaced) after it was copied, so deleting it could
/// lose data that is not in the copy. Reported as `.sourceNotRemoved(…)`.
struct SourceChangedAfterCopyError: Error, LocalizedError {
    var errorDescription: String? {
        "The source changed after it was copied, so it was kept. Check both files."
    }
}

enum OperationError: Error {
    case checksumMismatch(sourceHash: String, destHash: String)
    case ioError(Error)
    case cancelled
    case conflict(existingURL: URL)
    /// A same-volume `.overwrite` move failed and the original destination is
    /// not in its place (#52); the move did not fall back to a copy and the
    /// source is kept. `parkedOriginal`: the original was parked under a
    /// hidden `.old` name and putting it back failed; this is where it is now.
    /// nil: nothing was parked, the destination item was simply no longer
    /// there. `underlying` is why the move failed.
    case originalNotRestored(parkedOriginal: URL?, underlying: Error)
    /// The source file changed while it was being copied (#54): its size or
    /// modification time is not what it was when the copy started, or fewer or
    /// more bytes were read than it had then. The copy may be a mix of old and
    /// new data, so it was discarded: the destination is untouched, no partial
    /// file is left, and a move keeps its source.
    case sourceChanged
}

enum ConflictResolution {
    case skip
    case overwrite
    case rename  // appends "-2", "-3", … suffix
}

// MARK: - Delete types

enum DeleteMode {
    case trash      // Move to macOS Trash (default)
    case permanent  // Irreversible removal — requires a separate explicit confirmation
}

struct DeleteFailure {
    let url: URL
    let mode: DeleteMode
    let error: Error
}

/// Per-item outcome of a delete operation. Nothing is dropped: every requested
/// URL ends up in exactly one of the three lists.
struct DeleteResult {
    var trashedURLs: [URL] = []
    var deletedURLs: [URL] = []
    var failures: [DeleteFailure] = []

    var succeededURLs: [URL] { trashedURLs + deletedURLs }
    var hasFailures: Bool { !failures.isEmpty }

    /// Replaces the failures of `self` with the outcome of a follow-up
    /// operation that retried exactly those failed URLs.
    func applyingRetry(_ retry: DeleteResult) -> DeleteResult {
        DeleteResult(
            trashedURLs: trashedURLs + retry.trashedURLs,
            deletedURLs: deletedURLs + retry.deletedURLs,
            failures: retry.failures
        )
    }
}
