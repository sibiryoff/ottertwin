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
    /// only after the cleanup has finished: the partial (temporary) file or the
    /// unverified destination is removed and the source is never touched.
    func copy(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution = .skip,
        onState: @escaping StateHandler
    ) async throws {
        try await reportingCancellation {
            guard let dest = try await self.resolvedDestination(
                source: source, destination: destination,
                provider: provider, resolution: conflictResolution
            ) else {
                onState(.complete(result: .skipped))
                return
            }
            let result = try await self.performCopy(
                source: source, destination: dest,
                provider: provider, onState: onState
            )
            onState(.complete(result: result))
        }
    }

    /// Cross-volume: copy+verify, then delete the source. Same-volume: atomic rename.
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
            guard let dest = try await self.resolvedDestination(
                source: source, destination: destination,
                provider: provider, resolution: conflictResolution
            ) else {
                onState(.complete(result: .skipped))
                return
            }

            if sameVolume {
                let result = try await self.performSameVolumeMove(
                    source: source, destination: dest,
                    provider: provider, onState: onState
                )
                onState(.complete(result: result))
            } else {
                let result = try await self.performCopy(
                    source: source, destination: dest,
                    provider: provider, onState: onState
                )
                // Last point to cancel: the source has not been touched yet.
                // Remove the copy we just made so a cancelled move leaves the
                // file system as it was.
                if Task.isCancelled {
                    await self.removeIncompleteDestination(dest, provider: provider, reason: "move cancelled before source delete")
                    throw OperationError.cancelled
                }
                try await provider.delete(source)
                onState(.complete(result: result))
            }
        }
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

    private func performCopy(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        onState: StateHandler
    ) async throws -> VerificationResult {
        let chunkSize = settings.chunkSizeBytes
        let checksumEnabled = settings.checksumEnabled
        let totalSize = source.fileByteCount
        var sourceHasher = SHA256()
        var bytesWritten: Int64 = 0

        try Task.checkCancellation()
        let writer: ChunkedWriter
        do {
            writer = try provider.makeWriter(at: destination)
        } catch {
            if Self.isFileExistsError(error) { throw OperationError.conflict(existingURL: destination) }
            throw OperationError.ioError(error)
        }

        // The writer stores the data in a temporary file in the destination
        // folder, unique to this operation; only `close()` moves it into place.
        // `abort()` removes the temporary file and never touches `destination`.
        do {
            for try await chunk in provider.readChunks(of: source, chunkSize: chunkSize) {
                try Task.checkCancellation()
                if checksumEnabled { sourceHasher.update(data: chunk) }
                try writer.write(chunk)
                bytesWritten += Int64(chunk.count)
                let p = totalSize > 0 ? Double(bytesWritten) / Double(totalSize) : 0
                onState(.copying(progress: min(p, 1.0)))
            }
            // A cancelled task can end a provider's stream early *without*
            // throwing; never finalize a file that may be truncated.
            try Task.checkCancellation()
            try writer.close()
        } catch is CancellationError {
            writer.abort()
            throw OperationError.cancelled
        } catch {
            writer.abort()
            if Self.isFileExistsError(error) { throw OperationError.conflict(existingURL: destination) }
            throw OperationError.ioError(error)
        }

        guard checksumEnabled else {
            Self.logger.warning("Checksum verification skipped for destination: \(destination.path, privacy: .public)")
            return .skipped
        }

        // From here on `destination` is the file this operation created
        // (exclusively), so removing it on cancel or failure is safe.
        let sourceHex = sourceHasher.finalize().hexString
        var destHasher = SHA256()
        var bytesVerified: Int64 = 0
        let destSize = destination.fileByteCount

        do {
            for try await chunk in provider.readChunks(of: destination, chunkSize: chunkSize) {
                try Task.checkCancellation()
                destHasher.update(data: chunk)
                bytesVerified += Int64(chunk.count)
                let p = destSize > 0 ? Double(bytesVerified) / Double(destSize) : 0
                onState(.verifying(progress: min(p, 1.0)))
            }
            // An early, silent end of the stream must not count as verified.
            try Task.checkCancellation()
        } catch is CancellationError {
            await removeIncompleteDestination(destination, provider: provider, reason: "verification cancelled")
            throw OperationError.cancelled
        } catch {
            await removeIncompleteDestination(destination, provider: provider, reason: "verification failed")
            throw OperationError.ioError(error)
        }

        let destHex = destHasher.finalize().hexString
        if sourceHex != destHex {
            await removeIncompleteDestination(destination, provider: provider, reason: "checksum mismatch")
            throw OperationError.checksumMismatch(sourceHash: sourceHex, destHash: destHex)
        }
        return .verified(sourceHash: sourceHex, destHash: destHex)
    }

    /// Removes a destination this operation created but did not verify. The
    /// error that led here is what gets reported, so a failed removal is logged
    /// rather than thrown; it is never silently ignored.
    private func removeIncompleteDestination(_ destination: URL, provider: any VFSProvider, reason: String) async {
        do {
            try await provider.delete(destination)
        } catch {
            Self.logger.error("Could not remove unverified destination \(destination.lastPathComponent, privacy: .private) (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Same-volume move (atomic rename)

    private func performSameVolumeMove(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        onState: StateHandler
    ) async throws -> VerificationResult {
        let chunkSize = settings.chunkSizeBytes
        let checksumEnabled = settings.checksumEnabled

        var sourceHex: String?
        if checksumEnabled {
            onState(.copying(progress: 0))
            let totalSize = source.fileByteCount
            var hasher = SHA256()
            var bytesRead: Int64 = 0
            for try await chunk in provider.readChunks(of: source, chunkSize: chunkSize) {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                bytesRead += Int64(chunk.count)
                let p = totalSize > 0 ? Double(bytesRead) / Double(totalSize) : 0
                onState(.copying(progress: min(p, 1.0)))
            }
            sourceHex = hasher.finalize().hexString
        }

        // Last point to cancel: nothing has been changed yet.
        try Task.checkCancellation()
        // Atomic rename
        try await provider.move(from: source, to: destination)

        guard checksumEnabled, let srcHex = sourceHex else {
            Self.logger.warning("Checksum verification skipped for same-volume move destination: \(destination.path, privacy: .public)")
            return .skipped
        }

        // Sanity-check dest after rename — mismatch indicates a filesystem anomaly.
        // The rename has happened and cannot be cancelled any more: cancelling
        // now only stops this check, and the move is reported as complete with
        // the checksum skipped (the file exists exactly once, at the destination).
        onState(.verifying(progress: 0))
        let destSize = destination.fileByteCount
        var destHasher = SHA256()
        var bytesRead: Int64 = 0
        do {
            for try await chunk in provider.readChunks(of: destination, chunkSize: chunkSize) {
                try Task.checkCancellation()
                destHasher.update(data: chunk)
                bytesRead += Int64(chunk.count)
                let p = destSize > 0 ? Double(bytesRead) / Double(destSize) : 0
                onState(.verifying(progress: min(p, 1.0)))
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            Self.logger.warning("Post-rename check cancelled for same-volume move destination: \(destination.path, privacy: .public)")
            return .skipped
        }
        let destHex = destHasher.finalize().hexString
        if srcHex != destHex {
            throw OperationError.checksumMismatch(sourceHash: srcHex, destHash: destHex)
        }
        return .verified(sourceHash: srcHex, destHash: destHex)
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
                guard let dest = try await resolvedDestination(
                    source: child.id, destination: childDest,
                    provider: provider, resolution: conflictResolution
                ) else { continue }
                let result = try await performCopy(
                    source: child.id, destination: dest,
                    provider: provider, onState: onState
                )
                onState(.complete(result: result))
            }
        }
    }

    // MARK: - Conflict resolution

    /// Returns resolved destination URL, or nil if the file should be skipped.
    private func resolvedDestination(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        resolution: ConflictResolution
    ) async throws -> URL? {
        guard FileManager.default.fileExists(atPath: destination.path) else { return destination }
        switch resolution {
        case .skip:     return nil
        case .overwrite: try await provider.delete(destination); return destination
        case .rename:   return uniqueDestination(base: destination)
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
        } while FileManager.default.fileExists(atPath: candidate.path)
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

    private func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = Self.volumeIdentifier(for: a),
              let vb = Self.volumeIdentifier(for: b.deletingLastPathComponent()) else {
            return false
        }
        return va == vb
    }

    private static func volumeIdentifier(for url: URL) -> NSNumber? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.systemNumber] as? NSNumber
    }

    private static func isFileExistsError(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            return posix.code == .EEXIST
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EEXIST)
    }
}
