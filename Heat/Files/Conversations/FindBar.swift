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

    /// What's been typed, ahead of what's being searched. The field writes
    /// here and the search follows a pause behind it: searching on every
    /// keystroke re-marked matching messages per character, and with each
    /// mark being a re-parse the typing itself stopped echoing.
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.footnote)

            TextField("Find in conversation", text: $draft)
            .textFieldStyle(.plain)
            .font(.footnote)
            .frame(width: 150)
            .focused($isFocused)
            // Return steps forward, Shift+Return back, as everywhere else that
            // has a find bar. Stepping is against what's typed, not what the
            // pause has caught up to.
            .onSubmit {
                commitDraft()
                conversationViewModel.findNext()
            }
            .task(id: draft) {
                guard draft != conversationViewModel.findQuery else { return }
                try? await Task.sleep(for: .milliseconds(200))
                conversationViewModel.setFindQuery(draft)
            }

            if !conversationViewModel.findQuery.isEmpty {
                Text(position)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
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
        .onAppear {
            isFocused = true
            // A search result primes the query before the bar exists; the
            // field has to open showing it.
            draft = conversationViewModel.findQuery
        }
        // Escape closes, which is what the key is for and what stops the bar
        // needing the mouse to dismiss.
        .onExitCommand { conversationViewModel.endFind() }
    }

    /// Runs the search on what's typed right now, for the paths that act on
    /// the query rather than wait for it.
    private func commitDraft() {
        if draft != conversationViewModel.findQuery {
            conversationViewModel.setFindQuery(draft)
        }
    }

    /// Counted in matches, because matches are what the arrows move between.
    ///
    /// It counted messages for a while, and that was honest at the time: a
    /// match couldn't be marked where it sat, so the arrows could only move
    /// between messages and a count of occurrences would have been a promise
    /// the buttons couldn't keep — five matches in one message read as "1 of
    /// 5" and then refused to go anywhere. Marking them individually removed
    /// the reason, so the number went back to meaning what anyone would
    /// assume, and needs no unit to say so.
    private var position: String {
        let total = conversationViewModel.findMatches.count
        guard total > 0 else { return "none" }
        return "\(conversationViewModel.findIndex + 1) of \(total)"
    }
}
