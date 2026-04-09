import Foundation
import CryptoKit

// MARK: - Progress type

enum ChecksumProgress {
    case progress(Double)         // 0–1
    case complete(hexDigest: String)
}

// MARK: - ChecksumService

final class ChecksumService {
    /// Stream SHA-256 progress events while hashing `url` in `chunkSize` chunks.
    /// Cancellation is checked at each chunk boundary.
    func hash(url: URL, chunkSize: Int) -> AsyncThrowingStream<ChecksumProgress, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                do {
                    let totalSize = url.fileByteCount
                    var hasher = SHA256()
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }

                    var bytesRead: Int64 = 0
                    while true {
                        try Task.checkCancellation()
                        let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                        if chunk.isEmpty { break }
                        hasher.update(data: chunk)
                        bytesRead += Int64(chunk.count)
                        let progress = totalSize > 0 ? Double(bytesRead) / Double(totalSize) : 0
                        continuation.yield(.progress(min(progress, 1.0)))
                    }

                    continuation.yield(.complete(hexDigest: hasher.finalize().hexString))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
