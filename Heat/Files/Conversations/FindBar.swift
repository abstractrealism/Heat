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
            .frame(width: 150)
            .focused($isFocused)
            // Return steps forward, Shift+Return back, as everywhere else that
            // has a find bar.
            .onSubmit { conversationViewModel.findNext() }

            if !conversationViewModel.findQuery.isEmpty {
                Text(position)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 96, alignment: .trailing)
            }

            // Only the stepping is disabled with nothing to step through.
            // This was on the whole bar, which disabled the field as well: a
            // fresh find bar has no matches yet, so it opened unable to be
            // typed into, and `.disabled` is cumulative — a descendant cannot
            // re-enable itself, which is what the exemption here used to
            // pretend to do.
            Button(action: conversationViewModel.findPrevious) {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(conversationViewModel.findMatches.isEmpty)
            .help("Previous message")

            Button(action: conversationViewModel.findNext) {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(conversationViewModel.findMatches.isEmpty)
            .help("Next message")

            Button(action: conversationViewModel.endFind) {
                Image(systemName: "xmark")
            }
            // Escape as well as the button. A disabled bar swallowed
            // onExitCommand, which is how the bar became impossible to close
            // at all; the shortcut is a second way out that doesn't depend on
            // the container being enabled.
            .keyboardShortcut(.cancelAction)
            .help("Close find")
        }
        .buttonStyle(.borderless)
        .imageScale(.small)
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

    /// Counted in messages, because messages are what the arrows move between.
    ///
    /// It counted every occurrence before, which made the number a promise the
    /// buttons couldn't keep: five matches inside one message read as "1 of 5"
    /// and then refused to go anywhere, there being one message to go to. The
    /// unit is named so the number can't be read as anything else.
    private var position: String {
        let total = conversationViewModel.findMatches.count
        switch total {
        case 0: return "none"
        case 1: return "1 message"
        default: return "\(conversationViewModel.findIndex + 1) of \(total) messages"
        }
    }
}
