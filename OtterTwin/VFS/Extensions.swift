import Foundation
import CryptoKit

extension URL {
    var fileByteCount: Int64 {
        (try? resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
    }

    /// True when `self` is `ancestor` or lies anywhere below it (path-component
    /// comparison, so `/Volumes/share2` is not inside `/Volumes/share`).
    func isContained(in ancestor: URL) -> Bool {
        standardizedFileURL.pathComponents.starts(with: ancestor.standardizedFileURL.pathComponents)
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
