import Foundation
import Darwin
import CryptoKit
import XCTest

/// One difference between an expected and an actual tree.
struct TreeDifference: Equatable, CustomStringConvertible {
    enum Kind: String, CaseIterable {
        case missing, extra, type, size, content, symlinkTarget, mtime, permissions, xattrs
    }

    /// Path relative to the compared roots; "." is the root itself.
    let path: String
    let kind: Kind
    let detail: String

    var description: String { "\(kind.rawValue) at \(path): \(detail)" }
}

/// What the harness observed about one entry, read with POSIX calls only.
struct TreeEntry {
    enum EntryType: String { case directory, file, symlink, other }

    let type: EntryType
    let size: Int64
    /// SHA-256 of a regular file's bytes (own read loop + CryptoKit), if hashed.
    let sha256: String?
    let symlinkTarget: [UInt8]?
    let mtime: timespec
    /// Permission bits (`st_mode & 0o7777`).
    let permissions: mode_t
    let xattrs: [String: Data]
}

/// An independent record of a tree (or of a single file), keyed by the raw
/// UTF-8 bytes of each relative path, so NFC and NFD spellings stay distinct.
/// Symlinks are never followed, hidden entries are included.
struct TreeSnapshot {
    let root: URL
    let entries: [[UInt8]: TreeEntry]

    static func capture(_ root: URL, hashContents: Bool = true) throws -> TreeSnapshot {
        var entries: [[UInt8]: TreeEntry] = [:]
        try walk(absolute: Array(root.path.utf8), relative: [], hashContents: hashContents, into: &entries)
        return TreeSnapshot(root: root, entries: entries)
    }

    private static func walk(
        absolute: [UInt8], relative: [UInt8], hashContents: Bool,
        into entries: inout [[UInt8]: TreeEntry]
    ) throws {
        let path = String(decoding: absolute, as: UTF8.self)
        let st = try HarnessPOSIX.lstat(path)
        let type: TreeEntry.EntryType
        switch st.st_mode & S_IFMT {
        case S_IFDIR: type = .directory
        case S_IFREG: type = .file
        case S_IFLNK: type = .symlink
        default: type = .other
        }
        var hash: String?
        if type == .file, hashContents {
            var hasher = SHA256()
            try HarnessPOSIX.readFile(path) { hasher.update(bufferPointer: $0) }
            hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var linkTarget: [UInt8]?
        if type == .symlink { linkTarget = try HarnessPOSIX.readLink(path) }
        let xattrs = try HarnessPOSIX.xattrs(path)
        entries[relative.isEmpty ? Array(".".utf8) : relative] = TreeEntry(
            type: type,
            size: Int64(st.st_size),
            sha256: hash,
            symlinkTarget: linkTarget,
            mtime: st.st_mtimespec,
            permissions: st.st_mode & 0o7777,
            xattrs: xattrs
        )
        guard type == .directory else { return }
        for name in try HarnessPOSIX.directoryEntries(path) {
            try walk(
                absolute: absolute + [0x2F] + name,
                relative: relative.isEmpty ? name : relative + [0x2F] + name,
                hashContents: hashContents, into: &entries
            )
        }
    }
}

/// Data-safety harness (#24): compares two trees independently of the app's VFS
/// code (POSIX `lstat`/`readdir`/`readlink`/`getxattr`, own SHA-256). Every check
/// can be switched off, so a test asserts exactly what a feature guarantees.
struct TreeComparator {
    struct Checks: OptionSet {
        let rawValue: Int
        /// Missing and extra entries (hidden ones included).
        static let presence = Checks(rawValue: 1 << 0)
        static let type = Checks(rawValue: 1 << 1)
        static let size = Checks(rawValue: 1 << 2)
        static let content = Checks(rawValue: 1 << 3)
        static let symlinkTarget = Checks(rawValue: 1 << 4)
        static let mtime = Checks(rawValue: 1 << 5)
        static let permissions = Checks(rawValue: 1 << 6)
        static let xattrs = Checks(rawValue: 1 << 7)

        /// What a verified copy guarantees today: structure and bytes.
        static let data: Checks = [.presence, .type, .size, .content, .symlinkTarget]
        static let metadata: Checks = [.mtime, .permissions, .xattrs]
        static let all: Checks = [.data, .metadata]
    }

    var checks: Checks = .all
    /// Allowed |expected − actual| modification time difference, in seconds.
    var mtimeTolerance: TimeInterval = 0
    /// Extended attributes the OS may add on its own; ignored on both sides.
    var ignoredXattrs: Set<String> = ["com.apple.provenance"]
    /// Relative paths to leave out of the comparison entirely (both sides).
    var excluding: (String) -> Bool = { _ in false }

