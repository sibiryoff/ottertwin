import SwiftUI
import AppKit

// MARK: - SwiftUI wrapper

struct FileTableView: NSViewRepresentable {
    let items: [FileItem]
    @Binding var selection: Set<URL>
    let onDoubleClick: (FileItem) -> Void
    /// Called when the table view receives a click — used to mark the panel active.
    var onActivate: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, items: items, onDoubleClick: onDoubleClick, onActivate: onActivate)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        // Columns
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 160
        tableView.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        tableView.addTableColumn(sizeCol)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "Modified"
        dateCol.width = 140
        dateCol.minWidth = 100
        tableView.addTableColumn(dateCol)

        context.coordinator.tableView = tableView

        // Double-click
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.target = context.coordinator

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onActivate = onActivate
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        if context.coordinator.items != items {
            context.coordinator.items = items
            tableView.reloadData()
        }

        // Sync selection from SwiftUI → AppKit
        let newIndexes = NSMutableIndexSet()
        for (i, item) in items.enumerated() {
            if selection.contains(item.id) { newIndexes.add(i) }
        }
        if tableView.selectedRowIndexes != newIndexes as IndexSet {
            tableView.selectRowIndexes(newIndexes as IndexSet, byExtendingSelection: false)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        @Binding var selection: Set<URL>
        var items: [FileItem]
        var onDoubleClick: (FileItem) -> Void
        var onActivate: () -> Void
        weak var tableView: NSTableView?

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return f
        }()

        init(selection: Binding<Set<URL>>, items: [FileItem], onDoubleClick: @escaping (FileItem) -> Void, onActivate: @escaping () -> Void) {
            _selection = selection
            self.items = items
            self.onDoubleClick = onDoubleClick
            self.onActivate = onActivate
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
            // Make this table view first responder so arrow keys work.
            tv.window?.makeFirstResponder(tv)
            onActivate()
            let selected = tv.selectedRowIndexes.compactMap { items[safe: $0]?.id }
            selection = Set(selected)
        }

        @objc func handleDoubleClick(_ sender: Any) {
            guard let tv = tableView, tv.clickedRow >= 0, tv.clickedRow < items.count else { return }
            onDoubleClick(items[tv.clickedRow])
        }
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
