import SwiftUI
import AppKit

// MARK: - SwiftUI wrapper

struct FileTableView: NSViewRepresentable {
    let items: [FileItem]
    @Binding var selection: Set<URL>
    let isActive: Bool
    var accessibilityID: String = "fileTable"
    let onDoubleClick: (FileItem) -> Void
    var onActivate: () -> Void = {}
    var onEnterKey: () -> Void = {}
    var onBackspace: () -> Void = {}
    var onSortChange: (String, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: $selection, items: items,
            onDoubleClick: onDoubleClick, onActivate: onActivate,
            onEnterKey: onEnterKey, onBackspace: onBackspace, onSortChange: onSortChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = FileListView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnReordering = false

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 160
        nameCol.sortDescriptorPrototype = NSSortDescriptor(
            key: "name", ascending: true,
            selector: #selector(NSString.localizedStandardCompare)
        )
        tableView.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        tableView.addTableColumn(sizeCol)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "Modified"
        dateCol.width = 140
        dateCol.minWidth = 100
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
        tableView.addTableColumn(dateCol)

        // Reflect default sort order in the header
        tableView.sortDescriptors = [NSSortDescriptor(
            key: "name", ascending: true,
            selector: #selector(NSString.localizedStandardCompare)
        )]

        tableView.setAccessibilityIdentifier("fileTable.\(accessibilityID)")

        context.coordinator.tableView = tableView
        let coordinator = context.coordinator
        tableView.onEnterKey = { coordinator.onEnterKey() }
        tableView.onBackspace = { coordinator.onBackspace() }

        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.target = context.coordinator

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onActivate = onActivate
        context.coordinator.onEnterKey = onEnterKey
        context.coordinator.onBackspace = onBackspace
        context.coordinator.onSortChange = onSortChange
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        if context.coordinator.items != items {
            context.coordinator.items = items
            tableView.reloadData()
            if isActive {
                // Defer past SwiftUI's update cycle — calling makeFirstResponder
                // synchronously here fires before the window finishes layout.
                DispatchQueue.main.async {
                    tableView.window?.makeFirstResponder(tableView)
                    if !items.isEmpty {
                        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                        tableView.scrollRowToVisible(0)
                    }
                }
            }
            return
        }

        // Sync selection changes from SwiftUI (e.g. cleared after a copy/move)
        let newIndexes = NSMutableIndexSet()
        for (i, item) in items.enumerated() {
            if selection.contains(item.id) { newIndexes.add(i) }
        }
        if tableView.selectedRowIndexes != newIndexes as IndexSet {
            tableView.selectRowIndexes(newIndexes as IndexSet, byExtendingSelection: false)
        }
        // Re-focus when the active panel changes (Tab key)
        if isActive, tableView.window?.firstResponder !== tableView {
            DispatchQueue.main.async {
                tableView.window?.makeFirstResponder(tableView)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        @Binding var selection: Set<URL>
        var items: [FileItem]
        var onDoubleClick: (FileItem) -> Void
        var onActivate: () -> Void
        var onEnterKey: () -> Void
        var onBackspace: () -> Void
        var onSortChange: (String, Bool) -> Void
        weak var tableView: NSTableView?

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return f
        }()

        init(
            selection: Binding<Set<URL>>,
            items: [FileItem],
            onDoubleClick: @escaping (FileItem) -> Void,
            onActivate: @escaping () -> Void,
            onEnterKey: @escaping () -> Void,
            onBackspace: @escaping () -> Void,
            onSortChange: @escaping (String, Bool) -> Void
        ) {
            _selection = selection
            self.items = items
            self.onDoubleClick = onDoubleClick
            self.onActivate = onActivate
            self.onEnterKey = onEnterKey
            self.onBackspace = onBackspace
            self.onSortChange = onSortChange
        }

        // MARK: DataSource

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let item = items[row]
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView
                ?? NSTableCellView()
            cell.identifier = tableColumn.identifier

            if cell.textField == nil {
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(tf)
                cell.textField = tf
                NSLayoutConstraint.activate([
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                ])
            }

            switch tableColumn.identifier.rawValue {
            case "name": cell.textField?.stringValue = (item.isDirectory ? "📁 " : "📄 ") + item.name
            case "size": cell.textField?.stringValue = item.displaySize
            case "date": cell.textField?.stringValue = Self.dateFormatter.string(from: item.modificationDate)
            default: break
            }
            return cell
        }

        // MARK: Delegate

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTableView else { return }
            tv.window?.makeFirstResponder(tv)
            onActivate()
            let selected = tv.selectedRowIndexes.compactMap { items[safe: $0]?.id }
            selection = Set(selected)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
            guard let first = tableView.sortDescriptors.first, let key = first.key else { return }
            onSortChange(key, first.ascending)
        }

        @objc func handleDoubleClick(_ sender: Any) {
            guard let tv = tableView, tv.clickedRow >= 0, tv.clickedRow < items.count else { return }
            onDoubleClick(items[tv.clickedRow])
        }
    }
}

// MARK: - NSTableView subclass for keyboard handling

private final class FileListView: NSTableView {
    var onEnterKey: (() -> Void)?
    var onBackspace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onEnterKey?()   // Return, numpad Enter
        case 51:     onBackspace?()  // Delete/Backspace
        default:     super.keyDown(with: event)
        }
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
