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

        /// Carried so an offset change can be told apart from a layout change.
        /// See the scroll geometry handler.
        var contentHeight: CGFloat
    }

    var body: some View {
        ScrollViewReader { proxy in
            MessageListScrollView {

                // Show message run history
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(conversationViewModel.runs) { run in
                        RunView(run)
                        // Drawn after the run it falls in, so everything above
                        // it is what the model no longer reads.
                        if run.id == conversationViewModel.compactedThroughRunID {
                            ContextBoundaryView(summary: conversationViewModel.conversation.contextSummary)
                        }
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
                        GeneratingIndicator("Generating" + liveRateSuffix)
                    case .thinking:
                        // Also the way to close the reasoning above it. Its own
                        // Hide control scrolls off the top as the block grows,
                        // so this is the one part of it that stays in reach.
                        Button {
                            conversationViewModel.isStreamingThinkingExpanded.toggle()
                        } label: {
                            GeneratingIndicator("Thinking" + liveRateSuffix)
                        }
                        .buttonStyle(.plain)
                        .help(conversationViewModel.isStreamingThinkingExpanded
                              ? "Hide the reasoning above"
                              : "Show the reasoning above")
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
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                ScrollState(
                    offset: geometry.contentOffset.y,
                    distanceFromEnd: geometry.contentSize.height
                        - (geometry.contentOffset.y + geometry.containerSize.height),
                    contentHeight: geometry.contentSize.height
                )
            } action: { old, new in
                distanceFromEnd = new.distanceFromEnd

                // Only when the content stayed the same size. Text that is
                // still being laid out settles at slightly different heights
                // as it goes, and each settle moves the offset — which read as
                // the reader scrolling up, so following switched off, and
                // stayed off until the view happened to end up near the bottom
                // again. That is the stutter while a model thinks: reasoning is
                // markdown being re-parsed on every update, so it wobbles far
                // more than a plain answer does, and following was being turned
                // off and on throughout.
                let contentSettled = new.contentHeight == old.contentHeight

                if contentSettled, new.offset < old.offset - scrollUpTolerance {
                    // Moving up is the reader's doing; leave the view put.
                    isFollowing = false
                } else if new.distanceFromEnd <= endThreshold {
                    // Back at the newest content, so resume following it.
                    isFollowing = true
                }
            }
            .onChange(of: conversationViewModel.messages.count) { _, _ in
                // Sending is an explicit act, so bring the new prompt and the
                // status below it into view and start following again. Only
                // for messages the reader sent: an answer arriving shouldn't
                // move the view out from under someone reading further up.
                //
                // Appending a message doesn't touch file.modified, so the
                // follow below never saw a send at all.
                guard conversationViewModel.messages.last?.role == .user else { return }
                isFollowing = true
                proxy.scrollTo("bottom", anchor: .bottom)
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

    /// The running rate, once there's been long enough to mean anything. The
    /// service's own count only lands when the response is finished, so this
    /// stands in until the figures underneath the message replace it.
    private var liveRateSuffix: String {
        guard let rate = conversationViewModel.liveTokensPerSecond else { return "" }
        return String(format: " · %.0f tok/s", rate)
    }

    func handleSubmit(_ prompt: String) {
        conversationViewModel.submit(chat: prompt)
    }
}

/// Wrapper for scrolling message views. Using a `List` has much better scrolling performance on macOS.
/// On iOS the `List` studders when text is streaming and the scroll position is updated.
/// Marks where the model's view of the conversation begins.
///
/// Visible on purpose. Compaction is lossy, so the failure it invites is
/// assuming the model still remembers something it was only ever told in
/// summary — and that's much easier to reason about when you can see the line
/// and read what was kept.
struct ContextBoundaryView: View {
    let summary: String?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                line
                Button {
                    if summary != nil { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: summary == nil ? "eraser" : "arrow.down.right.and.arrow.up.left")
                        Text(summary == nil ? "Context cleared" : "Context compacted")
                        if summary != nil {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(summary == nil)
                line
            }

            if isExpanded, let summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
        .help(summary == nil
              ? "Messages above this line are no longer sent to the model. They stay in the conversation."
              : "Messages above this line are no longer sent to the model — it's given these notes instead. They stay in the conversation.")
    }

    private var line: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
    }
}

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
