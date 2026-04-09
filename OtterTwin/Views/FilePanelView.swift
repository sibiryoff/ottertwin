import SwiftUI

struct FilePanelView: View {
    @Binding var path: URL
    @Binding var selection: Set<URL>
    let isActive: Bool
    var onActivate: () -> Void = {}

    @State private var items: [FileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var sortOrder: [KeyPathComparator<FileItem>] = [
        .init(\.name, order: .forward)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb header
            BreadcrumbView(path: path) { url in
                path = url
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FileTableView(
                    items: sortedItems,
                    selection: $selection,
                    onDoubleClick: navigate,
                    onActivate: onActivate
                )
            }
        }
        .frame(minWidth: 300)
        .task(id: path) { await loadDirectory() }
    }

    // MARK: - Helpers

    private var sortedItems: [FileItem] {
        items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        do {
            items = try await LocalProvider().listDirectory(path)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func navigate(to item: FileItem) {
        guard item.isDirectory else { return }
        path = item.id
        selection = []
    }
}

// MARK: - BreadcrumbView

struct BreadcrumbView: View {
    let path: URL
    let onNavigate: (URL) -> Void

    private var components: [(name: String, url: URL)] {
        // Build from pathComponents to avoid the deletingLastPathComponent() root trap.
        let parts = path.pathComponents  // e.g. ["/", "Users", "mas"]
        var result: [(String, URL)] = []
        var built = URL(fileURLWithPath: "/")
        for (i, part) in parts.enumerated() {
            if i == 0 {
                result.append(("/", built))
            } else {
                built = built.appendingPathComponent(part)
                result.append((part, built))
            }
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button(component.name) {
                        onNavigate(component.url)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
                }
            }
        }
    }
}
