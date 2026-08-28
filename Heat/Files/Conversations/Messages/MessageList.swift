import SwiftUI
import SharedKit
import HeatKit

struct MessageList: View {
    @Environment(AppState.self) var state
    @Environment(ConversationViewModel.self) var conversationViewModel

    /// Scroll bookkeeping: whether to keep following the newest message, and
    /// how far from the end the view is. Read only inside handlers — nothing
    /// drawn depends on either value.
    ///
    /// That's why it's a box rather than two `@State` values. `@State` means
    /// "redraw when this changes", and `distanceFromEnd` changes on every
    /// frame of every scroll — so tracking the reader was re-rendering the
    /// entire conversation continuously while the view moved, re-parsing its
    /// markdown and re-highlighting its code, including during the automatic
    /// scrolls that run when a thread opens. Writing to a property of the box
    /// changes nothing SwiftUI watches: the reference stays the same, and the
    /// class is deliberately not `@Observable`.
    ///
    /// The box itself still lives in `@State` for its lifetime alone — a plain
    /// stored property would be a fresh box on every re-evaluation of the
    /// parent, forgetting that the reader had scrolled away, and this way it
    /// still resets with view identity exactly as the two values did.
    @MainActor
    private final class ScrollIntent {
        /// Whether new content should keep pulling the view to the newest
        /// message.
        ///
        /// This tracks intent rather than position. Position alone can't
        /// separate the reader's scrolling from ours: any threshold loose
        /// enough to absorb the content growing also becomes a band where a
        /// small scroll up is undone by the very next token, which feels like
        /// the view fighting back. Scrolling *up* is something only the reader
        /// does — following never moves anywhere but toward the end — so
        /// that's what stops it.
        var isFollowing = true

        /// Distance from the end as of the last scroll geometry change.
        /// Negative while the view is rubber-banded past the end.
        var distanceFromEnd: CGFloat = 0

        /// TEMPORARY — instrumentation for the follow cadence. See the
        /// `file.modified` handler.
        var lastGeometry = ScrollState(offset: 0, distanceFromEnd: 0, contentHeight: 0)
        var lastFollowLog = Date.distantPast
    }

    @State private var scroll = ScrollIntent()

    /// Sub-pixel drift and re-layout can nudge the offset; a real scroll
    /// gesture moves considerably further than this.
    private let scrollUpTolerance: CGFloat = 4

    /// How close to the end still counts as being at the end, for resuming.
    private let endThreshold: CGFloat = 16

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var distanceFromEnd: CGFloat

        /// Carried so an offset change can be told apart from a layout change.
        /// See the scroll geometry handler.
        var contentHeight: CGFloat

        /// TEMPORARY — instrumentation only. Whether `contentHeight` already
        /// accounts for the space the message field takes at the bottom
        /// decides whether `distanceFromEnd` reads zero at the end or short
        /// by the height of the field.
        var containerHeight: CGFloat = 0
        var insetBottom: CGFloat = 0
    }

    var body: some View {
        ScrollViewReader { proxy in
            MessageListScrollView {

                // Each run is a row of its own rather than all of them inside
                // one, because **only a list's rows are scroll anchors**. An
                // `.id()` nested inside a row cannot be reached, however
                // explicitly it's named — which is why find scrolled nowhere
                // while "bottom" below, a row, always worked.
                //
                // The spacing is unchanged: the 12 points the enclosing stack
                // used to provide are the 6 above and 6 below that
                // MessageListScrollView already gives every row.
                ForEach(conversationViewModel.runs) { run in
                    RunView(run)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(run.id)

                    // Drawn after the run it falls in, so everything above it
                    // is what the model no longer reads.
                    if run.id == conversationViewModel.compactedThroughRunID {
                        ContextBoundaryView(summary: conversationViewModel.conversation.contextSummary)
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
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height,
                    insetBottom: geometry.contentInsets.bottom
                )
            } action: { old, new in
                scroll.distanceFromEnd = new.distanceFromEnd
                scroll.lastGeometry = new

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
                    scroll.isFollowing = false
                } else if new.distanceFromEnd <= endThreshold {
                    // Back at the newest content, so resume following it.
                    scroll.isFollowing = true
                }
            }
            .onChange(of: conversationViewModel.currentFindMessageID) { _, message in
                // Scrolled to by run rather than by message: the run is the
                // row, and a row is the only thing a list can be scrolled to.
                // The message is still what gets marked, so stepping between
                // two matches in one run moves the highlight without moving
                // the view, which is right — it's already on screen.
                guard message != nil, let match = conversationViewModel.currentFindRunID else { return }
                // Following is switched off first: bringing a match into view
                // is a move away from the newest message, which is exactly
                // what following would undo.
                scroll.isFollowing = false
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(match, anchor: .center)
                }
                // Again once the messages have laid out. Arriving from a
                // search result asks for this while the conversation is still
                // being measured, and a scroll into a view that has no height
                // yet lands nowhere.
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard conversationViewModel.currentFindRunID == match else { return }
                    proxy.scrollTo(match, anchor: .center)
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
                scroll.isFollowing = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversationViewModel.file.modified) { _, _ in
                #if DEBUG
                // TEMPORARY. Following is driven from here, ten times a second
                // while a turn streams, and the guard below is what decides
                // whether each of those actually moves the view. Logged at four
                // a second so the cadence is readable rather than a wall.
                if Date().timeIntervalSince(scroll.lastFollowLog) >= 0.25 {
                    scroll.lastFollowLog = .now
                    let g = scroll.lastGeometry
                    let numbers = String(
                        format: "content %.1f | offset %.1f | container %.1f | insetBottom %.1f | distance %.1f",
                        Double(g.contentHeight), Double(g.offset), Double(g.containerHeight),
                        Double(g.insetBottom), Double(g.distanceFromEnd)
                    )
                    let acted = scroll.isFollowing
                        ? (scroll.distanceFromEnd >= 0 ? "scrolls" : "SKIPPED — reads as past the end")
                        : "not following"
                    ChatDebug.log("follow | \(numbers) | \(acted)")
                }
                #endif

                guard scroll.isFollowing else { return }

                // While the view is rubber-banded past the end there is
                // nothing below to follow, and scrolling would cancel the
                // bounce mid-flight — which reads as the view juddering.
                // Let it settle; following resumes on the next token.
                guard scroll.distanceFromEnd >= 0 else { return }

                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .task(id: conversationViewModel.file.id) {
                // Unless a find is already pointing somewhere. Arriving from a
                // search result is arriving *at* a match, and opening at the
                // newest message would scroll straight past it — including the
                // settling pass below, which lands after the match scroll and
                // would undo it.
                guard conversationViewModel.currentFindMessageID == nil else { return }

                // Open a conversation showing its most recent activity.
                scroll.isFollowing = true
                proxy.scrollTo("bottom", anchor: .bottom)

                // Message bodies are laid out asynchronously, so the first
                // scroll can land before the content has its full height.
                // Settle once more after that work has had a chance to run.
                try? await Task.sleep(for: .milliseconds(150))
                guard scroll.isFollowing else { return }
                guard conversationViewModel.currentFindMessageID == nil else { return }
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
