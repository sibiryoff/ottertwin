import Foundation

/// The check `OtterTwinUITestCase` runs before every UI-test launch (#59): the
/// app's start folder (`OTTERTWIN_UITEST_START_DIR`) must be the test's own
/// disposable temp folder or a folder inside it, and never the home folder.
/// This file is compiled into the app and the UI-test target (see `project.yml`)
/// so the unit tests can cover the decision; the app itself never calls it.
///
/// The XCUITest runner is sandboxed, so inside it `NSHomeDirectory()` and
/// `homeDirectoryForCurrentUser` return the runner's container, not the real
/// home folder the (unsandboxed) app would open. `realHomeDirectory()` asks the
/// user database instead.
enum UITestStartDirectoryGuard {
    /// True only when `startPath` is `disposableRoot` or inside it, and neither
    /// of them is `home` or a parent of `home`. Paths are compared component by
    /// component after resolving symlinks (`/var` vs `/private/var`), so
    /// `/tmp/abc` is not inside `/tmp/ab`. Empty or relative paths and paths with
    /// `.` or `..` components are refused.
    static func isAllowed(startPath: String, disposableRoot: String, home: String) -> Bool {
        guard let start = canonicalComponents(startPath),
              let root = canonicalComponents(disposableRoot),
              let home = canonicalComponents(home) else { return false }
        // Case-insensitive, so a case variant of the home folder is refused too.
        if isSameOrInside(home, start, caseSensitive: false)
            || isSameOrInside(home, root, caseSensitive: false) {
            return false
        }
        return isSameOrInside(start, root, caseSensitive: true)
    }

    /// The current user's real home folder from the user database, which the
    /// runner's sandbox does not redirect. Nil if it cannot be looked up.
    static func realHomeDirectory() -> String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        let path = String(cString: dir)
        return path.isEmpty ? nil : path
    }

    /// Whether `path` equals `ancestor` or lies below it.
    private static func isSameOrInside(_ path: [String], _ ancestor: [String], caseSensitive: Bool) -> Bool {
        guard path.count >= ancestor.count else { return false }
        return zip(path, ancestor).allSatisfy { lhs, rhs in
            caseSensitive ? lhs == rhs : lhs.lowercased() == rhs.lowercased()
        }
    }

    /// The path's components with symlinks resolved: the longest existing
    /// leading part goes through `realpath(3)`, the not-yet-existing rest is
    /// appended as given. Nil for empty or relative paths, or `.`/`..` components.
    static func canonicalComponents(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        for existing in stride(from: components.count, through: 0, by: -1) {
            let prefix = "/" + components.prefix(existing).joined(separator: "/")
            guard let resolved = realpath(prefix, nil) else { continue }
            defer { free(resolved) }
            let resolvedComponents = String(cString: resolved).split(separator: "/").map(String.init)
            return resolvedComponents + components.dropFirst(existing)
        }
        return nil
    }
}
