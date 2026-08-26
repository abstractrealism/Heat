import SwiftUI
import HeatKit

/// Find within the open conversation.
///
/// Sits over the thread at the top right, the way a browser's does, rather
/// than pushing the messages down — a bar that changes the layout moves what
/// you were reading at the moment you go looking for it.
struct FindBar: View {
    @Environment(ConversationViewModel.self) private var conversationViewModel

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.footnote)

            TextField("Find in conversation", text: Binding(
                get: { conversationViewModel.findQuery },
                set: { conversationViewModel.setFindQuery($0) }
            ))
            .textFieldStyle(.plain)
            .font(.footnote)
            .frame(width: 160)
            .focused($isFocused)
            // Return steps forward, Shift+Return back, as everywhere else that
            // has a find bar.
            .onSubmit { conversationViewModel.findNext() }

            if !conversationViewModel.findQuery.isEmpty {
                Text(position)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 54, alignment: .trailing)
            }

            Button(action: conversationViewModel.findPrevious) {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Previous match")

            Button(action: conversationViewModel.findNext) {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .help("Next match")

            Button(action: conversationViewModel.endFind) {
                Image(systemName: "xmark")
            }
            .help("Close find")
        }
        .buttonStyle(.borderless)
        .imageScale(.small)
        .disabled(conversationViewModel.findMatches.isEmpty)
        // The close button stays live even with nothing found, since that's
        // exactly when you want to give up on a search.
        .environment(\.isEnabled, true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.top, 10)
        .padding(.trailing, 14)
        .onAppear { isFocused = true }
        // Escape closes, which is what the key is for and what stops the bar
        // needing the mouse to dismiss.
        .onExitCommand { conversationViewModel.endFind() }
    }

    /// "3 of 12", or that there's nothing — a count of zero reads as a broken
    /// search rather than an answered one.
    private var position: String {
        guard conversationViewModel.findMatchTotal > 0 else { return "none" }
        let matchesBefore = conversationViewModel.findMatches
            .prefix(conversationViewModel.findIndex)
            .reduce(0) { $0 + $1.count }
        return "\(matchesBefore + 1) of \(conversationViewModel.findMatchTotal)"
    }
}
