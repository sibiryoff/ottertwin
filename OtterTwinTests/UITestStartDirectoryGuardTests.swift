import XCTest
@testable import OtterTwin

/// #59: the UI-test start-folder guard accepts only the test's disposable temp
/// folder (or a folder inside it) and refuses the real home folder, which the
/// sandboxed XCUITest runner cannot get from `homeDirectoryForCurrentUser`.
///
/// Every folder here lives in a fresh temp folder that models the runner's
/// layout: a fake `home` holding a container whose `tmp` holds the disposable
/// `root`. The real home folder is never passed in or written to.
final class UITestStartDirectoryGuardTests: XCTestCase {
    private var base: URL!
    private var home: URL!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fm = FileManager.default
        base = fm.temporaryDirectory
            .appendingPathComponent("UITestStartDirectoryGuardTests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        root = home.appendingPathComponent(
            "Library/Containers/com.mas.ottertwinUITests.xctrunner/Data/tmp/OtterTwinUITests-\(UUID().uuidString)",
            isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base, FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
        base = nil
        try super.tearDownWithError()
    }

    private func allowed(_ start: String, root: String? = nil, home: String? = nil) -> Bool {
        UITestStartDirectoryGuard.isAllowed(startPath: start,
                                            disposableRoot: root ?? self.root.path,
                                            home: home ?? self.home.path)
    }

    private func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSymlink(_ name: String, in folder: URL, to target: URL) throws -> URL {
        let link = folder.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    // MARK: Accepted

    func testDisposableRootItselfIsAccepted() {
        XCTAssertTrue(allowed(root.path))
        XCTAssertTrue(allowed(root.path + "/"))
    }

    func testFolderInsideDisposableRootIsAccepted() {
        XCTAssertTrue(allowed(root.appendingPathComponent("sub").path))
        XCTAssertTrue(allowed(root.appendingPathComponent("not-created-yet/deeper").path))
    }

    func testFolderInsideRootReachedThroughASymlinkIsAccepted() throws {
        let link = try makeSymlink("link-to-root", in: base, to: root)
        XCTAssertTrue(allowed(link.appendingPathComponent("sub").path))
    }

    // MARK: Home folder refused

    func testHomeFolderIsRefused() {
        XCTAssertFalse(allowed(home.path))
    }

    func testHomeFolderWithTrailingSlashesIsRefused() {
        XCTAssertFalse(allowed(home.path + "/"))
        XCTAssertFalse(allowed(home.path + "//"))
    }

    func testHomeFolderThroughASymlinkIsRefused() throws {
        let link = try makeSymlink("link-to-home", in: base, to: home)
        XCTAssertFalse(allowed(link.path))
        // And the other way round: the home folder given as the symlink.
        XCTAssertFalse(allowed(home.path, home: link.path))
    }

    func testHomeFolderThroughPrivateVariantIsRefused() {
        // On macOS /tmp is a symlink to /private/tmp; nothing is created here.
        let name = "UITestStartDirectoryGuardTests-home-\(UUID().uuidString)"
        XCTAssertFalse(allowed("/tmp/\(name)", root: "/tmp/\(name)", home: "/private/tmp/\(name)"))
        XCTAssertFalse(allowed("/private/tmp/\(name)", root: "/private/tmp/\(name)", home: "/tmp/\(name)"))
    }

    func testHomeFolderInDifferentCaseIsRefused() {
        // Refused whether or not the volume is case-sensitive.
        let variant = base.appendingPathComponent("HOME").path
        XCTAssertFalse(allowed(variant, root: variant))
    }

    func testParentOfHomeFolderIsRefused() {
        XCTAssertFalse(allowed(base.path, root: base.path))
        XCTAssertFalse(allowed("/", root: "/"))
    }

    func testSymlinkInsideRootThatPointsToHomeIsRefused() throws {
        let escape = try makeSymlink("escape", in: root, to: home)
        XCTAssertFalse(allowed(escape.path))
    }

    func testRootThatIsTheHomeFolderRefusesEverything() throws {
        let inside = try makeDirectory(home.appendingPathComponent("Documents"))
        XCTAssertFalse(allowed(inside.path, root: home.path))
    }

    // MARK: Outside the disposable root refused

    func testFolderOutsideRootIsRefused() throws {
        let other = try makeDirectory(base.appendingPathComponent("other"))
        XCTAssertFalse(allowed(other.path))
        // The runner's shared temp folder (the root's parent) is not disposable.
        XCTAssertFalse(allowed(root.deletingLastPathComponent().path))
    }

    func testSiblingSharingTheRootsNamePrefixIsRefused() throws {
        let sibling = try makeDirectory(URL(fileURLWithPath: root.path + "-other", isDirectory: true))
        XCTAssertFalse(allowed(sibling.path))
        XCTAssertFalse(allowed(root.path + "x"))
    }

    func testSymlinkInsideRootThatPointsOutsideIsRefused() throws {
        let other = try makeDirectory(base.appendingPathComponent("other"))
        let escape = try makeSymlink("escape", in: root, to: other)
        XCTAssertFalse(allowed(escape.path))
    }

    func testDotDotComponentsAreRefused() {
        XCTAssertFalse(allowed(root.path + "/../" + root.lastPathComponent))
        XCTAssertFalse(allowed(root.path + "/sub/.."))
        XCTAssertFalse(allowed(root.path + "/./sub"))
    }

    func testEmptyAndRelativePathsAreRefused() {
        XCTAssertFalse(allowed(""))
        XCTAssertFalse(allowed("sub"))
        XCTAssertFalse(allowed("~/"))
        XCTAssertFalse(allowed(root.path, root: ""))
        XCTAssertFalse(allowed(root.path, home: ""))
    }

    // MARK: Real home lookup

    func testRealHomeDirectoryIsAnAbsolutePathOutsideAnyContainer() throws {
        let realHome = try XCTUnwrap(UITestStartDirectoryGuard.realHomeDirectory())
        XCTAssertTrue(realHome.hasPrefix("/"), realHome)
        XCTAssertFalse(realHome.contains("/Library/Containers/"), realHome)
        // Only compares paths; nothing in the home folder is listed or touched.
        XCTAssertFalse(UITestStartDirectoryGuard.isAllowed(startPath: realHome, disposableRoot: realHome, home: realHome))
    }
}
