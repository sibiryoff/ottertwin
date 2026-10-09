import Foundation
import Darwin
import OSLog

/// Atomic finalize (#27): puts a complete, already verified file in place
/// without ever destroying what is at the destination first.
///
/// - New destination (`moveExclusively`): `renamex_np(RENAME_EXCL)`. Never
///   replaces anything; an item that appeared meanwhile is reported as `EEXIST`.
/// - Replace (`replace`): `renamex_np(RENAME_SWAP)` exchanges the two names in
///   one step, then the swapped-out original is removed.
///
/// File systems without these flags (smbfs, ExFAT; on CI the macOS msdos/FAT32
/// driver does support `RENAME_SWAP`) report `ENOTSUP` or `EINVAL` and get a
/// fallback:
/// - exclusive: check, then rename. A short window remains between the check
///   and the rename; without kernel support (and without hard links, which
///   these file systems lack too) it cannot be closed.
/// - replace: rename the original aside to `.<name>.ottertwin-<uuid>.old`,
///   move the new file into place exclusively, then remove the original. If
///   moving the new file fails, the original is renamed back.
///
/// Either way the original is touched only here, i.e. only after the new data
/// was completely written and verified by the caller.
struct AtomicRename {
    private static let logger = Logger(subsystem: "OtterTwin", category: "AtomicRename")

    /// `renamex_np(from, to, flags)`; flags 0 is a plain `rename`. Returns 0 on
    /// success, otherwise the `errno`.
    ///
    /// Test hook (#27): the data-safety harness wraps it to simulate file
    /// systems without `RENAME_EXCL`/`RENAME_SWAP` and to inject failures
    /// between the fallback's steps. Production code always uses `.system`.
    var renamex: (_ from: String, _ to: String, _ flags: UInt32) -> Int32

    static let system = AtomicRename { from, to, flags in
        let result = flags == 0 ? Darwin.rename(from, to) : renamex_np(from, to, flags)
        return result == 0 ? 0 : errno
    }

    /// Moves `source` to `destination`, never replacing an existing item
    /// (`EEXIST` if there is one).
    func moveExclusively(from source: URL, to destination: URL) throws {
        let result = renamex(source.path, destination.path, UInt32(RENAME_EXCL))
        if result == 0 { return }
        guard Self.isUnsupported(result) else { throw Self.error(result) }
        // No RENAME_EXCL (smbfs, ExFAT, FAT): check, then rename; see the type's doc.
        if Self.exists(destination) { throw POSIXError(.EEXIST) }
        let fallback = renamex(source.path, destination.path, 0)
        guard fallback == 0 else { throw Self.error(fallback) }
    }

    /// Replaces the item at `destination` with `source` (same folder, same
    /// volume). `backup` is an unused, operation-unique name in the same folder
    /// that the fallback parks the original under; it never remains afterwards
    /// unless restoring the original failed (logged as a fault).
    ///
    /// If the original disappeared meanwhile, `source` is moved into place
    /// exclusively instead. On error the original is in place, unchanged, and
    /// `source` is still at its own name.
    ///
    /// `swapping`: use `RENAME_SWAP` when available. A swap leaves the original
    /// at `source`'s name until it is removed, which is fine for a hidden
    /// temporary file but not for a user-visible source (a same-volume move):
    /// if removing it failed, the old destination would sit at the source path
    /// of a move that reported success. Pass false there, so the original only
    /// ever waits under the hidden `backup` name.
    func replace(_ destination: URL, with source: URL, backup: URL, swapping: Bool = true) throws {
        if Self.isSameFile(source, destination) {
            // A name change of one file (e.g. only its case, on a case-insensitive
            // volume): there is nothing to replace, and removing the "original"
            // would remove the file itself.
            let result = renamex(source.path, destination.path, 0)
            guard result == 0 else { throw Self.error(result) }
            return
        }

        if swapping {
            let swapped = renamex(source.path, destination.path, UInt32(RENAME_SWAP))
            if swapped == 0 {
                // The new file is in place; the original now has `source`'s (hidden) name.
                removeReplacedOriginal(at: source)
                return
            }
            if swapped == ENOENT, !Self.exists(destination) {
                try moveExclusively(from: source, to: destination)
                return
            }
            guard Self.isUnsupported(swapped) else { throw Self.error(swapped) }
        }

        // Without RENAME_SWAP. 1: park the original under `backup`.
        do {
            try moveExclusively(from: destination, to: backup)
        } catch let error as POSIXError where error.code == .ENOENT && !Self.exists(destination) {
            try moveExclusively(from: source, to: destination)
            return
        }
        // 2: move the new file into place, never over an item that appeared
        // in the meantime. On failure, put the original back.
        do {
            try moveExclusively(from: source, to: destination)
        } catch {
            restoreOriginal(from: backup, to: destination)
            throw error
        }
        // 3: the new file is in place; remove the original.
        removeReplacedOriginal(at: backup)
    }

    // MARK: Helpers

    /// The replacement already succeeded, so a failed removal of the original is
    /// logged, not thrown: the operation's result (the verified new file in
    /// place) stands. The leftover is a hidden `.ottertwin-` file.
    private func removeReplacedOriginal(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.error("Could not remove the replaced original \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Called while an error is being thrown; that error is what gets reported.
    /// If the original cannot be put back, it is kept under its backup name and
    /// that is logged as a fault (never deleted).
    private func restoreOriginal(from backup: URL, to destination: URL) {
        do {
            try moveExclusively(from: backup, to: destination)
        } catch {
            Self.logger.fault("Could not restore the original to \(destination.lastPathComponent, privacy: .private); it is kept as \(backup.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
        }
    }

    static func isUnsupported(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL
    }

    private static func error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        var infoA = stat(), infoB = stat()
        guard lstat(a.path, &infoA) == 0, lstat(b.path, &infoB) == 0 else { return false }
        return infoA.st_dev == infoB.st_dev && infoA.st_ino == infoB.st_ino
    }
}
