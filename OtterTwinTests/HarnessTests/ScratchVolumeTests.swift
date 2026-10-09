import XCTest
import Darwin
@testable import OtterTwin

/// #24: `ScratchVolume` creates, writes and detaches APFS, ExFAT and FAT32
/// disk images that the test made itself.
final class ScratchVolumeTests: XCTestCase {
    func testAPFSVolume() throws {
        try exercise(.apfs)
    }

    func testExFATVolume() throws {
        try exercise(.exfat)
    }

    func testFAT32Volume() throws {
        try exercise(.fat32)
    }

    func testDetachIsIdempotent() throws {
        let volume = try makeScratchVolume(.apfs)
        try volume.detach()
        try volume.detach()
        XCTAssertFalse(volume.isAttached)
    }

    private func exercise(_ fileSystem: ScratchVolume.FileSystem, file: StaticString = #filePath, line: UInt = #line) throws {
        let volume = try makeScratchVolume(fileSystem)
        let temp = FileManager.default.temporaryDirectory

        // Mounted inside the test's own temp folder, never under /Volumes.
        XCTAssertTrue(volume.mountPoint.resolvingSymlinksInPath()
                        .isContained(in: volume.workDirectory.resolvingSymlinksInPath()),
                      "mounted at \(volume.mountPoint.path)", file: file, line: line)
        XCTAssertFalse(volume.mountPoint.path.hasPrefix("/Volumes/"), file: file, line: line)
        XCTAssertEqual(try ScratchVolume.fileSystemTypeName(at: volume.mountPoint), fileSystem.statfsTypeName,
                       file: file, line: line)
        XCTAssertNotEqual(try ScratchVolume.deviceID(of: volume.mountPoint), try ScratchVolume.deviceID(of: temp),
                          "a separate volume", file: file, line: line)

        // Write a multi-megabyte file and read it back through the harness.
        let data = FixtureTree.content(for: "scratch.bin", size: 3 << 20, seed: 9)
        let local = temp.appendingPathComponent("ScratchVolumeTests-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: local) }  // test cleanup only
        try data.write(to: local)
        let onVolume = volume.mountPoint.appendingPathComponent("scratch.bin")
        try HarnessPOSIX.writeFile(onVolume.path, data: data)
        assertNoDifferences(try TreeComparator(checks: [.type, .size, .content]).compare(expected: local, actual: onVolume),
                            file: file, line: line)

        // Detach: the mount point no longer is a separate volume.
        let mountedDevice = try ScratchVolume.deviceID(of: volume.mountPoint)
        try volume.detach()
        XCTAssertFalse(volume.isAttached, file: file, line: line)
        if FileManager.default.fileExists(atPath: volume.mountPoint.path) {
            XCTAssertNotEqual(try ScratchVolume.deviceID(of: volume.mountPoint), mountedDevice, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: onVolume.path), file: file, line: line)
    }
}