    init(checks: Checks = .all, mtimeTolerance: TimeInterval = 0, excluding: @escaping (String) -> Bool = { _ in false }) {
        self.checks = checks
        self.mtimeTolerance = mtimeTolerance
        self.excluding = excluding
    }

    /// True when any component of `relativePath` starts with a dot.
    static func isHidden(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." }
    }

    func compare(expected: URL, actual: URL) throws -> [TreeDifference] {
        let hash = checks.contains(.content)
        return compare(
            expected: try TreeSnapshot.capture(expected, hashContents: hash),
            actual: try TreeSnapshot.capture(actual, hashContents: hash)
        )
    }

    func compare(expected: TreeSnapshot, actual: TreeSnapshot) -> [TreeDifference] {
        var differences: [TreeDifference] = []
        let keys = Set(expected.entries.keys).union(actual.entries.keys)
            .sorted { $0.lexicographicallyPrecedes($1) }
        for key in keys {
            let path = String(decoding: key, as: UTF8.self)
            if excluding(path) { continue }
            func report(_ kind: TreeDifference.Kind, _ detail: String) {
                differences.append(TreeDifference(path: path, kind: kind, detail: detail))
            }
            guard let want = expected.entries[key] else {
                if checks.contains(.presence) { report(.extra, "not in expected tree") }
                continue
            }
            guard let have = actual.entries[key] else {
                if checks.contains(.presence) { report(.missing, "not in actual tree") }
                continue
            }
            if want.type != have.type {
                if checks.contains(.type) { report(.type, "expected \(want.type.rawValue), got \(have.type.rawValue)") }
                continue
            }
            if want.type == .file {
                if checks.contains(.size), want.size != have.size {
                    report(.size, "expected \(want.size) bytes, got \(have.size)")
                }
                if checks.contains(.content), want.sha256 != have.sha256 {
                    report(.content, "SHA-256 \(want.sha256 ?? "-") vs \(have.sha256 ?? "-")")
                }
            }
            if want.type == .symlink, checks.contains(.symlinkTarget), want.symlinkTarget != have.symlinkTarget {
                report(.symlinkTarget, "expected → \(Self.text(want.symlinkTarget)), got → \(Self.text(have.symlinkTarget))")
            }
            if checks.contains(.mtime) {
                let delta = abs(Self.seconds(want.mtime) - Self.seconds(have.mtime))
                if delta > mtimeTolerance {
                    report(.mtime, "differs by \(delta) s (tolerance \(mtimeTolerance) s)")
                }
            }
            if want.type != .symlink, checks.contains(.permissions), want.permissions != have.permissions {
                report(.permissions, "expected \(String(want.permissions, radix: 8)), got \(String(have.permissions, radix: 8))")
            }
            if checks.contains(.xattrs) {
                let wantX = want.xattrs.filter { !ignoredXattrs.contains($0.key) }
                let haveX = have.xattrs.filter { !ignoredXattrs.contains($0.key) }
                if wantX != haveX {
                    report(.xattrs, "expected \(wantX.keys.sorted()), got \(haveX.keys.sorted())\(Set(wantX.keys) == Set(haveX.keys) ? " (values differ)" : "")")
                }
            }
        }
        return differences
    }

    private static func seconds(_ time: timespec) -> Double {
        Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    private static func text(_ bytes: [UInt8]?) -> String {
        bytes.map { String(decoding: $0, as: UTF8.self) } ?? "-"
    }
}

extension XCTestCase {
    /// Records one failure listing every difference (none → passes).
    func assertNoDifferences(
        _ differences: [TreeDifference], _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !differences.isEmpty else { return }
        let listed = differences.prefix(50).map { "  \($0)" }.joined(separator: "\n")
        let more = differences.count > 50 ? "\n  … and \(differences.count - 50) more" : ""
        XCTFail("\(message.isEmpty ? "" : message + ": ")\(differences.count) tree difference(s):\n\(listed)\(more)",
                file: file, line: line)
    }

    /// Compares two trees and records one failure listing every difference.
    func assertTreesEqual(
        expected: URL, actual: URL, comparator: TreeComparator = TreeComparator(), _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            assertNoDifferences(try comparator.compare(expected: expected, actual: actual), message, file: file, line: line)
        } catch {
            XCTFail("Tree comparison failed: \(error)", file: file, line: line)
        }
    }

    /// Compares the tree at `actual` with an earlier snapshot; one failure lists every difference.
    func assertTree(
        _ actual: URL, matches expected: TreeSnapshot, comparator: TreeComparator = TreeComparator(), _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            let snapshot = try TreeSnapshot.capture(actual, hashContents: comparator.checks.contains(.content))
            assertNoDifferences(comparator.compare(expected: expected, actual: snapshot), message, file: file, line: line)
        } catch {
            XCTFail("Tree comparison failed: \(error)", file: file, line: line)
        }
    }
}
