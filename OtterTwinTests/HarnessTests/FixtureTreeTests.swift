import XCTest
import Darwin
@testable import OtterTwin

/// #24: `FixtureTree` builds every case it promises, deterministically.
final class FixtureTreeTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("FixtureTreeTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func smallOptions(seed: UInt64 = 1) -> FixtureTree.Options {
        var options = FixtureTree.Options()
        options.seed = seed
        options.chunkSize = 4096
        options.largeFileSize = 64 * 1024
        return options
    }

    func testDefaultLargeFileIs64MiBUnlessOverridden() {
        if ProcessInfo.processInfo.environment["OTTERTWIN_FIXTURE_LARGE_FILE_BYTES"] == nil {
            XCTAssertEqual(FixtureTree.Options().largeFileSize, 64 * 1024 * 1024)
        }
        XCTAssertEqual(FixtureTree.Options().chunkSize, SettingsService.defaultChunkSizeBytes)
    }

    func testBuildsEveryRequiredCase() throws {
        let tree = try FixtureTree.build(at: tempDir.appendingPathComponent("tree"), options: smallOptions())
        typealias P = FixtureTree.Path

        func st(_ relativePath: String) throws -> stat { try HarnessPOSIX.lstat(tree.path(relativePath)) }
        func isType(_ relativePath: String, _ type: mode_t) throws -> Bool {
            let mode = try HarnessPOSIX.lstat(tree.path(relativePath)).st_mode
            return mode & S_IFMT == type
        }

        // Nested directories, depth ≥ 5, and empty directories.
        XCTAssertGreaterThanOrEqual(P.deepDirectory.split(separator: "/").count, 5)
        XCTAssertTrue(try isType(P.deepDirectory, S_IFDIR))
        XCTAssertTrue(try isType(P.deepFile, S_IFREG))
        XCTAssertEqual(try HarnessPOSIX.directoryEntries(tree.path(P.emptyDirectory)), [])
        XCTAssertEqual(try HarnessPOSIX.directoryEntries(tree.path(P.nestedEmptyDirectory)), [])

        // Sizes: empty, chunk − 1 / chunk / chunk + 1, multi-chunk, large.
        let chunk = Int64(tree.options.chunkSize)
        XCTAssertEqual(try st(P.emptyFile).st_size, 0)
        XCTAssertEqual(try st(P.chunkMinusOne).st_size, chunk - 1)
        XCTAssertEqual(try st(P.chunkExact).st_size, chunk)
        XCTAssertEqual(try st(P.chunkPlusOne).st_size, chunk + 1)
        XCTAssertGreaterThanOrEqual(try st(P.multiChunk).st_size, 3 * chunk)
        XCTAssertEqual(try st(P.large).st_size, Int64(tree.options.largeFileSize))
        for (relativePath, size) in tree.fileSizes {
            let expected = FixtureTree.content(for: relativePath, size: size, seed: tree.options.seed)
            var actual = Data()
            try HarnessPOSIX.readFile(tree.path(relativePath)) { actual.append(contentsOf: $0) }
            XCTAssertEqual(actual, expected, "content of \(relativePath)")
        }

        // Hidden file and hidden directory.
        XCTAssertTrue(try isType(P.dotfile, S_IFREG))
        XCTAssertTrue(try isType(P.hiddenDirectory, S_IFDIR))
        XCTAssertTrue(try isType(P.hiddenDirectoryFile, S_IFREG))
        XCTAssertTrue(try isType(P.hiddenInHiddenDirectory, S_IFREG))

        // Unicode names stored byte-exactly in NFC and NFD form.
        let nfc = Array("caf\u{00E9}.txt".utf8)
        let nfd = Array("cafe\u{0301}.txt".utf8)
        XCTAssertNotEqual(nfc, nfd)
        XCTAssertEqual(try HarnessPOSIX.directoryEntries(tree.path("unicode/nfc")), [nfc])
        XCTAssertEqual(try HarnessPOSIX.directoryEntries(tree.path("unicode/nfd")), [nfd])

        // Spaces, emoji, 255-byte name.
        XCTAssertTrue(try isType(P.spaces, S_IFREG))
        XCTAssertTrue(try isType(P.emoji, S_IFREG))
        XCTAssertEqual(P.longName.utf8.count, 255)
        XCTAssertTrue(try isType(P.longName, S_IFREG))

        // Symlinks: to file, to dir, dangling, loop.
        for (link, target) in FixtureTree.symlinkTargets {
            XCTAssertTrue(try isType(link, S_IFLNK), link)
            XCTAssertEqual(try HarnessPOSIX.readLink(tree.path(link)), Array(target.utf8), link)
        }
        var followed = stat()
        XCTAssertEqual(stat(tree.path(P.symlinkToFile), &followed), 0)
        XCTAssertEqual(followed.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(stat(tree.path(P.symlinkToDirectory), &followed), 0)
        XCTAssertEqual(followed.st_mode & S_IFMT, S_IFDIR)
        let danglingResult = stat(tree.path(P.danglingSymlink), &followed)
        let danglingErrno = errno
        XCTAssertEqual(danglingResult, -1)
        XCTAssertEqual(danglingErrno, ENOENT)
        let loopResult = stat(tree.path(P.loopA), &followed)
        let loopErrno = errno
        XCTAssertEqual(loopResult, -1)
        XCTAssertEqual(loopErrno, ELOOP)

        // Read-only file, extended attribute, custom mtime.
        XCTAssertEqual(try st(P.readOnly).st_mode & 0o777, 0o444)
        XCTAssertEqual(try HarnessPOSIX.xattrs(tree.path(P.xattrFile))[FixtureTree.xattrName]?.count, 32)
        let mtime = try st(P.mtimeFile).st_mtimespec
        XCTAssertEqual(mtime.tv_sec, FixtureTree.customMtime.tv_sec)
        XCTAssertEqual(mtime.tv_nsec, FixtureTree.customMtime.tv_nsec)
    }

    func testWithoutSymlinksHasNoLinksFolder() throws {
        var options = smallOptions()
        options.includeSymlinks = false
        let tree = try FixtureTree.build(at: tempDir.appendingPathComponent("tree"), options: options)
        XCTAssertFalse(fm.fileExists(atPath: tree.path("links")))
    }

    func testSameSeedBuildsIdenticalTrees() throws {
        let a = try FixtureTree.build(at: tempDir.appendingPathComponent("a"), options: smallOptions(seed: 7))
        let b = try FixtureTree.build(at: tempDir.appendingPathComponent("b"), options: smallOptions(seed: 7))
        // Everything but mtimes (directories and plain files get "now").
        let comparator = TreeComparator(checks: [.data, .permissions, .xattrs])
        assertNoDifferences(try comparator.compare(expected: a.root, actual: b.root))
    }

    func testDifferentSeedChangesEveryNonEmptyFile() throws {
        let a = try FixtureTree.build(at: tempDir.appendingPathComponent("a"), options: smallOptions(seed: 7))
        let b = try FixtureTree.build(at: tempDir.appendingPathComponent("b"), options: smallOptions(seed: 8))
        let differences = try TreeComparator(checks: .data).compare(expected: a.root, actual: b.root)
        let changed = Set(differences.filter { $0.kind == .content }.map(\.path))
        let nonEmpty = Set(a.fileSizes.filter { $0.value > 0 }.map(\.key))
        XCTAssertEqual(changed.count, nonEmpty.count)
        XCTAssertEqual(differences.count, changed.count, "only content differs: \(differences)")
    }
}
