import SwiftUI
import HeatKit

struct FileRow: View {
    @Environment(AppState.self) var state

    let tree: FileTree
    let depth: Int

    var body: some View {
        if let file = try? API.shared.file(tree.id) {
            HStack {
                Text(file.name ?? file.path)

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
