import Foundation
import Darwin
import XCTest

/// Data-safety harness (#24): a small disk image the test creates itself with
/// `hdiutil`, attached under the test's own temp directory (never a pre-existing
/// `/Volumes/*` volume), for cross-volume and non-APFS tests.
///
/// Create it with `XCTestCase.makeScratchVolume(_:)`, which detaches it and
/// deletes the image in the test's teardown, whatever the test's outcome.
final class ScratchVolume {
    enum FileSystem: String, CaseIterable {
        case apfs = "APFS"
        case exfat = "ExFAT"
        case fat32 = "MS-DOS FAT32"

        /// `f_fstypename` reported by `statfs` once mounted.
        var statfsTypeName: String {
            switch self {
            case .apfs: return "apfs"
            case .exfat: return "exfat"
            case .fat32: return "msdos"
            }
        }
    }

    static let hdiutil = "/usr/bin/hdiutil"
    /// FAT needs an upper-case name of at most 11 characters.
    static let volumeName = "OTSCRATCH"

    let fileSystem: FileSystem
    /// Folder that holds the image and the mount root; deleted on `destroy()`.
    let workDirectory: URL
    let imageURL: URL
    /// Where the volume is mounted (inside `workDirectory`).
    let mountPoint: URL
    private let deviceEntry: String
    private(set) var isAttached = true

    private init(fileSystem: FileSystem, workDirectory: URL, imageURL: URL, mountPoint: URL, deviceEntry: String) {
        self.fileSystem = fileSystem
        self.workDirectory = workDirectory
        self.imageURL = imageURL
        self.mountPoint = mountPoint
        self.deviceEntry = deviceEntry
    }

    /// Creates and attaches a fresh image. Throws `XCTSkip` when `hdiutil` is unavailable.
    static func create(_ fileSystem: FileSystem, sizeMB: Int = 64) throws -> ScratchVolume {
        guard FileManager.default.isExecutableFile(atPath: hdiutil) else {
            throw XCTSkip("hdiutil is not available; ScratchVolume needs macOS disk images")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScratchVolume-\(UUID().uuidString)", isDirectory: true)
        let mountRoot = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let image = work.appendingPathComponent("scratch.dmg")
        do {
            try run(["create", "-size", "\(sizeMB)m", "-fs", fileSystem.rawValue,
                     "-volname", volumeName, "-type", "UDIF", image.path])
            let output = try run(["attach", "-plist", "-nobrowse", "-noautoopen", "-noverify",
                                  "-mountroot", mountRoot.path, image.path])
            let (device, mount) = try parseAttach(output)
            return ScratchVolume(fileSystem: fileSystem, workDirectory: work, imageURL: image,
                                 mountPoint: URL(fileURLWithPath: mount, isDirectory: true), deviceEntry: device)
        } catch {
            // Never leave a half-made image attached: if attach succeeded but its
            // output was unusable, find the image in `hdiutil info` and detach it.
            // Only then delete the work folder; if detaching failed, a mount may
            // still live inside it, so it is left alone. The original error is
            // rethrown either way.
            if (try? detachAll(attachedFrom: image)) != nil {
                try? FileManager.default.removeItem(at: work)  // nothing is mounted in it any more
            }
            throw error
        }
    }

    /// Detaches the image. Idempotent.
    func detach() throws {
        guard isAttached else { return }
        do {
            try Self.run(["detach", deviceEntry])
        } catch {
            try Self.run(["detach", deviceEntry, "-force"])
        }
        isAttached = false
    }

    /// Detaches (if needed) and deletes the image and its folder.
    func destroy() throws {
        try detach()
        if FileManager.default.fileExists(atPath: workDirectory.path) {
            try FileManager.default.removeItem(at: workDirectory)
        }
    }

    /// `f_fstypename` of whatever is mounted at `url` (e.g. "apfs", "exfat", "msdos").
    static func fileSystemTypeName(at url: URL) throws -> String {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw HarnessError.posix("statfs", url.path) }
        return withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// `st_dev` of `url`, to tell volumes apart.
    static func deviceID(of url: URL) throws -> dev_t {
        try HarnessPOSIX.lstat(url.path).st_dev
    }

    // MARK: - hdiutil

    @discardableResult
    private static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hdiutil)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        // stderr goes to a file, so neither pipe can fill up and block hdiutil.
        let errorLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdiutil-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: errorLog.path, contents: nil) else {
            throw HarnessError(description: "cannot create \(errorLog.path)")
        }
        defer { try? FileManager.default.removeItem(at: errorLog) }  // log of a finished command; nothing to keep
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        defer { try? errorHandle.close() }  // see above
        process.standardError = errorHandle
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorData = (try? Data(contentsOf: errorLog)) ?? Data()  // only used in the error message
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HarnessError(description: "hdiutil \(arguments.first ?? "") failed (\(process.terminationStatus)): \(message)")
        }
        return output
    }

    /// Detaches every device `hdiutil info` lists for the image at `image`.
    private static func detachAll(attachedFrom image: URL) throws {
        let output = try run(["info", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return }
        let wanted = image.resolvingSymlinksInPath().path
        for entry in images {
            guard let path = entry["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted,
                  let entities = entry["system-entities"] as? [[String: Any]],
                  let device = entities.compactMap({ $0["dev-entry"] as? String })
                    .first(where: { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil })
            else { continue }
            try run(["detach", device, "-force"])
        }
    }

    private static func parseAttach(_ output: Data) throws -> (device: String, mountPoint: String) {
        guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw HarnessError(description: "hdiutil attach: unexpected output")
        }
        let devices = entities.compactMap { $0["dev-entry"] as? String }
        guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first,
              // The image's whole-disk entry (e.g. /dev/disk4, listed first) detaches it
              // with all its partitions and, for APFS, its synthesized container.
              let device = devices.first(where: { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil }) else {
            throw HarnessError(description: "hdiutil attach: no mount point in output")
        }
        return (device, mount)
    }
}

extension XCTestCase {
    /// Creates a `ScratchVolume` that is always detached and deleted in this
    /// test's teardown (a failing detach fails the test).
    func makeScratchVolume(_ fileSystem: ScratchVolume.FileSystem, sizeMB: Int = 64) throws -> ScratchVolume {
        let volume = try ScratchVolume.create(fileSystem, sizeMB: sizeMB)
        addTeardownBlock {
            try volume.destroy()
        }
        return volume
    }
}
