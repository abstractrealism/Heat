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

/// The row a drag is currently over, and the folder a drop there would land in.
///
/// The row is carried as well as the folder so a row can tell whether the
/// focus is still its own to clear — every row inside a folder reports the
/// same folder, so a leave handler that checked only the folder would blink
/// the highlight off as the cursor crossed between siblings.
///
/// Here rather than beside `FileRow`, which is a separate file per platform.
struct DropFocus: Equatable {
    let rowID: String
    let folderID: String?
}

struct FileList: View {
    @Environment(AppState.self) var state
    @Environment(\.dismiss) var dismiss
    @Environment(\.undoManager) private var undoManager

    @Binding var selected: String?

    @AppStorage(FileSortOrder.preferenceKey) private var sortOrder: FileSortOrder = .recentActivity

    @State private var isEditingFile = false

    /// The list's own selection, which can hold several rows so a range can be
    /// acted on at once. `selected` remains the single file being shown on the
    /// right — only one file can be open, however many are highlighted.
    @State private var selection: Set<String> = []

    @State private var pendingDeletion: Set<String> = []

    /// Which row a drag is over, so the folder it would land in can say so.
    @State private var dropFocus: DropFocus?

    /// Files lit for a moment after being moved.
    @State private var recentlyMoved: Set<String> = []

