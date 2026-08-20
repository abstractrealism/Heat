import SwiftUI
import HeatKit

struct FileRow: View {
    @Environment(AppState.self) var state

    let tree: FileTree
    let depth: Int

    // Accepted so the shared FileList builds on both platforms, and unused:
    // dragging files between folders is a macOS-only affordance for now.
    let parentFolderID: String?
    @Binding var dropFocus: DropFocus?
    let onDrop: (_ draggedIDs: [String], _ folderID: String?) -> Bool
    let recentlyMoved: Set<String>

    var body: some View {
        if let file = try? API.shared.file(tree.id) {
            HStack {
                Text(file.name ?? file.path)
                    .help(file.name ?? file.path)

                Spacer()

                // Marks a conversation that's still working, so it's visible
                // from the list without opening it.
                if ConversationViewModelStore.shared.generatingFileIDs.contains(tree.id) {
                    ProgressView()
                        .controlSize(.small)
                        .help("Generating a response")
                }

                if let count = tree.children?.count, count > 0 {
                    Text("\(count) items")
                        .foregroundStyle(.tertiary)
                }
                if file.flag == "pin" {
                    Image(systemName: "flag.fill")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
