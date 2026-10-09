import Foundation
import CryptoKit
import OSLog

// MARK: - FileOperationService

actor FileOperationService {
    private static let logger = Logger(subsystem: "OtterTwin", category: "FileOperationService")
    private static let maximumRecursiveCopyDepth = 128

    private let settings: SettingsService

    init(settings: SettingsService) {
        self.settings = settings
    }

    // MARK: - Public interface

    /// Receives every state of an operation, in order, ending with `.complete`.
    typealias StateHandler = @Sendable (OperationState) -> Void

    /// Copies a file and verifies the copy, running in the caller's task.
    ///
    /// Cancellation (#6): cancelling the caller's task stops the copy or the
    /// verification at the next chunk. This throws `OperationError.cancelled`
    /// only after the cleanup has finished: the partial (temporary) file is
    /// removed, and neither the source nor an existing destination is touched.
    ///
    /// `.overwrite` (#27): an existing destination is replaced atomically, and
    /// only after the new copy is complete and verified; any failure or cancel
    /// before that leaves it byte-identical.
    func copy(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution = .skip,
        onState: @escaping StateHandler
    ) async throws {
        try await reportingCancellation {
            guard let target = self.resolvedDestination(
                destination: destination, resolution: conflictResolution
            ) else {
                onState(.complete(result: .skipped))
                return
            }
            let result = try await self.performCopy(
                source: source, target: target,
                provider: provider, onState: onState
            )
            onState(.complete(result: result))
        }
    }

    /// Cross-volume: copy, always verify (whatever `checksumEnabled` says,
    /// #28), then delete the source. If that delete fails, the verified copy is
    /// kept and the move ends `.partiallyComplete(…, .sourceNotRemoved)`.
    /// Same-volume: atomic rename, nothing to verify (`.renamed`).
    /// Runs in the caller's task; see `copy(…onState:)` for cancellation. A
    /// cancelled move never deletes its source.
    func move(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution = .skip,
        onState: @escaping StateHandler
    ) async throws {
        try await reportingCancellation {
            let sameVolume = self.isSameVolume(source, destination)
            guard let target = self.resolvedDestination(
                destination: destination, resolution: conflictResolution
            ) else {
                onState(.complete(result: .skipped))
                return
            }

            if sameVolume {
                do {
                    try await self.performSameVolumeMove(source: source, target: target, provider: provider)
                    onState(.complete(result: .renamed))
                    return
                } catch where Self.isCrossDeviceError(error) {
                    // The rename found the destination on another volume after
                    // all (`EXDEV`; nothing was changed): move it the verified way.
                    Self.logger.info("Rename crossed volumes; moving by verified copy instead")
                }
            }
            try await self.performCrossVolumeMove(source: source, target: target,
                                                  provider: provider, onState: onState)
        }
    }

    /// Copy, always verify, then delete the source (see `move(…onState:)`).
    private func performCrossVolumeMove(
        source: URL,
        target: Target,
        provider: any VFSProvider,
        onState: StateHandler
    ) async throws {
        // The source is deleted below, so the copy must be verified.
        let result = try await performCopy(
            source: source, target: target,
            provider: provider, alwaysVerify: true, onState: onState
        )
        let dest = target.url
        // Last point to cancel: the source has not been touched yet.
        if Task.isCancelled {
            if target.replacesExisting {
                // The verified copy has already replaced the original
                // destination, which is gone: removing the copy would
                // leave neither. Keep it; the source stays untouched.
                Self.logger.warning("Move cancelled after its copy replaced the destination; the copy is kept and the source is not deleted")
            } else {
                // Remove the copy we just made so a cancelled move
                // leaves the file system as it was.
                await removeIncompleteDestination(dest, provider: provider, reason: "move cancelled before source delete")
            }
            throw OperationError.cancelled
        }
        do {
            try await provider.delete(source)
        } catch {
            // The destination is a verified copy: keep it (removing it
            // could lose data if the source is partly gone) and report
            // a partial success instead of a failure.
            Self.logger.error("Move copied and verified \(dest.lastPathComponent, privacy: .private), but the source could not be removed: \(error.localizedDescription, privacy: .private)")
            onState(.partiallyComplete(result: result, issue: .sourceNotRemoved(error)))
            return
        }
        onState(.complete(result: result))
    }

    /// Stream form of `copy(…onState:)`. Ending the iteration early, or
    /// cancelling the task that iterates, cancels the copy; its cleanup then
    /// finishes in the background. Callers that must know when the cleanup is
    /// done (like the UI) use `copy(…onState:)` instead.
    func copy(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution = .skip
    ) -> AsyncThrowingStream<OperationState, Error> {
        makeStream { onState in
            try await self.copy(source: source, destination: destination, provider: provider,
                                conflictResolution: conflictResolution, onState: onState)
        }
    }

    /// Stream form of `move(…onState:)`; cancellation as for the stream `copy`.
    func move(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution = .skip
    ) -> AsyncThrowingStream<OperationState, Error> {
        makeStream { onState in
            try await self.move(source: source, destination: destination, provider: provider,
                                conflictResolution: conflictResolution, onState: onState)
        }
    }

    func copyDirectory(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution = .skip
    ) -> AsyncThrowingStream<OperationState, Error> {
        makeStream { onState in
            do {
                try await self.recursiveCopy(
                    source: source, destination: destination,
                    provider: provider, conflictResolution: conflictResolution,
                    onState: onState,
                    visitedDirectories: [],
                    depth: 0
                )
            } catch is CancellationError {
                throw OperationError.cancelled
            }
        }
    }

    /// Runs `body` in its own task and streams its states. The task is
    /// cancelled when the consumer stops listening (its task was cancelled or
    /// it dropped the stream), so no file I/O outlives the consumer's interest.
    private nonisolated func makeStream(
        _ body: @escaping @Sendable (@escaping StateHandler) async throws -> Void
    ) -> AsyncThrowingStream<OperationState, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body { state in _ = continuation.yield(state) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    /// Normalises cancellation: a `CancellationError` from anywhere below
    /// (provider streams, `Task.checkCancellation`) surfaces as `OperationError.cancelled`.
    private func reportingCancellation(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch is CancellationError {
            throw OperationError.cancelled
        }
    }

    // MARK: - Core copy+verify

    /// Atomic finalize (#27): the copy is written to the writer's temporary
    /// file, verified there, and only then moved into place (or swapped with
    /// the existing destination for `.overwrite`). Every failure or cancel
    /// before that point only discards the temporary file.
    ///
    /// Meaningful verification (#28): the temporary file is flushed to storage
    /// and closed (`finishWriting()`), then read back through a new descriptor
    /// with `F_NOCACHE` (`openForVerification`). The copy is verified when
    /// `checksumEnabled` is on, or always with `alwaysVerify` (moves).
    private func performCopy(
        source: URL,
        target: Target,
        provider: any VFSProvider,
        alwaysVerify: Bool = false,
        onState: StateHandler
    ) async throws -> VerificationResult {
        let destination = target.url
        let chunkSize = settings.chunkSizeBytes
        let verify = settings.checksumEnabled || alwaysVerify
        let totalSize = source.fileByteCount
        var sourceHasher = SHA256()
        var bytesWritten: Int64 = 0

        try Task.checkCancellation()
        let writer: ChunkedWriter
        do {
            writer = try provider.makeWriter(at: destination, replacingExisting: target.replacesExisting)
        } catch {
            if Self.isFileExistsError(error) { throw OperationError.conflict(existingURL: destination) }
            throw OperationError.ioError(error)
        }

        // The writer stores the data in a temporary file in the destination
        // folder, unique to this operation; only `commit()` moves it into place.
        // `abort()` removes the temporary file and never touches `destination`.
        let flushMode: FlushMode
        do {
            for try await chunk in provider.readChunks(of: source, chunkSize: chunkSize) {
                try Task.checkCancellation()
                if verify { sourceHasher.update(data: chunk) }
                try writer.write(chunk)
                bytesWritten += Int64(chunk.count)
                let p = totalSize > 0 ? Double(bytesWritten) / Double(totalSize) : 0
                onState(.copying(progress: min(p, 1.0)))
            }
            // A cancelled task can end a provider's stream early *without*
            // throwing; never finalize a file that may be truncated.
            try Task.checkCancellation()
            flushMode = try writer.finishWriting()
        } catch is CancellationError {
            writer.abort()
            throw OperationError.cancelled
        } catch {
            writer.abort()
            throw OperationError.ioError(error)
        }

        let result: VerificationResult
        if verify {
            let sourceHex = sourceHasher.finalize().hexString
            let (destHex, cacheBypassed) = try await verifiedHash(of: writer, chunkSize: chunkSize, provider: provider, onState: onState)
            guard sourceHex == destHex else {
                writer.abort()
                throw OperationError.checksumMismatch(sourceHash: sourceHex, destHash: destHex)
            }
            result = .verified(sourceHash: sourceHex, destHash: destHex,
                               flushMode: flushMode, cacheBypassed: cacheBypassed)
        } else {
            Self.logger.warning("Checksum verification skipped for destination: \(destination.path, privacy: .public)")
            result = .skipped
        }

        // Applying the source's metadata (#30) belongs here, before the copy
        // becomes visible under its final name.

        // Last point to cancel: the destination has not been touched yet.
        do {
            try Task.checkCancellation()
            try writer.commit()
        } catch is CancellationError {
            writer.abort()
            throw OperationError.cancelled
        } catch {
            writer.abort()
            if Self.isFileExistsError(error) { throw OperationError.conflict(existingURL: destination) }
            throw OperationError.ioError(error)
        }
        return result
    }

    /// Reads back the writer's finished (flushed and closed) temporary file
    /// through a new, uncached descriptor and returns its SHA-256, and whether
    /// the read bypassed the cache. On cancel or error the temporary file is
    /// discarded (`abort()`).
    private func verifiedHash(
        of writer: ChunkedWriter,
        chunkSize: Int,
        provider: any VFSProvider,
        onState: StateHandler
    ) async throws -> (hash: String, cacheBypassed: Bool) {
        var destHasher = SHA256()
        var bytesVerified: Int64 = 0
        let copy = writer.temporaryURL
        let destSize = copy.fileByteCount
        let cacheBypassed: Bool

        do {
            let read = try provider.openForVerification(copy, chunkSize: chunkSize)
            // Bypassed only if neither the written pages nor the read went
            // through this Mac's buffer cache.
            cacheBypassed = writer.writesBypassCache && read.cacheBypassed
            for try await chunk in read.chunks {
                try Task.checkCancellation()
                destHasher.update(data: chunk)
                bytesVerified += Int64(chunk.count)
                let p = destSize > 0 ? Double(bytesVerified) / Double(destSize) : 0
                onState(.verifying(progress: min(p, 1.0)))
            }
            // An early, silent end of the stream must not count as verified.
            try Task.checkCancellation()
        } catch is CancellationError {
            writer.abort()
            throw OperationError.cancelled
        } catch {
            writer.abort()
            throw OperationError.ioError(error)
        }
        return (destHasher.finalize().hexString, cacheBypassed)
    }

    /// Removes a destination this operation created and finalized, when a move
    /// is cancelled before deleting its source. The error that led here is what
    /// gets reported, so a failed removal is logged rather than thrown; it is
    /// never silently ignored.
    private func removeIncompleteDestination(_ destination: URL, provider: any VFSProvider, reason: String) async {
        do {
            try await provider.delete(destination)
        } catch {
            Self.logger.error("Could not remove unverified destination \(destination.lastPathComponent, privacy: .private) (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Same-volume move (atomic rename)

    /// An atomic rename (#28): rename does not touch the data, so there is
    /// nothing to verify and no hashing before or after. (No inode or size
    /// check either: smbfs can derive inode numbers from names, so they may
    /// change on a rename that is perfectly fine.)
    private func performSameVolumeMove(
        source: URL,
        target: Target,
        provider: any VFSProvider
    ) async throws {
        // Last point to cancel: nothing has been changed yet.
        try Task.checkCancellation()
        // `.overwrite` (#27) swaps the existing item out instead of deleting it first.
        if target.replacesExisting {
            try await provider.replaceItem(at: target.url, withItemAt: source)
        } else {
            try await provider.move(from: source, to: target.url)
        }
    }

    // MARK: - Recursive directory copy

    private func recursiveCopy(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution,
        onState: StateHandler,
        visitedDirectories: Set<String>,
        depth: Int
    ) async throws {
        guard depth <= Self.maximumRecursiveCopyDepth else {
            throw OperationError.ioError(POSIXError(.ELOOP))
        }

        let sourceKey = source.resolvingSymlinksInPath().standardizedFileURL.path
        guard !visitedDirectories.contains(sourceKey) else {
            throw OperationError.ioError(POSIXError(.ELOOP))
        }
        var visitedDirectories = visitedDirectories
        visitedDirectories.insert(sourceKey)

        try await provider.createDirectory(at: destination)
        let children = try await provider.listDirectory(source)
        for child in children {
            try Task.checkCancellation()
            let childDest = destination.appendingPathComponent(child.name)
            if child.isDirectory {
                try await recursiveCopy(
                    source: child.id, destination: childDest,
                    provider: provider, conflictResolution: conflictResolution,
                    onState: onState,
                    visitedDirectories: visitedDirectories,
                    depth: depth + 1
                )
            } else {
                guard let target = resolvedDestination(
                    destination: childDest, resolution: conflictResolution
                ) else { continue }
                let result = try await performCopy(
                    source: child.id, target: target,
                    provider: provider, onState: onState
                )
                onState(.complete(result: result))
            }
        }
    }

    // MARK: - Conflict resolution

    /// Where a file goes, and whether it replaces an existing item there.
    private struct Target {
        let url: URL
        let replacesExisting: Bool
    }

    /// Returns the resolved destination, or nil if the file should be skipped.
    /// Nothing is deleted here: `.overwrite` replaces the existing item only
    /// once the new data is in place and verified (#27).
    private func resolvedDestination(
        destination: URL,
        resolution: ConflictResolution
    ) -> Target? {
        guard Self.itemExists(at: destination) else {
            return Target(url: destination, replacesExisting: false)
        }
        switch resolution {
        case .skip:      return nil
        case .overwrite: return Target(url: destination, replacesExisting: true)
        case .rename:    return Target(url: uniqueDestination(base: destination), replacesExisting: false)
        }
    }

    private func uniqueDestination(base: URL) -> URL {
        let dir  = base.deletingLastPathComponent()
        let ext  = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        var counter = 2
        var candidate: URL
        repeat {
            let name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = dir.appendingPathComponent(name)
            counter += 1
        } while Self.itemExists(at: candidate)
        return candidate
    }

    // MARK: - Delete

    /// Deletes `urls` one by one. A failure on one item never stops the others
    /// and is never swallowed: it is recorded in the returned result.
    /// Callers are responsible for obtaining user confirmation first.
    func deleteItems(
        urls: [URL],
        mode: DeleteMode,
        provider: any VFSProvider
    ) async -> DeleteResult {
        var result = DeleteResult()
        for url in urls {
            do {
                switch mode {
                case .trash:
                    try await provider.trash(url)
                    result.trashedURLs.append(url)
                case .permanent:
                    try await provider.delete(url)
                    result.deletedURLs.append(url)
                }
            } catch {
                Self.logger.error("Delete (\(String(describing: mode), privacy: .public)) failed for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                result.failures.append(DeleteFailure(url: url, mode: mode, error: error))
            }
        }
        return result
    }

    // MARK: - Private helpers

    /// Whether moving `source` to `destination` can be a rename (#28). The
    /// source item itself is checked with `lstat` (a symlink is moved, not its
    /// target); the destination folder with `stat`, which follows symlinks, so
    /// a folder that links to another volume counts as that volume. Unknown →
    /// false (the verified copy path). The rename itself also refuses to cross
    /// volumes (`EXDEV`), see `move(…onState:)`.
    private func isSameVolume(_ source: URL, _ destination: URL) -> Bool {
        var sourceInfo = stat(), folderInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0,
              stat(destination.deletingLastPathComponent().path, &folderInfo) == 0 else {
            return false
        }
        return sourceInfo.st_dev == folderInfo.st_dev
    }

    /// `EXDEV`: a rename between two volumes.
    private static func isCrossDeviceError(_ error: Error) -> Bool {
        if let posix = error as? POSIXError { return posix.code == .EXDEV }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return nsError.code == Int(EXDEV) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EXDEV)
        }
        return false
    }

    /// Whether anything is at `url`, without following symlinks: a dangling
    /// symlink counts as an existing item.
    private static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isFileExistsError(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            return posix.code == .EEXIST
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EEXIST)
    }
}
