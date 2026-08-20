import SwiftUI
import HeatKit

struct FileRow: View {
    @Environment(AppState.self) var state

    let tree: FileTree
    let depth: Int

    /// What to do when rows are dropped on a folder. Passed down rather than
    /// reached for, because deciding *which* files move needs the list's
    /// selection, which lives with the list.
    let onDrop: (_ draggedIDs: [String], _ folderID: String) -> Bool

    @State private var isDropping = false

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
            // Was here from the start with nothing ever setting it — there was
            // no way to drag a file anywhere. Now it marks the folder a drop
            // would land in.
            .background(isDropping ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 4))
            .modifier(DragAndDrop(file: file, isDropping: $isDropping, onDrop: onDrop))

            // Child references
            if file.isExpanded, let children = tree.children {
                ForEach(children) { child in
                    FileRow(tree: child, depth: depth+1, onDrop: onDrop)
                        .tag(child.id)
                }
            }
        }
    }

    /// A row is one or the other: a folder takes drops, anything else can be
    /// dragged into one.
    ///
    /// Folders are deliberately not draggable — moving one means rewriting
    /// every descendant's path, and dropping it into its own descendant would
    /// strand the subtree. See `FilesProvider.moveFile`.
    private struct DragAndDrop: ViewModifier {
        let file: File
        @Binding var isDropping: Bool
        let onDrop: (_ draggedIDs: [String], _ folderID: String) -> Bool

        func body(content: Content) -> some View {
            if file.isDirectory {
                content.dropDestination(for: String.self) { ids, _ in
                    onDrop(ids, file.id)
                } isTargeted: { targeted in
                    isDropping = targeted
                }
            } else {
                // The payload is the file's id. Plain text dragged in from
                // elsewhere arrives the same way, so the drop handler only
                // acts on ids it can find a file for.
                content.draggable(file.id)
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
