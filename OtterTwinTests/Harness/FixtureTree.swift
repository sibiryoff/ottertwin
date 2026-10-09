import Foundation
import Darwin
@testable import OtterTwin

/// Data-safety harness (#24): builds a disposable directory tree with
/// deterministic content (derived from a seed and each file's path) that covers
/// the cases a copy/move must survive. Everything is created with POSIX calls,
/// independently of the app's VFS code, so names reach the disk byte-exactly.
///
/// Build it only inside a test-owned temporary directory.
struct FixtureTree {
    struct Options {
        var seed: UInt64 = 0x0771_7E57
        /// Chunk size the boundary files are built around; pass the chunk size
        /// the code under test uses.
        var chunkSize = SettingsService.defaultChunkSizeBytes
        /// Size of `large.bin`. Default: 64 MiB, or the value of the
        /// `OTTERTWIN_FIXTURE_LARGE_FILE_BYTES` environment variable.
        var largeFileSize = FixtureTree.defaultLargeFileSize
        /// Symlinks (to file, to dir, dangling, loop). Off for operations that
        /// would fail on them for reasons a test does not want to measure.
        var includeSymlinks = true
    }

    static var defaultLargeFileSize: Int {
        if let value = ProcessInfo.processInfo.environment["OTTERTWIN_FIXTURE_LARGE_FILE_BYTES"],
           let bytes = Int(value), bytes >= 0 {
            return bytes
        }
        return 64 << 20
    }

    /// Relative paths of the well-known entries.
    enum Path {
        static let deepDirectory = "a/b/c/d/e"
        static let deepFile = "a/b/c/d/e/deep.txt"
        static let emptyDirectory = "empty_dir"
        static let nestedEmptyDirectory = "a/b/empty_nested"
        static let emptyFile = "empty.txt"
        static let chunkMinusOne = "chunk_minus_1.bin"
        static let chunkExact = "chunk_exact.bin"
        static let chunkPlusOne = "chunk_plus_1.bin"
        static let multiChunk = "multi_chunk.bin"
        static let large = "large.bin"
        static let dotfile = ".dotfile"
        static let hiddenDirectory = ".hidden_dir"
        static let hiddenDirectoryFile = ".hidden_dir/inside.txt"
        static let hiddenInHiddenDirectory = ".hidden_dir/.nested_hidden"
        /// "café.txt" with é as U+00E9 (NFC) …
        static let nfcName = "unicode/nfc/caf\u{00E9}.txt"
        /// … and as "e" + U+0301 (NFD). Kept in separate folders because APFS
        /// treats both spellings as the same name inside one directory.
        static let nfdName = "unicode/nfd/cafe\u{0301}.txt"
        static let spaces = "name with spaces.txt"
        static let emoji = "emoji \u{1F9A6}.txt"
        /// 255 bytes, the APFS name limit.
        static let longName = String(repeating: "n", count: 251) + ".txt"
        static let symlinkToFile = "links/to_file"
        static let symlinkToDirectory = "links/to_dir"
        static let danglingSymlink = "links/dangling"
        static let loopA = "links/loop_a"
        static let loopB = "links/loop_b"
        static let readOnly = "readonly.txt"
        static let xattrFile = "xattr.txt"
        static let mtimeFile = "mtime.txt"
    }

    static let xattrName = "com.ottertwin.harness"
    /// 2001-02-03 04:05:06.5 UTC.
    static let customMtime = timespec(tv_sec: 981_173_106, tv_nsec: 500_000_000)
    static let symlinkTargets: [String: String] = [
        Path.symlinkToFile: "../a/b/c/d/e/deep.txt",
        Path.symlinkToDirectory: "../a",
        Path.danglingSymlink: "../does-not-exist",
        Path.loopA: "loop_b",
        Path.loopB: "loop_a",
    ]

