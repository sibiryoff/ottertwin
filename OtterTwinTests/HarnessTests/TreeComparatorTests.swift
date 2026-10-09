import XCTest
import Darwin

/// #24: `TreeComparator` detects every kind of difference, one test per kind,
/// and each check can be switched off.
final class TreeComparatorTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var expected: URL!
    private var actual: URL!

    private static let fixedTime = timespec(tv_sec: 1_000_000_000, tv_nsec: 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("TreeComparatorTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        expected = tempDir.appendingPathComponent("expected", isDirectory: true)
        actual = tempDir.appendingPathComponent("actual", isDirectory: true)
        try makeBaseTree(at: expected)
        try makeBaseTree(at: actual)
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func p(_ root: URL, _ relativePath: String) -> String {
        root.path + "/" + relativePath
    }

    /// A small tree whose every entry has a fixed mtime, so two copies are identical.
    private func makeBaseTree(at root: URL) throws {
        try HarnessPOSIX.makeDirectory(root.path)
        try HarnessPOSIX.makeDirectory(p(root, "dir"))
        try HarnessPOSIX.makeDirectory(p(root, "dir/deeper"))
        try HarnessPOSIX.writeFile(p(root, "file.txt"), data: Data("hello world".utf8))
        try HarnessPOSIX.writeFile(p(root, "dir/deeper/nested.bin"), data: Data([1, 2, 3, 4, 5]))
        try HarnessPOSIX.writeFile(p(root, ".hidden"), data: Data("secret".utf8))
        try HarnessPOSIX.symlink("file.txt", at: p(root, "link"))
        try HarnessPOSIX.setXattr(p(root, "file.txt"), name: "com.ottertwin.test", value: Data("v1".utf8))
        try resetMtimes(root)
    }

    /// Re-applies the fixed mtime to every entry (mutating a tree changes its folders' mtimes).
    private func resetMtimes(_ root: URL) throws {
        for key in try TreeSnapshot.capture(root, hashContents: false).entries.keys {
            let relative = String(decoding: key, as: UTF8.self)
            try HarnessPOSIX.setMtime(relative == "." ? root.path : p(root, relative), Self.fixedTime)
        }
    }

    private func differences(_ comparator: TreeComparator = TreeComparator()) throws -> [TreeDifference] {
        try comparator.compare(expected: expected, actual: actual)
    }

    private func assertOnly(
        _ kind: TreeDifference.Kind, at path: String, _ comparator: TreeComparator = TreeComparator(),
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let found = try differences(comparator)
        XCTAssertEqual(found.map(\.kind), [kind], "\(found)", file: file, line: line)
        XCTAssertEqual(found.map(\.path), [path], file: file, line: line)
    }

    // MARK: - Identical

    func testIdenticalTreesHaveNoDifferences() throws {
        XCTAssertEqual(try differences(), [])
    }

    func testIdenticalSingleFilesHaveNoDifferences() throws {
        let comparator = TreeComparator()
        XCTAssertEqual(try comparator.compare(expected: expected.appendingPathComponent("file.txt"),
                                              actual: actual.appendingPathComponent("file.txt")), [])
    }

    // MARK: - One test per difference kind

    func testMissingEntry() throws {
        try fm.removeItem(atPath: p(actual, "dir/deeper/nested.bin"))
        try resetMtimes(actual)
        try assertOnly(.missing, at: "dir/deeper/nested.bin")
    }

    func testMissingHiddenEntry() throws {
        try fm.removeItem(atPath: p(actual, ".hidden"))
        try resetMtimes(actual)
        try assertOnly(.missing, at: ".hidden")
    }

    func testExtraEntry() throws {
        try HarnessPOSIX.writeFile(p(actual, "dir/new.txt"), data: Data())
        try resetMtimes(actual)
        try assertOnly(.extra, at: "dir/new.txt")
    }

    func testExtraHiddenEntry() throws {
        try HarnessPOSIX.writeFile(p(actual, "dir/.DS_Store"), data: Data())
        try resetMtimes(actual)
        try assertOnly(.extra, at: "dir/.DS_Store")
    }

    func testTypeDifference() throws {
        try fm.removeItem(atPath: p(actual, "file.txt"))
        try HarnessPOSIX.makeDirectory(p(actual, "file.txt"))
        try resetMtimes(actual)
        try assertOnly(.type, at: "file.txt")
    }

    func testSymlinkReplacedByItsTargetIsATypeDifference() throws {
        try fm.removeItem(atPath: p(actual, "link"))
        try HarnessPOSIX.writeFile(p(actual, "link"), data: Data("hello world".utf8))
        try resetMtimes(actual)
        try assertOnly(.type, at: "link")
    }

    func testSizeDifference() throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: p(actual, "file.txt")))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("!".utf8))
        try handle.close()
        try resetMtimes(actual)
        try assertOnly(.size, at: "file.txt", TreeComparator(checks: [.presence, .type, .size]))
        XCTAssertEqual(Set(try differences().map(\.kind)), [.size, .content])
    }

    func testContentDifferenceWithSameSize() throws {
        try fm.removeItem(atPath: p(actual, "dir/deeper/nested.bin"))
        try HarnessPOSIX.writeFile(p(actual, "dir/deeper/nested.bin"), data: Data([1, 2, 3, 4, 6]))
        try resetMtimes(actual)
        try assertOnly(.content, at: "dir/deeper/nested.bin")
    }

    func testSymlinkTargetDifference() throws {
        try fm.removeItem(atPath: p(actual, "link"))
        try HarnessPOSIX.symlink("dir", at: p(actual, "link"))
        try resetMtimes(actual)
        try assertOnly(.symlinkTarget, at: "link")
    }

    func testMtimeDifferenceAndTolerance() throws {
        try HarnessPOSIX.setMtime(p(actual, "file.txt"), timespec(tv_sec: Self.fixedTime.tv_sec + 2, tv_nsec: 0))
        try assertOnly(.mtime, at: "file.txt")
        try assertOnly(.mtime, at: "file.txt", TreeComparator(mtimeTolerance: 1.5))
        XCTAssertEqual(try differences(TreeComparator(mtimeTolerance: 2)), [])

        // Sub-second differences count too.
        try HarnessPOSIX.setMtime(p(actual, "file.txt"), timespec(tv_sec: Self.fixedTime.tv_sec, tv_nsec: 1_000))
        try assertOnly(.mtime, at: "file.txt")
    }

    func testDirectoryMtimeDifference() throws {
        try HarnessPOSIX.setMtime(p(actual, "dir"), timespec(tv_sec: Self.fixedTime.tv_sec + 60, tv_nsec: 0))
        try assertOnly(.mtime, at: "dir")
    }

    func testPermissionsDifference() throws {
        try HarnessPOSIX.chmod(p(actual, "file.txt"), 0o600)
        try assertOnly(.permissions, at: "file.txt")
    }

    func testXattrValueDifference() throws {
        try HarnessPOSIX.setXattr(p(actual, "file.txt"), name: "com.ottertwin.test", value: Data("v2".utf8))
        try assertOnly(.xattrs, at: "file.txt")
    }

    func testMissingXattr() throws {
        XCTAssertEqual(removexattr(p(actual, "file.txt"), "com.ottertwin.test", XATTR_NOFOLLOW), 0)
        try assertOnly(.xattrs, at: "file.txt")
    }

    func testNFCAndNFDNamesAreDifferentEntries() throws {
        try HarnessPOSIX.writeFile(p(expected, "dir/caf\u{00E9}"), data: Data())
        try HarnessPOSIX.writeFile(p(actual, "dir/cafe\u{0301}"), data: Data())
        try resetMtimes(expected)
        try resetMtimes(actual)
        let found = try differences()
        XCTAssertEqual(Set(found.map(\.kind)), [.missing, .extra], "\(found)")
        XCTAssertEqual(found.count, 2)
    }

    // MARK: - Switches

    func testEveryCheckCanBeSwitchedOff() throws {
        try fm.removeItem(atPath: p(actual, "dir/deeper/nested.bin"))
        try HarnessPOSIX.writeFile(p(actual, "dir/deeper/nested.bin"), data: Data([9, 9, 9]))
        try HarnessPOSIX.writeFile(p(actual, "extra.txt"), data: Data())
        try fm.removeItem(atPath: p(actual, "link"))
        try HarnessPOSIX.symlink("elsewhere", at: p(actual, "link"))
        try HarnessPOSIX.chmod(p(actual, "file.txt"), 0o600)
        try HarnessPOSIX.setXattr(p(actual, "file.txt"), name: "com.ottertwin.test", value: Data("v2".utf8))
        try fm.removeItem(atPath: p(actual, ".hidden"))
        try HarnessPOSIX.makeDirectory(p(actual, ".hidden"))
        // mtimes now differ for several entries, too.

        let all = try differences()
        XCTAssertEqual(Set(all.map(\.kind)), Set(TreeDifference.Kind.allCases).subtracting([.missing]), "\(all)")
        XCTAssertEqual(try differences(TreeComparator(checks: [])), [])

        let singleChecks: [(TreeComparator.Checks, TreeDifference.Kind)] = [
            (.presence, .extra), (.type, .type), (.size, .size), (.content, .content),
            (.symlinkTarget, .symlinkTarget), (.mtime, .mtime), (.permissions, .permissions), (.xattrs, .xattrs),
        ]
        for (check, kind) in singleChecks {
            let found = try differences(TreeComparator(checks: check))
            XCTAssertFalse(found.isEmpty, "\(kind) not detected on its own")
            XCTAssertTrue(found.allSatisfy { $0.kind == kind }, "\(check.rawValue): \(found)")
            let without = try differences(TreeComparator(checks: TreeComparator.Checks.all.subtracting(check)))
            XCTAssertFalse(without.contains { $0.kind == kind }, "\(kind) reported although switched off")
        }
    }

    func testContentCheckWithoutHashesFailsLoudly() throws {
        let unhashed = try TreeSnapshot.capture(expected, hashContents: false)
        let hashed = try TreeSnapshot.capture(actual)
        XCTAssertThrowsError(try TreeComparator().compare(expected: unhashed, actual: hashed))
        XCTAssertThrowsError(try TreeComparator(checks: .content).compare(expected: hashed, actual: unhashed))
        XCTAssertEqual(try TreeComparator(checks: [.presence, .type, .size]).compare(expected: unhashed, actual: hashed), [])
    }

    func testExcludingSkipsPathsOnBothSides() throws {
        try fm.removeItem(atPath: p(actual, ".hidden"))
        try HarnessPOSIX.writeFile(p(actual, ".extra_hidden"), data: Data())
        try resetMtimes(actual)
        XCTAssertEqual(try differences().count, 2)
        XCTAssertEqual(try differences(TreeComparator(excluding: TreeComparator.isHidden)), [])
    }
}
