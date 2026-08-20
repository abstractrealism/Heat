import SwiftUI
import HeatKit

struct FileRow: View {
    @Environment(AppState.self) var state

    let tree: FileTree
    let depth: Int

    /// The folder this row sits in, nil at the top level.
    ///
    /// Handed down through the recursion, which already knows it, rather than
    /// worked out from the path here — that would be a scan of every file for
    /// every row on every redraw.
    let parentFolderID: String?

    /// Which row the cursor is over mid-drag, shared so the *folder* lights up
    /// when a row inside it is hovered.
    @Binding var dropFocus: DropFocus?

    /// What to do when rows are dropped. Passed down rather than reached for,
    /// because deciding *which* files move needs the list's selection, which
    /// lives with the list.
    let onDrop: (_ draggedIDs: [String], _ folderID: String?) -> Bool

    /// Files that have just been moved, briefly lit so they can be found
    /// again in the sorted list.
    let recentlyMoved: Set<String>

    /// How far past its own height a row answers a drop, covering the gap the
    /// list leaves between rows. Cosmetically invisible: the layout is pulled
    /// back by the same amount.
    private static let dropOverhang: CGFloat = 3

    /// Where a drop on this row lands: into it if it's a folder, otherwise
    /// into whatever folder it sits in — so the whole of a folder's contents
    /// is one target, and a top-level row means the top level.
    private var dropFolderID: String? {
        (try? API.shared.file(tree.id))?.isDirectory == true ? tree.id : parentFolderID
    }

    private func isDropTarget(_ file: File) -> Bool {
        file.isDirectory && dropFocus?.folderID == file.id
    }

    var body: some View {
        if let file = try? API.shared.file(tree.id) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                    .frame(width: leadingSpace(file))

                if file.isDirectory {
                    disclosureButton(file)
                }

                Text(file.name ?? "Untitled")
                    .help(file.name ?? "Untitled")

                if file.isDirectory, let count = tree.children?.count, count > 0 {
                    Text("\(count) items")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }

                Spacer()

                // Marks a conversation that's still working, so it's visible
                // from the list without opening it.
                if ConversationViewModelStore.shared.generatingFileIDs.contains(tree.id) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                        .help("Generating a response")
                }

                if file.flag == "pin" {
                    Image(systemName: "flag.fill")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The row's own vertical space, taken back from the list. With the
            // list's insets doing it instead, the margins belonged to the row's
            // slot but not to this view, so the gaps between rows accepted no
            // drop at all and the cursor flickered between refusing and
            // accepting on the way past.
            .padding(.vertical, 4)
            // Two things wear the same highlight, and they're drawn separately
            // because they come and go differently. A file that just moved
            // lights the instant it lands and fades out slowly; nothing
            // animates it here, so the fade is whatever the change that clears
            // it asks for — see FileList.flash. One animation governing both
            // ends would have to either delay the appearance or hurry the
            // fade.
            .background(
                recentlyMoved.contains(tree.id) ? Color.accentColor.opacity(0.25) : .clear,
                in: .rect(cornerRadius: 4)
            )
            // The folder a drop is heading for, which wants to keep up with the
            // cursor rather than linger.
            .background(
                isDropTarget(file) ? Color.accentColor.opacity(0.25) : .clear,
                in: .rect(cornerRadius: 4)
            )
            .animation(.easeOut(duration: 0.15), value: isDropTarget(file))
            // A sliver of space survives between rows that belongs to the list
            // rather than to either of them. `listRowSpacing` would close it,
            // but that modifier is iOS-only, so instead the hit area is grown
            // past the row and the layout pulled back by the same amount: the
            // row occupies what it always did, and answers a drop slightly
            // beyond it. Applied after the background, so nothing about the
            // highlight moves.
            .padding(.vertical, Self.dropOverhang)
            // The whole row rather than the words in it. A Spacer is layout and
            // not content, so with no shape to hit only the label itself
            // answers — which is why a drop had to land on the text.
            .contentShape(.rect)
            .modifier(
                DragAndDrop(
                    file: file,
                    rowID: tree.id,
                    folderID: dropFolderID,
                    dropFocus: $dropFocus,
                    onDrop: onDrop
                )
            )
            // The other half of the overhang: the row lays out at its real
            // height, having answered drops at the taller one.
            .padding(.vertical, -Self.dropOverhang)
            // Vertical spacing is the row's own now, so rows meet with nothing
            // dead between them. Horizontal is stated rather than defaulted
            // because these insets replace the list's outright — the leading
            // value stands in for the sidebar's usual margin, and `leadingSpace`
            // adds depth on top of it.
            .listRowInsets(.init(top: 0, leading: 10, bottom: 0, trailing: 10))

            // Child references
            if file.isExpanded, let children = tree.children {
                ForEach(children) { child in
                    // Children of an expanded row are inside it — only
                    // directories ever expand.
                    FileRow(
                        tree: child,
                        depth: depth+1,
                        parentFolderID: file.id,
                        dropFocus: $dropFocus,
                        onDrop: onDrop,
                        recentlyMoved: recentlyMoved
                    )
                    .tag(child.id)
                }
            }
        }
    }

    /// Every row takes a drop; only files can be dragged.
    ///
    /// A folder used to be the only target, which meant landing exactly on its
    /// name — and left no way back out at all, the top level having no row to
    /// aim at. Now a drop anywhere in a folder's contents means that folder,
    /// and anywhere at the top level means the top level.
    ///
    /// Folders are deliberately not draggable — moving one means rewriting
    /// every descendant's path, and dropping it into its own descendant would
    /// strand the subtree. See `FilesProvider.moveFile`.
    private struct DragAndDrop: ViewModifier {
        let file: File
        let rowID: String
        let folderID: String?
        @Binding var dropFocus: DropFocus?
        let onDrop: (_ draggedIDs: [String], _ folderID: String?) -> Bool

        func body(content: Content) -> some View {
            dropTarget(content)
                // The payload is the file's id. Plain text dragged in from
                // elsewhere arrives the same way, so the drop handler only
                // acts on ids it can find a file for.
                .modifier(Draggable(file: file))
        }

        private func dropTarget(_ content: Content) -> some View {
            content.dropDestination(for: String.self) { ids, _ in
                dropFocus = nil
                return onDrop(ids, folderID)
            } isTargeted: { targeted in
                if targeted {
                    dropFocus = DropFocus(rowID: rowID, folderID: folderID)
                } else if dropFocus?.rowID == rowID {
                    // Only the row that claimed the focus may give it up.
                    // Rows inside one folder all point at the same folder, so
                    // clearing on any leave would blink the highlight off as
                    // the cursor crossed between them.
                    dropFocus = nil
                }
            }
        }

        private struct Draggable: ViewModifier {
            let file: File

            func body(content: Content) -> some View {
                if file.isDirectory {
                    content
                } else {
                    content.draggable(file.id)
                }
            }
        }
    }

    func disclosureButton(_ file: File) -> some View {
        Button(action: handleExpandFolder) {
            Image(systemName: file.isExpanded ? "chevron.down" : "chevron.right")
                .imageScale(.small)
                .fontWeight(.medium)
        }
        .buttonStyle(.borderless)
        .frame(width: 8)
    }

    func leadingSpace(_ file: File) -> CGFloat {
        if file.isDirectory {
            return CGFloat(depth * 18)
        } else {
            return CGFloat(depth * 18) + 8 + 4
        }
    }

    func handleExpandFolder() {
        Task {
            do {
                var file = try API.shared.file(tree.id)
                file.isExpanded.toggle()
                try await API.shared.fileUpdate(file)
            } catch {
                print(error)
            }
        }
    }
}
