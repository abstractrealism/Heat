import HeatKit
import SwiftUI

/// How the file list is ordered. Stored per machine, since it's about how
/// someone likes to look at their files rather than anything about the files.
enum FileSortOrder: String, CaseIterable, Identifiable {
    case recentActivity
    case dateCreated
    case name

    static let preferenceKey = "fileSortOrder"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentActivity: "Recent Activity"
        case .dateCreated: "Date Created"
        case .name: "Name"
        }
    }
}

struct FileList: View {
    @Environment(AppState.self) var state
    @Environment(\.dismiss) var dismiss

    @Binding var selected: String?

    @AppStorage(FileSortOrder.preferenceKey) private var sortOrder: FileSortOrder = .recentActivity

    @State private var isEditingFile = false

    var body: some View {
        List(selection: $selected) {
            ForEach(sortedTree) { tree in
                FileRow(tree: tree, depth: 0)
                    .tag(tree.id)
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(FileSortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.plain)
        #endif
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Files")
        #if os(macOS)
        .contextMenu(forSelectionType: String.self) { fileIDs in
            Group {
                Button("Show in Finder") { handleShowFinder(fileIDs) }
                Button("Edit") { handleEdit(fileIDs) }
                Divider()
                Button("Delete", role: .destructive) { handleDelete(fileIDs) }
            }
        }
        #endif
        .sheet(isPresented: $isEditingFile) {
            if let fileID = state.selectedFileID {
                NavigationStack {
                    FileForm(fileID: fileID)
                }
            }
        }
        .overlay(alignment: .center) {
            if sortedTree.isEmpty {
                ContentUnavailableView {
                    Label("No files", systemImage: "doc.on.doc")
                } description: {
                    Text("New files you create will appear here.")
                }
            }
        }
        #if os(iOS)
        .onChange(of: selected) { _, newValue in
            if newValue != nil { dismiss() }
        }
        #endif
    }

    /// The tree in the chosen order, folders sorted the same way inside.
    ///
    /// Nothing sorted this before: the list came back in whatever order the
    /// directory happened to enumerate in, which is why it looked like no
    /// order at all. Newest activity first is the default because the thing
    /// you were last working on is almost always the one you want next.
    private var sortedTree: [FileTree] {
        // One lookup for the whole sort, rather than searching the file list
        // again for every comparison.
        let filesByID = Dictionary(
            state.files.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return sort(state.fileTree, using: filesByID)
    }

    private func sort(_ trees: [FileTree], using filesByID: [String: File]) -> [FileTree] {
        trees
            .map { tree in
                var tree = tree
                if let children = tree.children {
                    tree.children = sort(children, using: filesByID)
                }
                return tree
            }
            .sorted { isOrderedBefore($0, $1, using: filesByID) }
    }

    private func isOrderedBefore(_ lhs: FileTree, _ rhs: FileTree, using filesByID: [String: File]) -> Bool {
        // A row with no file behind it can't be ordered meaningfully, and
        // FileRow won't draw it either, so let it settle at the end.
        guard let left = filesByID[lhs.id] else { return false }
        guard let right = filesByID[rhs.id] else { return true }

        switch sortOrder {
        case .recentActivity:
            return left.modified > right.modified
        case .dateCreated:
            return left.created > right.created
        case .name:
            // Matches what the row displays, and compares the way a person
            // reads names — case-insensitive, with numbers in numeric order.
            return displayName(left).localizedStandardCompare(displayName(right)) == .orderedAscending
        }
    }

    private func displayName(_ file: File) -> String {
        file.name ?? file.path
    }

    func handleShowFinder(_ fileIDs: Set<String>) {
        #if os(macOS)
        guard let fileID = fileIDs.first else { return }
        guard let file = try? API.shared.file(fileID) else { return }

        let url = URL.documentsDirectory
            .appending(path: file.path)

        if url.hasDirectoryPath {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        #endif
    }

    func handleEdit(_ fileIDs: Set<String>) {
        if let fileID = fileIDs.first {
            state.selectedFileID = fileID
            isEditingFile = true
        }
    }

    func handleDelete(_ fileIDs: Set<String>) {
        Task {
            for fileID in fileIDs {
                try await API.shared.fileDelete(fileID)
            }
        }
    }
}