    let root: URL
    let options: Options

    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Sizes of every regular file the builder creates.
    var fileSizes: [String: Int] {
        let chunk = options.chunkSize
        return [
            Path.deepFile: 1_000,
            Path.emptyFile: 0,
            Path.chunkMinusOne: chunk - 1,
            Path.chunkExact: chunk,
            Path.chunkPlusOne: chunk + 1,
            Path.multiChunk: 3 * chunk + 17,
            Path.large: options.largeFileSize,
            Path.dotfile: 64,
            Path.hiddenDirectoryFile: 300,
            Path.hiddenInHiddenDirectory: 10,
            Path.nfcName: 50,
            Path.nfdName: 51,
            Path.spaces: 70,
            Path.emoji: 80,
            Path.longName: 90,
            Path.readOnly: 120,
            Path.xattrFile: 130,
            Path.mtimeFile: 140,
        ]
    }

    var directories: [String] {
        var result = ["a", "a/b", "a/b/c", "a/b/c/d", Path.deepDirectory,
                      Path.emptyDirectory, Path.nestedEmptyDirectory,
                      Path.hiddenDirectory, "unicode", "unicode/nfc", "unicode/nfd"]
        if options.includeSymlinks { result.append("links") }
        return result
    }

    /// Creates the tree at `root`, which must not exist yet.
    @discardableResult
    static func build(at root: URL, options: Options = Options()) throws -> FixtureTree {
        precondition(options.chunkSize > 1, "chunk size must be > 1")
        let tree = FixtureTree(root: root, options: options)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HarnessPOSIX.makeDirectory(root.path)
        for directory in tree.directories {
            try HarnessPOSIX.makeDirectory(tree.path(directory))
        }
        for (relativePath, size) in tree.fileSizes.sorted(by: { $0.key < $1.key }) {
            try writeContent(at: tree.path(relativePath), relativePath: relativePath, size: size, seed: options.seed)
        }
        if options.includeSymlinks {
            for (link, target) in symlinkTargets.sorted(by: { $0.key < $1.key }) {
                try HarnessPOSIX.symlink(target, at: tree.path(link))
            }
        }
        try HarnessPOSIX.setXattr(tree.path(Path.xattrFile), name: xattrName,
                                  value: content(for: Path.xattrFile + "#xattr", size: 32, seed: options.seed))
        try HarnessPOSIX.setMtime(tree.path(Path.mtimeFile), customMtime)
        try HarnessPOSIX.chmod(tree.path(Path.readOnly), 0o444)
        return tree
    }

    /// Absolute path string; built by string concatenation so the relative
    /// part keeps its exact bytes.
    func path(_ relativePath: String) -> String {
        root.path + "/" + relativePath
    }

    // MARK: - Deterministic content

    /// The exact bytes the builder writes for `relativePath`.
    static func content(for relativePath: String, size: Int, seed: UInt64) -> Data {
        var generator = ContentGenerator(seed: seed, relativePath: relativePath)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { generator.fill($0, count: size) }
        return data
    }

    static func writeContent(at path: String, relativePath: String, size: Int, seed: UInt64) throws {
        var generator = ContentGenerator(seed: seed, relativePath: relativePath)
        try HarnessPOSIX.writeFile(path, size: size) { buffer, count in
            generator.fill(buffer, count: count)
        }
    }

    /// SplitMix64 stream keyed by (seed, FNV-1a of the path's UTF-8 bytes).
    struct ContentGenerator {
        private var state: UInt64

        init(seed: UInt64, relativePath: String) {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in relativePath.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            state = seed ^ hash
        }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Fills the first `count` bytes of `buffer` with the next bytes of the stream.
        /// Consecutive calls continue the stream only when `count` is a multiple of 8
        /// (the builder's 1 MiB blocks are).
        mutating func fill(_ buffer: UnsafeMutableRawBufferPointer, count: Int) {
            var offset = 0
            while offset + 8 <= count {
                buffer.storeBytes(of: next().littleEndian, toByteOffset: offset, as: UInt64.self)
                offset += 8
            }
            if offset < count {
                var tail = next().littleEndian
                withUnsafeBytes(of: &tail) { bytes in
                    for i in 0..<(count - offset) { buffer[offset + i] = bytes[i] }
                }
            }
        }
    }
}
