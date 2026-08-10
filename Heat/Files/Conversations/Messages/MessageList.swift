import SwiftUI
import SharedKit
import HeatKit

struct MessageList: View {
    @Environment(AppState.self) var state
    @Environment(ConversationViewModel.self) var conversationViewModel

    /// Whether new content should keep pulling the view to the newest message.
    ///
    /// This tracks intent rather than position. Position alone can't separate
    /// the reader's scrolling from ours: any threshold loose enough to absorb
    /// the content growing also becomes a band where a small scroll up is
    /// undone by the very next token, which feels like the view fighting back.
    /// Scrolling *up* is something only the reader does — following never
    /// moves anywhere but toward the end — so that's what stops it.
    @State private var isFollowing = true

    /// Sub-pixel drift and re-layout can nudge the offset; a real scroll
    /// gesture moves considerably further than this.
    private let scrollUpTolerance: CGFloat = 4

    /// How close to the end still counts as being at the end, for resuming.
    private let endThreshold: CGFloat = 16

    /// Distance from the end as of the last scroll geometry change. Negative
    /// while the view is rubber-banded past the end.
    @State private var distanceFromEnd: CGFloat = 0

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var distanceFromEnd: CGFloat
    }

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
                    // Assistant typing indicator when processing
                    if conversationViewModel.conversation.state == .processing {
                        TypingIndicator()
                    }

                    // Suggestions typing indicator when suggesting
                    if conversationViewModel.conversation.state == .suggesting {
                        TypingIndicator(foregroundColor: .accentColor)
                    }

                    // Show suggestions when they are available
                    if !conversationViewModel.suggestions.isEmpty {
                        SuggestionList(suggestions: conversationViewModel.suggestions) { suggestion in
                            SuggestionView(suggestion: suggestion) { handleSubmit($0) }
                        }
                    }
                }
                .id("bottom")
            }
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                ScrollState(
                    offset: geometry.contentOffset.y,
                    distanceFromEnd: geometry.contentSize.height
                        - (geometry.contentOffset.y + geometry.containerSize.height)
                )
            } action: { old, new in
                distanceFromEnd = new.distanceFromEnd

                if new.offset < old.offset - scrollUpTolerance {
                    // Moving up is the reader's doing; leave the view put.
                    isFollowing = false
                } else if new.distanceFromEnd <= endThreshold {
                    // Back at the newest content, so resume following it.
                    isFollowing = true
                }
            }
            .onChange(of: conversationViewModel.file.modified) { _, _ in
                guard isFollowing else { return }

                // While the view is rubber-banded past the end there is
                // nothing below to follow, and scrolling would cancel the
                // bounce mid-flight — which reads as the view juddering.
                // Let it settle; following resumes on the next token.
                guard distanceFromEnd >= 0 else { return }

                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .task(id: conversationViewModel.file.id) {
                // Open a conversation showing its most recent activity.
                isFollowing = true
                proxy.scrollTo("bottom", anchor: .bottom)

                // Message bodies are laid out asynchronously, so the first
                // scroll can land before the content has its full height.
                // Settle once more after that work has had a chance to run.
                try? await Task.sleep(for: .milliseconds(150))
                guard isFollowing else { return }
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
        Task {
            do {
                try await conversationViewModel.generate(chat: prompt)
            } catch {
                print(error)
            }
        }
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
