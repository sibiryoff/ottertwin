import Foundation

struct FileItem: Identifiable, Hashable, Equatable {
    let id: URL
    let name: String
    let size: Int64
    let modificationDate: Date
    let isDirectory: Bool

    var displaySize: String {
        guard !isDirectory else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
