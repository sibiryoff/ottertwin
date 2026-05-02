import XCTest
@testable import OtterTwin

final class FileItemTests: XCTestCase {
    private func makeFile(name: String = "test.txt", size: Int64 = 1024, isDirectory: Bool = false) -> FileItem {
        FileItem(
            id: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            size: size,
            modificationDate: Date(),
            isDirectory: isDirectory
        )
    }

    // MARK: - displaySize

    func testDisplaySizeForDirectory() {
        let item = makeFile(name: "folder", size: 4096, isDirectory: true)
        XCTAssertEqual(item.displaySize, "—")
    }

    func testDisplaySizeForZeroByteFile() {
        let item = makeFile(name: "empty.txt", size: 0)
        XCTAssertFalse(item.displaySize.isEmpty)
        XCTAssertNotEqual(item.displaySize, "—")
    }

    func testDisplaySizeForKilobyteFile() {
        let item = makeFile(name: "small.txt", size: 512)
        XCTAssertNotEqual(item.displaySize, "—")
        XCTAssertFalse(item.displaySize.isEmpty)
    }

    func testDisplaySizeForMegabyteFile() {
        let item = makeFile(name: "large.bin", size: 1_048_576)
        // ByteCountFormatter will render this as "1 MB" or "1 MiB" depending on locale
        XCTAssertNotEqual(item.displaySize, "—")
        XCTAssertTrue(item.displaySize.contains("1"))
    }

    func testDisplaySizeForGigabyteFile() {
        let item = makeFile(name: "huge.iso", size: 1_073_741_824)
        XCTAssertNotEqual(item.displaySize, "—")
        XCTAssertFalse(item.displaySize.isEmpty)
    }

    // MARK: - Identity / Equatable / Hashable

    func testEqualityByURL() {
        let url = URL(fileURLWithPath: "/tmp/file.txt")
        let date = Date()
        let a = FileItem(id: url, name: "file.txt", size: 100, modificationDate: date, isDirectory: false)
        let b = FileItem(id: url, name: "file.txt", size: 100, modificationDate: date, isDirectory: false)
        XCTAssertEqual(a, b)
    }

    func testInequalityForDifferentURLs() {
        let date = Date()
        let a = FileItem(id: URL(fileURLWithPath: "/tmp/a.txt"), name: "a.txt", size: 100, modificationDate: date, isDirectory: false)
        let b = FileItem(id: URL(fileURLWithPath: "/tmp/b.txt"), name: "b.txt", size: 100, modificationDate: date, isDirectory: false)
        XCTAssertNotEqual(a, b)
    }

    func testHashabilityInSet() {
        let url = URL(fileURLWithPath: "/tmp/file.txt")
        let date = Date()
        let a = FileItem(id: url, name: "file.txt", size: 100, modificationDate: date, isDirectory: false)
        let b = FileItem(id: url, name: "file.txt", size: 100, modificationDate: date, isDirectory: false)
        var set = Set<FileItem>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1, "Identical items should deduplicate in a Set")
    }

    func testDistinctItemsInSet() {
        let date = Date()
        let a = FileItem(id: URL(fileURLWithPath: "/tmp/a.txt"), name: "a.txt", size: 100, modificationDate: date, isDirectory: false)
        let b = FileItem(id: URL(fileURLWithPath: "/tmp/b.txt"), name: "b.txt", size: 200, modificationDate: date, isDirectory: false)
        let set = Set([a, b])
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - isDirectory

    func testIsDirectoryFalseForFile() {
        let item = makeFile(isDirectory: false)
        XCTAssertFalse(item.isDirectory)
    }

    func testIsDirectoryTrueForDirectory() {
        let item = makeFile(isDirectory: true)
        XCTAssertTrue(item.isDirectory)
    }
}
