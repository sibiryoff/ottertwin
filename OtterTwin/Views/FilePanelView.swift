import SwiftUI

struct FilePanelView: View {
    @Binding var path: URL
    @Binding var selection: Set<URL>
    let isActive: Bool
    var onActivate: () -> Void = {}

    @State private var items: [FileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var sortKey: String = "name"
    @State private var sortAscending: Bool = true
    @State private var showSMBConnect = false

    var body: some View {
        VStack(spacing: 0) {
            // Location shortcuts
            LocationBar(currentPath: path, onNavigate: { url in path = url }, onConnectSMB: { showSMBConnect = true })
                .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)

            Divider()

            // Breadcrumb
            BreadcrumbView(path: path) { url in path = url }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)

            Divider()

            // FileTableView stays in the hierarchy at all times so the NSTableView
            // is never destroyed between directory loads — destroying it resets first
            // responder, which breaks keyboard navigation. Loading/error states are
            // overlaid on top instead.
            ZStack {
                FileTableView(
                    items: sortedItems,
                    selection: $selection,
                    isActive: isActive,
                    onDoubleClick: navigate,
                    onActivate: onActivate,
                    onEnterKey: navigateSelected,
                    onBackspace: navigateUp,
                    onSortChange: { key, asc in sortKey = key; sortAscending = asc }
                )
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial)
                } else if let err = errorMessage {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial)
                }
            }
        }
        .frame(minWidth: 300)
        .task(id: path) { await loadDirectory() }
        .sheet(isPresented: $showSMBConnect) {
            SMBConnectView(onConnect: { provider in
                // After mounting, navigate to the share's local mount point
                if let mountURL = try? provider.rootURL {
                    path = mountURL
                }
                showSMBConnect = false
            })
        }
    }

    // MARK: - Sorting

    private var sortedItems: [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sortKey {
            case "size":
                return sortAscending ? a.size < b.size : a.size > b.size
            case "date":
                return sortAscending ? a.modificationDate < b.modificationDate
                                     : a.modificationDate > b.modificationDate
            default: // "name"
                let cmp = a.name.localizedStandardCompare(b.name)
                return sortAscending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
    }

    // MARK: - Navigation

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

    /// Enter — navigate into the selected folder.
    private func navigateSelected() {
        guard selection.count == 1, let url = selection.first,
              let item = items.first(where: { $0.id == url }) else { return }
        navigate(to: item)
    }

    /// Backspace — go up to parent directory.
    private func navigateUp() {
        let parent = path.deletingLastPathComponent()
        guard parent != path else { return }
        path = parent
        selection = []
    }
}

// MARK: - LocationBar

private struct LocationBar: View {
    let currentPath: URL
    let onNavigate: (URL) -> Void
    let onConnectSMB: () -> Void

    private let fm = FileManager.default

    private var locations: [(label: String, icon: String, url: URL)] {
        let home = fm.homeDirectoryForCurrentUser
        return [
            ("Home",      "house",           home),
            ("Desktop",   "menubar.dock.rectangle", home.appending(path: "Desktop")),
            ("Documents", "doc",             home.appending(path: "Documents")),
            ("Downloads", "arrow.down.circle", home.appending(path: "Downloads")),
            ("/Volumes",  "externaldrive",   URL(fileURLWithPath: "/Volumes")),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(locations, id: \.url) { loc in
                        Button {
                            onNavigate(loc.url)
                        } label: {
                            Label(loc.label, systemImage: loc.icon)
                                .labelStyle(.iconOnly)
                                .help(loc.label)
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                        .background(
                            currentPath.path.hasPrefix(loc.url.path)
                                ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    }
                }
                .padding(.horizontal, 6)
            }

            Divider().frame(height: 16)

            // SMB connect button
            Button {
                onConnectSMB()
            } label: {
                Label("Connect to Server…", systemImage: "network.badge.shield.half.filled")
                    .labelStyle(.iconOnly)
                    .help("Connect to SMB server…")
            }
            .buttonStyle(.plain)
            .padding(5)
        }
        .padding(.vertical, 2)
        .frame(height: 30)
    }
}

// MARK: - BreadcrumbView

struct BreadcrumbView: View {
    let path: URL
    let onNavigate: (URL) -> Void

    private var components: [(name: String, url: URL)] {
        let parts = path.pathComponents
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
