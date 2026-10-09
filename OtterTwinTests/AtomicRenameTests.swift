import XCTest
import Darwin
@testable import OtterTwin

/// #27: `AtomicRename` never destroys the destination before the new file is
/// in its place, with the native rename flags and with the fallback for file
/// systems that lack them; failures between the fallback's steps restore the
/// original or, if even that fails, keep it under its hidden `.old` name.
final class AtomicRenameTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("AtomicRenameTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private let original = Data("original destination".utf8)
    private let replacement = Data("new, verified data".utf8)

    /// `destination` holding the original and `source` holding the replacement, in `folder`.
    private func makePair(in folder: URL? = nil) throws -> (destination: URL, source: URL, backup: URL) {
        let folder = folder ?? tempDir!
        let destination = folder.appendingPathComponent("file.bin")
        let source = folder.appendingPathComponent(".file.bin.ottertwin-\(UUID().uuidString).part")
        try HarnessPOSIX.writeFile(destination.path, data: original)
        try HarnessPOSIX.writeFile(source.path, data: replacement)
        return (destination, source, ChunkedWriter.backupURL(for: destination))
    }

    private func contents(of folder: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix("._") }.sorted()
    }

    private static let variants: [(String, AtomicRename)] = [
        ("native", .system),
        ("fallback", .withoutRenameFlags()),
    ]

    // MARK: - Replace

    func testReplacePutsTheNewFileInPlaceAndRemovesTheOriginal() throws {
        for (name, rename) in Self.variants {
            let folder = tempDir.appendingPathComponent(name, isDirectory: true)
            try HarnessPOSIX.makeDirectory(folder.path)
            let (destination, source, backup) = try makePair(in: folder)

            try rename.replace(destination, with: source, backup: backup)

            XCTAssertEqual(try Data(contentsOf: destination), replacement, name)
            XCTAssertEqual(try contents(of: folder), ["file.bin"], "\(name): no source, no .old left")
        }
    }

    func testFallbackRestoresTheOriginalWhenMovingTheNewFileInFails() throws {
        let (destination, source, backup) = try makePair()
        let rename = AtomicRename.withoutRenameFlags { from, _ in
            from.lastPathComponent == source.lastPathComponent ? EIO : nil
        }

        XCTAssertThrowsError(try rename.replace(destination, with: source, backup: backup)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original, "original restored")
        XCTAssertEqual(try Data(contentsOf: source), replacement, "the new file is left for the caller to discard")
        XCTAssertFalse(fm.fileExists(atPath: backup.path), "no .old left")
    }

    func testFallbackFailingToParkTheOriginalChangesNothing() throws {
        let (destination, source, backup) = try makePair()
        let rename = AtomicRename.withoutRenameFlags { _, to in
            to.lastPathComponent == backup.lastPathComponent ? EACCES : nil
        }

        XCTAssertThrowsError(try rename.replace(destination, with: source, backup: backup)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertFalse(fm.fileExists(atPath: backup.path))
    }

    /// Someone creates the destination right after the fallback parked the
    /// original: the new file never replaces theirs, and the original, which
    /// cannot go back, is kept under its `.old` name rather than deleted.
    func testFallbackNeverOverwritesAnItemThatAppearsAfterTheOriginalWasParked() throws {
        let (destination, source, backup) = try makePair()
        let theirs = Data("someone else's".utf8)
        let rename = AtomicRename { from, to, flags in
            if flags != 0 { return ENOTSUP }
            let result = AtomicRename.system.renamex(from, to, 0)
            if result == 0, to == backup.path {
                try? HarnessPOSIX.writeFile(destination.path, data: theirs)  // test setup; checked below
            }
            return result
        }

        XCTAssertThrowsError(try rename.replace(destination, with: source, backup: backup)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: destination), theirs, "never overwritten")
        XCTAssertEqual(try Data(contentsOf: backup), original, "the original is kept, not deleted")
        XCTAssertEqual(try Data(contentsOf: source), replacement)
    }

    func testReplaceWhenTheOriginalVanishedMovesTheNewFileIn() throws {
        for (name, rename) in Self.variants {
            let folder = tempDir.appendingPathComponent(name, isDirectory: true)
            try HarnessPOSIX.makeDirectory(folder.path)
            let (destination, source, backup) = try makePair(in: folder)
            try fm.removeItem(at: destination)

            try rename.replace(destination, with: source, backup: backup)

            XCTAssertEqual(try Data(contentsOf: destination), replacement, name)
            XCTAssertEqual(try contents(of: folder), ["file.bin"], name)
        }
    }

    /// A move that only changes the case of a name, on a case-insensitive
    /// volume: the "destination" is the source itself and must survive.
    func testReplacingAFileWithItselfKeepsIt() throws {
        for (name, rename) in Self.variants {
            let folder = tempDir.appendingPathComponent(name, isDirectory: true)
            try HarnessPOSIX.makeDirectory(folder.path)
            let file = folder.appendingPathComponent("file.bin")
            try HarnessPOSIX.writeFile(file.path, data: original)

            try rename.replace(file, with: file, backup: ChunkedWriter.backupURL(for: file))

            XCTAssertEqual(try Data(contentsOf: file), original, name)
            XCTAssertEqual(try contents(of: folder), ["file.bin"], name)
        }
    }

    // MARK: - Same-volume move replace

    /// A move never leaves the old destination at the (user-visible) source
    /// path, even when the old destination cannot be fully removed: it is parked
    /// under a hidden `.old` name next to the destination instead.
    func testMoveReplaceNeverLeavesTheOldDestinationAtTheSourcePath() async throws {
        let folder = tempDir.appendingPathComponent("dst", isDirectory: true)
        let destination = folder.appendingPathComponent("target")
        let locked = destination.appendingPathComponent("locked")
        try HarnessPOSIX.makeDirectory(folder.path)
        try HarnessPOSIX.makeDirectory(destination.path)
        try HarnessPOSIX.makeDirectory(locked.path)
        try HarnessPOSIX.writeFile(locked.appendingPathComponent("f").path, data: original)
        try HarnessPOSIX.chmod(locked.path, 0o500)  // its file cannot be removed
        defer { unlockLeftovers(in: folder) }
        let source = tempDir.appendingPathComponent("moved.bin")
        try HarnessPOSIX.writeFile(source.path, data: replacement)

        try await LocalProvider().replaceItem(at: destination, withItemAt: source)

        XCTAssertFalse(fm.fileExists(atPath: source.path), "nothing at the source path")
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        let leftovers = try contents(of: folder).filter { $0 != "target" }
        XCTAssertEqual(leftovers.count, 1, "\(leftovers)")
        XCTAssertTrue(leftovers.allSatisfy(ChunkedWriter.isTemporaryFileName), "only a hidden .old leftover: \(leftovers)")
    }

    /// Makes leftovers of the test above removable by `tearDown`.
    private func unlockLeftovers(in folder: URL) {
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }  // nothing to unlock
        for name in names {
            let locked = folder.appendingPathComponent(name).appendingPathComponent("locked")
            if fm.fileExists(atPath: locked.path) {
                try? HarnessPOSIX.chmod(locked.path, 0o700)  // best effort; tearDown reports anything left
            }
        }
    }

    func testMoveReplaceUsesNoSwap() async throws {
        let (destination, source, _) = try makePair()
        let provider = FaultInjectingProvider(fakeTrash: tempDir.appendingPathComponent("FakeTrash", isDirectory: true))
        let flags = FlagLog()
        provider.rename = AtomicRename { from, to, flag in
            flags.append(flag)
            return AtomicRename.system.renamex(from, to, flag)
        }

        try await provider.replaceItem(at: destination, withItemAt: source)

        XCTAssertFalse(flags.values.contains(UInt32(RENAME_SWAP)), "\(flags.values)")
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertEqual(try contents(of: tempDir), ["file.bin"])
    }

    final class FlagLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [UInt32] = []
        var values: [UInt32] { lock.withLock { _values } }
        func append(_ value: UInt32) { lock.withLock { _values.append(value) } }
    }

    // MARK: - Exclusive move

    func testMoveExclusivelyNeverReplaces() throws {
        for (name, rename) in Self.variants {
            let folder = tempDir.appendingPathComponent(name, isDirectory: true)
            try HarnessPOSIX.makeDirectory(folder.path)
            let (destination, source, _) = try makePair(in: folder)

            XCTAssertThrowsError(try rename.moveExclusively(from: source, to: destination), name) { error in
                XCTAssertEqual((error as? POSIXError)?.code, .EEXIST, name)
            }
            XCTAssertEqual(try Data(contentsOf: destination), original, name)

            try fm.removeItem(at: destination)
            try rename.moveExclusively(from: source, to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), replacement, name)
        }
    }

    // MARK: - Real non-APFS file systems

    /// ExFAT has no `RENAME_SWAP`, so `AtomicFinalizeTests` on ExFAT exercise
    /// the real fallback.
    func testExFATHasNoRenameSwap() throws {
        let volume = try makeScratchVolume(.exfat)
        let (destination, source, _) = try makePair(in: volume.mountPoint)

        let swap = renamex_np(source.path, destination.path, UInt32(RENAME_SWAP))
        let code = errno

        XCTAssertNotEqual(swap, 0, "ExFAT unexpectedly supports RENAME_SWAP")
        if swap != 0 {
            XCTAssertTrue(AtomicRename.isUnsupported(code), "errno \(code)")
        }
        XCTAssertEqual(try Data(contentsOf: destination), original, "a failed swap changes nothing")
    }

    /// Replacing works on ExFAT (fallback) and FAT32 (whose msdos driver does
    /// support `RENAME_SWAP`).
    func testReplaceWorksOnExFATAndFAT32() throws {
        for fileSystem in [ScratchVolume.FileSystem.exfat, .fat32] {
            let volume = try makeScratchVolume(fileSystem)
            let (destination, source, backup) = try makePair(in: volume.mountPoint)

            try AtomicRename.system.replace(destination, with: source, backup: backup)

            XCTAssertEqual(try Data(contentsOf: destination), replacement, fileSystem.rawValue)
            XCTAssertFalse(fm.fileExists(atPath: source.path), fileSystem.rawValue)
            XCTAssertFalse(fm.fileExists(atPath: backup.path), fileSystem.rawValue)
        }
    }
}
