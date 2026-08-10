import SwiftUI
import SharedKit
import HeatKit

struct MessageList: View {
    @Environment(AppState.self) var state
    @Environment(ConversationViewModel.self) var conversationViewModel

    /// Whether the view is sitting at (or very near) the newest content.
    /// Auto-scrolling only happens while this holds, so scrolling up to read
    /// during a response isn't fought by every incoming token.
    @State private var isPinnedToBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            MessageListScrollView {

                // Show message run history
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(conversationViewModel.runs) { run in
                        RunView(run)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    // Inline error when the last generation attempt failed
                    if let error = conversationViewModel.error {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error)
                        }
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }

                    // What the assistant is doing, where its answer will appear
                    switch conversationViewModel.phase {
                    case .waiting:
                        GeneratingIndicator("Generating")
                    case .thinking:
                        GeneratingIndicator("Thinking")
                    case .responding, .suggesting, .idle:
                        EmptyView()
                    }

                    // Suggestions, or a note that they're on their way, in the
                    // place they'll appear
                    if conversationViewModel.phase == .suggesting {
                        GeneratingIndicator("Generating suggestions", alignment: .trailing)
                    } else if !conversationViewModel.suggestions.isEmpty {
                        SuggestionList(suggestions: conversationViewModel.suggestions) { suggestion in
                            SuggestionView(suggestion: suggestion) { handleSubmit($0) }
                        }
                    }
                }
                .id("bottom")
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // A small slack keeps rounding and the bounce at the end of a
                // scroll from reading as "the user scrolled away".
                let distanceFromBottom = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                return distanceFromBottom <= 40
            } action: { _, pinned in
                isPinnedToBottom = pinned
            }
            .onChange(of: conversationViewModel.file.modified) { _, _ in
                guard isPinnedToBottom else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .task(id: conversationViewModel.file.id) {
                // Open a conversation showing its most recent activity.
                isPinnedToBottom = true
                proxy.scrollTo("bottom", anchor: .bottom)

                // Message bodies are laid out asynchronously, so the first
                // scroll can land before the content has its full height.
                // Settle once more after that work has had a chance to run.
                try? await Task.sleep(for: .milliseconds(150))
                guard isPinnedToBottom else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onOpenURL { url in
                if let suggestion = url.queryParameters["suggestion"] {
                    handleSubmit(suggestion.replacingOccurrences(of: "+", with: " "))
                }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    func handleSubmit(_ prompt: String) {
        conversationViewModel.submit(chat: prompt)
    }
}

/// Wrapper for scrolling message views. Using a `List` has much better scrolling performance on macOS.
/// On iOS the `List` studders when text is streaming and the scroll position is updated.
struct MessageListScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS)
        List {
            content()
                .listRowSeparator(.hidden)
                .listRowInsets(.init(top: 6, leading: 0, bottom: 6, trailing: 0))
        }
        .scrollClipDisabled()
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        #else
        ScrollView {
            content()
        }
        .scrollClipDisabled()
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        #endif
    }
}
