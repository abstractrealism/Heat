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

    /// The list's own selection, which can hold several rows so a range can be
    /// acted on at once. `selected` remains the single file being shown on the
    /// right — only one file can be open, however many are highlighted.
    @State private var selection: Set<String> = []

    @State private var pendingDeletion: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy)
        }
    }

    private func list(_ proxy: ScrollViewProxy) -> some View {
        List(selection: $selection) {
            ForEach(sortedTree) { tree in
                FileRow(tree: tree, depth: 0)
                    .tag(tree.id)
            }
        }
        .onChange(of: selection) { _, highlighted in
            // Opening only makes sense for a single row; a wider selection is
            // for doing something to the group, so leave the open file alone.
            if highlighted.count == 1, let only = highlighted.first, only != selected {
                selected = only
            }
        }
        .onChange(of: selected) { _, openFile in
            guard let openFile else { return }

            // Follow along when something else changes what's open, such as
            // creating a conversation, without disturbing a wider selection.
            if !selection.contains(openFile) {
                selection = [openFile]
            }

            // Kept outside that condition, and reached even when the row was
            // already highlighted: stepping between conversations by keyboard
            // can open one that's scrolled out of sight, where the detail view
            // changes and the sidebar appears not to have moved at all.
            proxy.scrollTo(openFile)
        }
        .onAppear {
            if let selected { selection = [selected] }
        }
        #if os(macOS)
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            pendingDeletion = selection
        }
        #endif
        .confirmationDialog(
            "Delete \(pendingDeletion.count == 1 ? "File" : "\(pendingDeletion.count) Files")",
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            )
        ) {
            Button("Delete", role: .destructive) { handleDelete(pendingDeletion) }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("This can't be undone.")
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
                .help("Sort")
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
                Button("Delete", role: .destructive) { pendingDeletion = fileIDs }
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
    ///
    /// The sort itself lives in `FileOrder`, shared with the keyboard shortcuts
    /// that step between conversations — they have to move in the order the
    /// list is drawn in, and a second copy of this would eventually disagree.
    private var sortedTree: [FileTree] {
        FileOrder.sorted(state.fileTree, files: state.files, by: sortOrder)
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
        pendingDeletion = []
        Task {
            for fileID in fileIDs {
                do {
                    try await API.shared.fileDelete(fileID)
                } catch {
                    // Carry on with the rest rather than stopping partway
                    // through and leaving the outcome unclear.
                    state.log(error: error)
                }
            }
            selection.subtract(fileIDs)
            if let open = selected, fileIDs.contains(open) {
                selected = nil
            }
        }
    }
}
