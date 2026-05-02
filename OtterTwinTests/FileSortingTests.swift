import XCTest
@testable import OtterTwin

// Directories always sort before files; within each group the chosen sort key applies.
final class FileSortingTests: XCTestCase {
    private let now = Date()

    private func item(name: String, size: Int64, offsetSeconds: TimeInterval = 0, isDir: Bool = false) -> FileItem {
        FileItem(
            id: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            size: size,
            modificationDate: now.addingTimeInterval(offsetSeconds),
            isDirectory: isDir
        )
    }

    // Mirror of FilePanelView.sortedItems
    private func sorted(_ items: [FileItem], by key: String, ascending: Bool) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch key {
            case "size":
                return ascending ? a.size < b.size : a.size > b.size
            case "date":
                return ascending ? a.modificationDate < b.modificationDate
                                 : a.modificationDate > b.modificationDate
            default:
                let cmp = a.name.localizedStandardCompare(b.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
    }

    private func makeFixture() -> [FileItem] {
        [
            item(name: "z.txt",  size: 300, offsetSeconds: -100),
            item(name: "a",      size: 100, offsetSeconds:  -50, isDir: true),
            item(name: "m.txt",  size: 200, offsetSeconds:    0),
            item(name: "b",      size: 150, offsetSeconds: -200, isDir: true),
        ]
    }

    // MARK: - Sort by name

    func testSortByNameAscendingDirsFirst() {
        let result = sorted(makeFixture(), by: "name", ascending: true)
        XCTAssertTrue(result[0].isDirectory)
        XCTAssertTrue(result[1].isDirectory)
        XCTAssertFalse(result[2].isDirectory)
        XCTAssertFalse(result[3].isDirectory)
        XCTAssertEqual(result[0].name, "a")
        XCTAssertEqual(result[1].name, "b")
        XCTAssertEqual(result[2].name, "m.txt")
        XCTAssertEqual(result[3].name, "z.txt")
    }

    func testSortByNameDescendingDirsFirst() {
        let result = sorted(makeFixture(), by: "name", ascending: false)
        XCTAssertTrue(result[0].isDirectory)
        XCTAssertTrue(result[1].isDirectory)
        XCTAssertEqual(result[0].name, "b")
        XCTAssertEqual(result[1].name, "a")
        XCTAssertEqual(result[2].name, "z.txt")
        XCTAssertEqual(result[3].name, "m.txt")
    }

    // MARK: - Sort by size

    func testSortBySizeAscending() {
        let result = sorted(makeFixture(), by: "size", ascending: true)
        // Dirs first: a(100) < b(150)
        XCTAssertTrue(result[0].isDirectory)
        XCTAssertTrue(result[1].isDirectory)
        XCTAssertEqual(result[0].name, "a")
        XCTAssertEqual(result[1].name, "b")
        // Files: m.txt(200) < z.txt(300)
        XCTAssertEqual(result[2].name, "m.txt")
        XCTAssertEqual(result[3].name, "z.txt")
    }

    func testSortBySizeDescending() {
        let result = sorted(makeFixture(), by: "size", ascending: false)
        // Dirs: b(150) > a(100)
        XCTAssertEqual(result[0].name, "b")
        XCTAssertEqual(result[1].name, "a")
        // Files: z.txt(300) > m.txt(200)
        XCTAssertEqual(result[2].name, "z.txt")
        XCTAssertEqual(result[3].name, "m.txt")
    }

    // MARK: - Sort by date

    func testSortByDateAscending() {
        let result = sorted(makeFixture(), by: "date", ascending: true)
        // Dirs: b(-200) < a(-50)
        XCTAssertEqual(result[0].name, "b")
        XCTAssertEqual(result[1].name, "a")
        // Files: z.txt(-100) < m.txt(0)
        XCTAssertEqual(result[2].name, "z.txt")
        XCTAssertEqual(result[3].name, "m.txt")
    }

    func testSortByDateDescending() {
        let result = sorted(makeFixture(), by: "date", ascending: false)
        // Dirs: a(-50) > b(-200)
        XCTAssertEqual(result[0].name, "a")
        XCTAssertEqual(result[1].name, "b")
        // Files: m.txt(0) > z.txt(-100)
        XCTAssertEqual(result[2].name, "m.txt")
        XCTAssertEqual(result[3].name, "z.txt")
    }

    // MARK: - Edge cases

    func testSortEmptyList() {
        XCTAssertTrue(sorted([], by: "name", ascending: true).isEmpty)
    }

    func testSortSingleItem() {
        let items = [item(name: "only.txt", size: 1)]
        let result = sorted(items, by: "name", ascending: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "only.txt")
    }

    func testSortOnlyDirectories() {
        let items = [
            item(name: "c", size: 0, isDir: true),
            item(name: "a", size: 0, isDir: true),
            item(name: "b", size: 0, isDir: true),
        ]
        let result = sorted(items, by: "name", ascending: true)
        XCTAssertEqual(result.map(\.name), ["a", "b", "c"])
    }

    func testSortOnlyFiles() {
        let items = [
            item(name: "zebra.txt", size: 300),
            item(name: "apple.txt", size: 100),
        ]
        let result = sorted(items, by: "name", ascending: true)
        XCTAssertEqual(result[0].name, "apple.txt")
        XCTAssertEqual(result[1].name, "zebra.txt")
    }

    func testSortUnknownKeyFallsBackToName() {
        let items = [
            item(name: "z.txt", size: 10),
            item(name: "a.txt", size: 20),
        ]
        let result = sorted(items, by: "unknown", ascending: true)
        XCTAssertEqual(result[0].name, "a.txt")
    }

    func testCaseSensitivityInNameSort() {
        let items = [
            item(name: "B.txt", size: 1),
            item(name: "a.txt", size: 1),
        ]
        // localizedStandardCompare is case-insensitive: a < B
        let result = sorted(items, by: "name", ascending: true)
        XCTAssertEqual(result[0].name, "a.txt")
    }
}
