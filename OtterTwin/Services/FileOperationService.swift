import Foundation
import CryptoKit

// MARK: - FileOperationService

actor FileOperationService {
    private let settings: SettingsService

    init(settings: SettingsService) {
        self.settings = settings
    }

    // MARK: - Public interface

    func copy(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution = .skip
    ) -> AsyncThrowingStream<OperationState, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let dest = try await self.resolvedDestination(
                        source: source, destination: destination,
                        provider: provider, resolution: conflictResolution
                    ) else {
                        continuation.yield(.complete(result: .skipped))
                        continuation.finish()
                        return
                    }
                    let result = try await self.performCopy(
                        source: source, destination: dest,
                        provider: provider, continuation: continuation
                    )
                    continuation.yield(.complete(result: result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Cross-volume: copy+verify then delete source. Same-volume: atomic rename.
    func move(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution = .skip
    ) -> AsyncThrowingStream<OperationState, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let sameVolume = self.isSameVolume(source, destination)
                    guard let dest = try await self.resolvedDestination(
                        source: source, destination: destination,
                        provider: provider, resolution: conflictResolution
                    ) else {
                        continuation.yield(.complete(result: .skipped))
                        continuation.finish()
                        return
                    }

                    if sameVolume {
                        let result = try await self.performSameVolumeMove(
                            source: source, destination: dest,
                            provider: provider, continuation: continuation
                        )
                        continuation.yield(.complete(result: result))
                    } else {
                        let result = try await self.performCopy(
                            source: source, destination: dest,
                            provider: provider, continuation: continuation
                        )
                        try await provider.delete(source)
                        continuation.yield(.complete(result: result))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func copyDirectory(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        conflictResolution: ConflictResolution = .skip
    ) -> AsyncThrowingStream<OperationState, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.recursiveCopy(
                        source: source, destination: destination,
                        provider: provider, conflictResolution: conflictResolution,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Core copy+verify

    private func performCopy(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        continuation: AsyncThrowingStream<OperationState, Error>.Continuation
    ) async throws -> VerificationResult {
        let chunkSize = settings.chunkSizeBytes
        let checksumEnabled = settings.checksumEnabled
        let totalSize = source.fileByteCount
        var sourceHasher = SHA256()
        var bytesWritten: Int64 = 0

        let writer: ChunkedWriter
        do { writer = try provider.makeWriter(at: destination) }
        catch { throw OperationError.ioError(error) }

        do {
            for try await chunk in provider.readChunks(of: source, chunkSize: chunkSize) {
                try Task.checkCancellation()
                if checksumEnabled { sourceHasher.update(data: chunk) }
                try writer.write(chunk)
                bytesWritten += Int64(chunk.count)
                let p = totalSize > 0 ? Double(bytesWritten) / Double(totalSize) : 0
                continuation.yield(.copying(progress: min(p, 1.0)))
            }
            try writer.close()
        } catch is CancellationError {
            writer.abort()
            throw OperationError.cancelled
        } catch {
            writer.abort()
            throw OperationError.ioError(error)
        }

        guard checksumEnabled else { return .skipped }

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
                continuation.yield(.verifying(progress: min(p, 1.0)))
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw OperationError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw OperationError.ioError(error)
        }

        let destHex = destHasher.finalize().hexString
        if sourceHex != destHex {
            try? FileManager.default.removeItem(at: destination)
            throw OperationError.checksumMismatch(sourceHash: sourceHex, destHash: destHex)
        }
        return .verified(sourceHash: sourceHex, destHash: destHex)
    }

    // MARK: - Same-volume move (atomic rename)

    private func performSameVolumeMove(
        source: URL,
        destination: URL,
        provider: any VFSProvider,
        continuation: AsyncThrowingStream<OperationState, Error>.Continuation
    ) async throws -> VerificationResult {
        let chunkSize = settings.chunkSizeBytes
        let checksumEnabled = settings.checksumEnabled

        var sourceHex: String?
        if checksumEnabled {
            continuation.yield(.copying(progress: 0))
            let totalSize = source.fileByteCount
            var hasher = SHA256()
            var bytesRead: Int64 = 0
            for try await chunk in provider.readChunks(of: source, chunkSize: chunkSize) {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                bytesRead += Int64(chunk.count)
                let p = totalSize > 0 ? Double(bytesRead) / Double(totalSize) : 0
                continuation.yield(.copying(progress: min(p, 1.0)))
            }
            sourceHex = hasher.finalize().hexString
        }

        // Atomic rename
        try await provider.move(from: source, to: destination)

        guard checksumEnabled, let srcHex = sourceHex else { return .skipped }

        // Sanity-check dest after rename — mismatch indicates a filesystem anomaly
        continuation.yield(.verifying(progress: 0))
        let destSize = destination.fileByteCount
        var destHasher = SHA256()
        var bytesRead: Int64 = 0
        for try await chunk in provider.readChunks(of: destination, chunkSize: chunkSize) {
            try Task.checkCancellation()
            destHasher.update(data: chunk)
            bytesRead += Int64(chunk.count)
            let p = destSize > 0 ? Double(bytesRead) / Double(destSize) : 0
            continuation.yield(.verifying(progress: min(p, 1.0)))
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
        continuation: AsyncThrowingStream<OperationState, Error>.Continuation
    ) async throws {
        try await provider.createDirectory(at: destination)
        let children = try await provider.listDirectory(source)
        for child in children {
            try Task.checkCancellation()
            let childDest = destination.appendingPathComponent(child.name)
            if child.isDirectory {
                try await recursiveCopy(
                    source: child.id, destination: childDest,
                    provider: provider, conflictResolution: conflictResolution,
                    continuation: continuation
                )
            } else {
                guard let dest = try await resolvedDestination(
                    source: child.id, destination: childDest,
                    provider: provider, resolution: conflictResolution
                ) else { continue }
                let result = try await performCopy(
                    source: child.id, destination: dest,
                    provider: provider, continuation: continuation
                )
                continuation.yield(.complete(result: result))
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

    func deleteItems(
        urls: [URL],
        mode: DeleteMode,
        provider: any VFSProvider
    ) async -> DeleteResult {
        var succeeded: [URL] = []
        var failed: [(url: URL, error: Error)] = []
        for url in urls {
            do {
                switch mode {
                case .trash:     try await provider.trash(url)
                case .permanent: try await provider.delete(url)
                }
                succeeded.append(url)
            } catch {
                failed.append((url: url, error: error))
            }
        }
        return DeleteResult(mode: mode, succeededURLs: succeeded, failedURLs: failed)
    }

    // MARK: - Private helpers

    private func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = (try? FileManager.default.attributesOfItem(atPath: a.path)[.systemNumber] as? Int) ?? -1
        let vb = (try? FileManager.default.attributesOfItem(atPath: b.deletingLastPathComponent().path)[.systemNumber] as? Int) ?? -2
        return va == vb
    }
}
