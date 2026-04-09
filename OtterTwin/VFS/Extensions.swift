import Foundation
import CryptoKit

extension URL {
    var fileByteCount: Int64 {
        (try? resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