    /// Stands in for the empty space below the list, which has no file behind
    /// it but still claims and releases the drop focus like a row.
    private static let emptySpaceRowID = "\u{0}top-level"

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            searchButton
            Divider()
            #endif
            ScrollViewReader { proxy in
                list(proxy)
            }
        }
    }

    #if os(macOS)
    /// Pinned above the files rather than listed among them: it isn't one of
    /// them, and a row that scrolls away is a poor place for the thing you
    /// reach for when you can't find something.
    private var searchButton: some View {
        Button {
            state.isSearching = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small)
                Text("Search")
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(state.isSearching ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Search across every conversation")
    }
    #endif

    private func list(_ proxy: ScrollViewProxy) -> some View {
        List(selection: $selection) {
            ForEach(sortedTree) { tree in
                FileRow(
                    tree: tree,
                    depth: 0,
                    parentFolderID: nil,
                    dropFocus: $dropFocus,
                    onDrop: handleDrop,
                    recentlyMoved: recentlyMoved
                )
                .tag(tree.id)
            }

            // The way back out of a folder, and the only one that exists when
            // every top-level row is a folder: the empty space beneath the
            // list is itself the top level. A real row rather than a drop
            // destination on the List, so it can't compete with the rows for
            // the same drop. Untagged, so it can't be selected.
            Color.clear
                .frame(minHeight: 60)
                .contentShape(.rect)
                .listRowSeparator(.hidden)
                .listRowInsets(.init())
                .dropDestination(for: String.self) { ids, _ in
                    dropFocus = nil
                    return handleDrop(ids, into: nil)
                } isTargeted: { targeted in
                    if targeted {
                        dropFocus = DropFocus(rowID: Self.emptySpaceRowID, folderID: nil)
                    } else if dropFocus?.rowID == Self.emptySpaceRowID {
                        dropFocus = nil
                    }
                }
        }
        .onChange(of: selection) { _, highlighted in
            // Opening only makes sense for a single row; a wider selection is
            // for doing something to the group, so leave the open file alone.
            if highlighted.count == 1, let only = highlighted.first, only != selected {
                selected = only
                // Picking a file is asking to read it, which search was in the
                // way of.
                state.isSearching = false
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
            deletionPrompt.title,
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            )
        ) {
            Button("Delete", role: .destructive) { handleDelete(pendingDeletion) }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(deletionPrompt.message)
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
                Button("Rename") { handleRename(fileIDs) }

                let groupable = groupableCount(fileIDs)
                if groupable > 0 {
                    Button(groupable == 1 ? "New Folder with 1 Item" : "New Folder with \(groupable) Items") {
                        handleNewFolder(from: fileIDs)
                    }
                }

                // The way back out. Dragging handles going in, but there's
                // nowhere to drop a row to mean "the top level" — the list's
                // own background sits behind every row.
                if isInsideFolder(fileIDs) {
                    Button("Move to Top Level") { move(fileIDs, into: nil) }
                }

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

    /// Files dropped somewhere. A nil folder is the top level.
    ///
    /// Dragging a row that's part of the current selection moves the whole
    /// selection, the way Finder does — the drag itself only carries the one
    /// row it started on, so the rest is read from the selection here.
    private func handleDrop(_ draggedIDs: [String], into folderID: String?) -> Bool {
        var moving = Set(draggedIDs)
        if draggedIDs.contains(where: { selection.contains($0) }) {
            moving.formUnion(selection)
        }
        return move(moving, into: folderID)
    }

    /// Moves what can be moved, and says whether anything was.
    ///
    /// Folders are skipped rather than refused: dragging a mixed selection
    /// should still move the files in it. An id with no file behind it is
    /// skipped too — the drag payload is plain text, so anything at all can
    /// arrive here.
    @discardableResult
    private func move(_ fileIDs: Set<String>, into folderID: String?) -> Bool {
        let movable = fileIDs.filter { id in
            guard id != folderID, let file = try? API.shared.file(id) else { return false }
            return !file.isDirectory
        }
        guard !movable.isEmpty else { return false }

        Task {
            for id in movable {
                do {
                    try await API.shared.fileMove(id, into: folderID)
                } catch {
                    // Carry on with the rest rather than stopping partway and
                    // leaving half the selection moved with no word why.
                    state.log(error: error)
                }
            }
            flash(movable)
        }
        return true
    }

    /// Lights the rows that just moved, long enough to find them.
    ///
    /// The list is sorted, so a file almost never stays where it was let go —
    /// without this a drop looks like the file vanished and something
    /// unrelated appeared. Lit after the moves rather than before, so the row
    /// is already in the place being pointed at.
    private func flash(_ fileIDs: Set<String>) {
        // On at once and unanimated: the point is to catch the eye the moment
        // the row lands, and a fade in would delay exactly that.
        recentlyMoved.formUnion(fileIDs)

        Task {
            try? await Task.sleep(for: .milliseconds(600))
            // Off gently. The row itself asks for no animation on this
            // highlight, so the fade is entirely this: one animation covering
            // both ends would have to either slow the appearance or hurry
            // this.
            withAnimation(.easeOut(duration: 0.7)) {
                // Subtracted rather than cleared: a second drop while this one
                // is still lit must not put the first one's rows out early.
                recentlyMoved.subtract(fileIDs)
            }
        }
    }

    /// Groups a selection into a new folder, the way Finder's "New Folder with
    /// Selection" does.
    ///
    /// The folder is made beside what's going into it when they all share a
    /// parent, and at the top level when they don't — there being no single
    /// "here" for a selection spanning several folders.
    ///
    /// Created expanded, so the files are visible where they landed rather
    /// than appearing to have been swallowed.
    private func handleNewFolder(from fileIDs: Set<String>) {
        let files = fileIDs.compactMap { try? API.shared.file($0) }.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }

        let parents = Set(files.map { ($0.path as NSString).deletingLastPathComponent })
        let parentPath = parents.count == 1 ? (parents.first ?? "") : ""

        Task {
            do {
                let id = String.id
                let folderID = try await state.folderCreate(
                    id: id,
                    name: "New Folder",
                    path: parentPath.isEmpty ? id : "\(parentPath)/\(id)"
                )

                var folder = try API.shared.file(folderID)
                folder.isExpanded = true
                try await API.shared.fileUpdate(folder)

                move(Set(files.map(\.id)), into: folderID)
                selection = [folderID]
            } catch {
                state.log(error: error)
            }
        }
    }

    /// How many of these would actually go into a new folder.
    private func groupableCount(_ fileIDs: Set<String>) -> Int {
        fileIDs.count { id in
            guard let file = try? API.shared.file(id) else { return false }
            return !file.isDirectory
        }
    }

    /// Whether any of these are currently inside a folder, and so have
    /// somewhere to come back out to.
    private func isInsideFolder(_ fileIDs: Set<String>) -> Bool {
        fileIDs.contains { id in
            guard let file = try? API.shared.file(id), !file.isDirectory else { return false }
            return file.path.contains("/")
        }
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

    /// Named for what it does rather than what it opens: the form behind it
    /// has only ever had a name field in it.
    func handleRename(_ fileIDs: Set<String>) {
        if let fileID = fileIDs.first {
            state.selectedFileID = fileID
            isEditingFile = true
        }
    }

    /// Everything a deletion would actually remove: what was chosen, plus the
    /// contents of any folder among it, at any depth.
    ///
    /// Deleting a folder used to remove only the folder. That was harmless
    /// while nothing could be put in one — now that files can be, the folder's
    /// directory would go from disk while its contents kept metadata pointing
    /// into it: gone from the sidebar, still on file, unreachable forever.
    private func deletionTargets(_ fileIDs: Set<String>) -> [File] {
        var targets: [String: File] = [:]
        for id in fileIDs {
            guard let file = try? API.shared.file(id) else { continue }
            targets[file.id] = file
            for child in FileOrder.descendants(of: file, files: state.files) {
                targets[child.id] = child
            }
        }
        // Deepest first, so a folder is empty by the time it's removed.
        return targets.values.sorted {
            $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
        }
    }

    /// What the confirmation says. The count in the title is everything that
    /// goes, and the message calls out contents separately — agreeing to remove
    /// one folder shouldn't quietly take a year of conversations with it.
    private var deletionPrompt: (title: String, message: String) {
        let targets = deletionTargets(pendingDeletion)
        let hidden = targets.count - pendingDeletion.count

        let title = targets.count == 1 ? "Delete File" : "Delete \(targets.count) Files"
        // Undo lives on the window's undo stack, which starts empty each
        // launch — so the promise has to be bounded by the session to be true.
        let undo = "Undo brings this back until you quit Heat."

        guard hidden > 0 else {
            return (title, undo)
        }
        if pendingDeletion.count == 1,
           let folder = try? API.shared.file(pendingDeletion.first!) {
            let name = folder.name ?? "this folder"
            return (title, "Deleting \(name) also deletes the \(hidden) \(hidden == 1 ? "item" : "items") inside it. \(undo)")
        }
        return (title, "This includes \(hidden) \(hidden == 1 ? "item" : "items") inside the folders being deleted. \(undo)")
    }

    func handleDelete(_ fileIDs: Set<String>) {
        let targets = deletionTargets(fileIDs)
        pendingDeletion = []
        Task {
            var deleted: [API.DeletedFile] = []
            for file in targets {
                do {
                    deleted.append(try await API.shared.fileDelete(file.id))
                } catch {
                    // Carry on with the rest rather than stopping partway
                    // through and leaving the outcome unclear.
                    state.log(error: error)
                }
            }
            let removed = Set(targets.map(\.id))
            selection.subtract(removed)
            if let open = selected, removed.contains(open) {
                selected = nil
            }
            registerUndo(for: deleted)
        }
    }

    /// Offers the delete back through the Edit menu and ⌘Z.
    ///
    /// The snapshots live in this closure and nowhere else, so they're held
    /// exactly as long as the undo is on offer and released the moment the
    /// stack drops them — nothing deleted lingers on disk waiting to be
    /// wanted. The cost is that undo doesn't survive quitting, which is what
    /// undo means everywhere else.
    ///
    /// Registered against `AppState`, undo needing an object to own the
    /// action; a `View` is a value and can't.
    private func registerUndo(for deleted: [API.DeletedFile]) {
        guard !deleted.isEmpty, let undoManager else { return }

        undoManager.setActionName(deleted.count == 1 ? "Delete File" : "Delete \(deleted.count) Files")
        undoManager.registerUndo(withTarget: state) { state in
            Task { @MainActor in
                var restored: Set<String> = []
                // Shallowest first, mirroring the deepest-first deletion: a
                // folder has to exist again before what was inside it does.
                for item in deleted.sorted(by: {
                    $0.file.path.split(separator: "/").count < $1.file.path.split(separator: "/").count
                }) {
                    do {
                        try await API.shared.fileRestore(item)
                        restored.insert(item.file.id)
                    } catch {
                        state.log(error: error)
                    }
                }
                selection = restored
            }
        }
    }
}
