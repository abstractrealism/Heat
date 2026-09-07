import SwiftUI
import SharedKit
import GenKit
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

        /// How many upward offset moves in a row, counted so a lone one can
        /// be ignored. Textual re-settles text at slightly different heights
        /// *across frames* — height shrinks a few points in one geometry
        /// event, the offset follows in the next — and that second event is
        /// indistinguishable from a small reader scroll on its own numbers.
        /// It is distinguishable in aggregate: a settle is one isolated blip
        /// amid growth, while a reader's gesture delivers a run of upward
        /// events. So one upward move is layout until a second follows it.
        var upwardMoves = 0
    }

    @State private var scroll = ScrollIntent()

    /// Which runs are rendered for real. Everything else reserves its height.
    ///
    /// This *is* `@State`, unlike the scroll bookkeeping, because what's drawn
    /// depends on it. That's also why it must change as rarely as possible: it
    /// is recomputed on every scroll event but only assigned when the span
    /// actually differs, so a scroll within the overscan redraws nothing.
    ///
    /// Nil until the view has been scrolled, when `RunWindow.tail` stands in.
    /// It cannot simply start wide and narrow later: the geometry handler
    /// can't run until the list has been laid out once, and that lay-out is
    /// the entire cost being avoided.
    @State private var renderWindow: RunWindow?

    /// The conversation whose opening scroll has finished.
    ///
    /// Until it has, scroll geometry does not get to choose the window. A
    /// transcript is laid out from the top and only then scrolled to its
    /// newest message, so the geometry during that stretch describes the top
    /// of the conversation — and acting on it built six runs nobody was going
    /// to look at, before building the one they were.
    @State private var openedFileID: String?

    #if os(macOS)
    /// The scroll the AppKit transcript has been asked for. Carries the moment
    /// it was asked, so the same destination twice is two requests.
    @State private var scrollRequest: TranscriptScroll?
    #endif

    /// The runs to build now — what scrolling last decided, or the tail of the
    /// conversation before anything has scrolled.
    private var window: RunWindow {
        renderWindow ?? RunWindow.tail(
            runs: conversationViewModel.runs,
            heights: conversationViewModel.runHeights
        )
    }

    /// Sub-pixel drift and re-layout can nudge the offset; a real scroll
    /// gesture moves considerably further than this.
    private let scrollUpTolerance: CGFloat = 4

    /// How close to the end still counts as being at the end, for resuming.
    ///
    /// Following leaves the view about 10 points short — padding below the last
    /// row rather than content out of sight — so this has to clear that, and
    /// has 6 points to spare. Anything that adds height below the final row
    /// eats into that margin, and once the resting figure passes this the view
    /// stops counting as being at the end at all: following would never resume
    /// after a scroll up.
    private let endThreshold: CGFloat = 16

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var distanceFromEnd: CGFloat

        /// Carried so an offset change can be told apart from a layout change.
        /// See the scroll geometry handler.
        var contentHeight: CGFloat

        /// The viewport, for working out which runs fall inside it.
        var viewportHeight: CGFloat

        /// Width invalidates measured heights, since how tall a message is
        /// depends on how wide it may run.
        var viewportWidth: CGFloat
    }

    var body: some View {
        #if os(macOS)
        appKitBody
        #else
        swiftUIBody
        #endif
    }

    #if os(macOS)
    /// The transcript laid out by hand — see `TranscriptView` for why.
    ///
    /// Following is the coordinator's own business, not this view's. It was
    /// handed in at first, from the same box the SwiftUI path uses — and that
    /// box is deliberately not observable, so writing to it never re-renders
    /// and the value never arrived. See `TranscriptCoordinator.isFollowing`.
    private var appKitBody: some View {
        TranscriptView(
            runs: conversationViewModel.runs,
            heights: conversationViewModel.runHeights,
            conversationID: conversationViewModel.file.id,
            revision: conversationViewModel.file.modified,
            // Find changes what matching messages draw without touching the
            // conversation, so the transcript has to be told separately.
            findQuery: conversationViewModel.isFinding ? conversationViewModel.findQuery : nil,
            scrollRequest: scrollRequest,
            content: { run in
                AnyView(
                    RunView(run)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(state)
                        .environment(conversationViewModel)
                )
            },
            footer: {
                AnyView(
                    statusFooter
                        .environment(state)
                        .environment(conversationViewModel)
                )
            },
            onUserScroll: {
                // The coordinator only reports scrolling it didn't cause, so
                // this is always the reader.
                scroll.isFollowing = false
            }
        )
        .onChange(of: conversationViewModel.currentFindRunID) { _, runID in
            guard let runID else { return }
            scroll.isFollowing = false
            scrollRequest = TranscriptScroll(destination: .run(runID), requestedAt: .now)
        }
        .onChange(of: conversationViewModel.messages.count) { _, _ in
            // Sending is an explicit act: go to the newest message and follow
            // again. Only for messages the reader sent.
            guard conversationViewModel.messages.last?.role == .user else { return }
            scroll.isFollowing = true
            scrollRequest = TranscriptScroll(destination: .bottom, requestedAt: .now)
        }
        .task(id: conversationViewModel.file.id) {
            guard conversationViewModel.currentFindMessageID == nil else { return }
            scroll.isFollowing = true
            scrollRequest = TranscriptScroll(destination: .bottom, requestedAt: .now)
        }
        .onOpenURL { url in
            if let suggestion = url.queryParameters["suggestion"] {
                handleSubmit(suggestion.replacingOccurrences(of: "+", with: " "))
            }
            scrollRequest = TranscriptScroll(destination: .bottom, requestedAt: .now)
        }
    }
    #endif

    private var swiftUIBody: some View {
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
                ForEach(Array(conversationViewModel.runs.enumerated()), id: \.element.id) { index, run in
                    // The newest run is always built, wherever the view is
                    // scrolled: it's where a streaming answer is written, and
                    // reserving space for it would leave the answer invisible
                    // as it arrived.
                    if window.contains(index) || index == conversationViewModel.runs.count - 1 {
                        RunView(run)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Floored at what it last measured, so the row can
                            // never report less than it already has.
                            //
                            // The content height was seen collapsing from
                            // 19,840 to 8,466 and back while scrolling, with
                            // every run rendered and no placeholders involved —
                            // the list under-reports rows it hasn't settled.
                            // An offset that was valid against the taller
                            // figure is past the end of the shorter one, and
                            // clamping it to the end is the view being yanked
                            // to the bottom.
                            //
                            // Measured *inside* the pin, so what's recorded is
                            // what the content wants rather than what it has
                            // been given — otherwise the pin would freeze the
                            // first measurement and never learn it was wrong.
                            .reportingHeight(of: run.id, into: conversationViewModel.runHeights)
                            // Pinned to the tallest this run has measured, so
                            // rebuilding it cannot change the content's height.
                            //
                            // The list recycles rows as it scrolls — its own
                            // virtualization, under ours — and a rebuilt row
                            // reports a different height while its content
                            // settles, which is why the height dips line up
                            // exactly with the parse lines in the log. Pinning
                            // takes that out of the total: the content size
                            // becomes the sum of numbers we chose, so it cannot
                            // collapse, and an offset can never be left past
                            // the end.
                            .frame(height: pinnedHeight(for: run, at: index), alignment: .top)
                            .id(run.id)
                    } else {
                        // Off screen: reserve what it measured and draw
                        // nothing. The row still exists and still carries its
                        // id, so the list's total height stays honest and find
                        // can still scroll to it — it renders for real by the
                        // time the scroll lands.
                        Color.clear
                            .frame(height: conversationViewModel.runHeights.height(for: run))
                            .id(run.id)
                    }

                    // Drawn after the run it falls in, so everything above it
                    // is what the model no longer reads.
                    if run.id == conversationViewModel.compactedThroughRunID {
                        ContextBoundaryView(summary: conversationViewModel.conversation.contextSummary)
                    }
                }

                statusFooter
                    .id("bottom")
            }
            // The find query reaches renderers per message, from MessageView —
            // set here it changed for every message on every keystroke, and
            // every StructuredText rebuilt each time.
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                ScrollState(
                    offset: geometry.contentOffset.y,
                    // The bottom inset counts as content the view can still
                    // travel over. The message field sits in a bottom
                    // `safeAreaInset`, which is inside `containerSize` but
                    // outside `contentSize` — so without it this reads short by
                    // the height of the field, and sitting exactly at the end
                    // measures as 82 points *past* it.
                    distanceFromEnd: geometry.contentSize.height + geometry.contentInsets.bottom
                        - (geometry.contentOffset.y + geometry.containerSize.height),
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height,
                    viewportWidth: geometry.containerSize.width
                )
            } action: { old, new in
                scroll.distanceFromEnd = new.distanceFromEnd

                // Which runs are worth rendering, recomputed here because the
                // answer depends only on the offset and the heights already
                // recorded — no measuring involved. Assigned only when the
                // span really changes, so scrolling inside the overscan costs
                // nothing.
                conversationViewModel.runHeights.noteViewport(width: new.viewportWidth)

                // Only once this conversation has finished opening: see
                // `openedFileID`. The tail window stands until then.
                guard openedFileID == conversationViewModel.file.id else { return }

                let computed = RunWindow.around(
                    offset: new.offset,
                    viewportHeight: new.viewportHeight,
                    runs: conversationViewModel.runs,
                    heights: conversationViewModel.runHeights
                )
                // Grown into, never shrunk back — and the reason is not the one
                // this rule was first written for.
                //
                // The window is computed from the offset, and what the window
                // renders changes the offset, so allowing it to narrow closes a
                // loop: the log caught it alternating between 7…13 at offset
                // 6038 and 5…11 at offset 4828, seven times in two seconds,
                // re-parsing rows on every cycle. A window that cannot shrink
                // cannot cycle. What it costs is reclaiming the memory of a run
                // scrolled past.
                let grown = window.union(computed)
                if grown != renderWindow {
                    renderWindow = grown
                }

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

                // A same-event height check isn't enough on its own. Textual
                // splits a re-settle across frames — height shrank 7 points in
                // one event, the offset followed it down in the *next*, where
                // the height was already equal again — so the second frame
                // passes the check and reads as a 7-point reader scroll. Hence
                // the counter: see its declaration.
                if contentSettled, new.offset < old.offset - scrollUpTolerance {
                    scroll.upwardMoves += 1
                } else {
                    scroll.upwardMoves = 0
                }

                if scroll.upwardMoves >= 2 {
                    // A run of upward moves is the reader's doing; leave the
                    // view put. (A reader's gesture trips this on its second
                    // event, one frame in — an isolated settle never does.)
                    scroll.isFollowing = false
                } else if new.distanceFromEnd <= endThreshold {
                    // Back at the newest content, so resume following it.
                    scroll.isFollowing = true
                } else if scroll.isFollowing, conversationViewModel.isGenerating,
                          new.contentHeight > old.contentHeight,
                          new.distanceFromEnd > endThreshold {
                    // The content just grew while following, and the view is
                    // now more than a line behind. Catch up from here rather
                    // than waiting for the next publish tick: this event fires
                    // *after* layout, so the scroll lands on sizes that are
                    // already true — the tick handler was landing one
                    // line-growth late, leaving the current line half below
                    // the fold, and lumps of growth arriving at once left it
                    // far below.
                    //
                    // On growth *only*. Textual re-flows the live message on a
                    // cadence — height dips ~12 points and then grows as a
                    // paragraph's trailing edge streams — and scrolling on the
                    // dips slammed the view flush against the end each time,
                    // amplifying a 12-point content flap into a 30-point
                    // scroll flap. Shrinks are left for the next growth to
                    // absorb.
                    //
                    // And only while generating. A thread *opening* fits the
                    // other conditions perfectly — following starts true and
                    // the height grows in steps as rows are measured — so this
                    // was scrolling on every step, each scroll forcing more
                    // rows to lay out, which grew the height, which fired the
                    // next event: a feedback loop that made opening a thread
                    // take half a second. The catch-up exists for streaming
                    // lag; streaming is when it runs.
                    proxy.scrollTo("bottom", anchor: .bottom)
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
                guard scroll.isFollowing else { return }

                // While the view is rubber-banded past the end there is
                // nothing below to follow, and scrolling would cancel the
                // bounce mid-flight — which reads as the view juddering.
                // Let it settle; following resumes on the next token.
                //
                // This depends entirely on the measurement above being honest.
                // While it read short by the height of the message field,
                // sitting at the end looked like being 82 points past it, so
                // this rejected every follow until that much new text had
                // arrived — the view moved in steps of three or four lines with
                // the newest one below the fold in between.
                guard scroll.distanceFromEnd >= 0 else { return }

                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .task(id: conversationViewModel.file.id) {
                // A different conversation opens at its own tail, rather than
                // wherever the last one had been scrolled to — and geometry
                // doesn't get a say until the opening scroll has landed.
                let openingFileID = conversationViewModel.file.id
                renderWindow = nil
                openedFileID = nil
                defer { openedFileID = openingFileID }

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

                await measureRemainingRuns(proxy: proxy)
            }
            .onOpenURL { url in
                if let suggestion = url.queryParameters["suggestion"] {
                    handleSubmit(suggestion.replacingOccurrences(of: "+", with: " "))
                }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// What sits after the last run: any error, what the model is doing, and
    /// the suggestions when they arrive.
    ///
    /// Its own view so both hosts can show it — SwiftUI puts it in the list as
    /// the "bottom" row, AppKit measures and positions it after the runs.
    @ViewBuilder
    private var statusFooter: some View {
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
                // Also the way to close the reasoning above it. Its own Hide
                // control scrolls off the top as the block grows, so this is
                // the one part of it that stays in reach.
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

            // Suggestions, or a note that they're on their way, in the place
            // they'll appear
            if conversationViewModel.phase == .suggesting {
                GeneratingIndicator("Generating suggestions", alignment: .trailing)
            } else if !conversationViewModel.suggestions.isEmpty {
                SuggestionList(suggestions: conversationViewModel.suggestions) { suggestion in
                    SuggestionView(suggestion: suggestion) { handleSubmit($0) }
                }
            }
        }
    }

    /// The height a run is held at, being the tallest it has measured.
    ///
    /// Nothing while a turn is generating: the newest run is where the answer
    /// is being written, so its height is supposed to change, and holding it
    /// at what it measured a moment ago would fight every token.
    ///
    /// Only *while generating*, though. Exempting the newest run at all times
    /// left the largest row in the conversation free to move, and it was the
    /// whole of the remaining wobble — the content sat perfectly still for
    /// stretches and then dipped by two thousand points, which is the size of
    /// that one message.
    private func pinnedHeight(for run: Run, at index: Int) -> CGFloat? {
        let isNewest = index == conversationViewModel.runs.count - 1
        if isNewest, conversationViewModel.isGenerating { return nil }
        return conversationViewModel.runHeights.measuredHeight(for: run.id)
    }

    /// Builds the rest of the conversation a few runs at a time, once the
    /// newest ones are on screen.
    ///
    /// Scrolling up used to jump, and this is why: a run reserved at an
    /// *estimated* height and then built at its real one changes the height of
    /// everything above the reader, and the scroll offset is measured from the
    /// top — so the content under the cursor slides out from under it. The
    /// estimates run low, so each run scrolled into grows and shoves the reader
    /// further up. It settled only at the top of the thread, because by then
    /// everything had been measured.
    ///
    /// Better estimates would only make the jump smaller. What removes it is
    /// having measured everything before the reader arrives — the same trick a
    /// browser plays when a fast scroll shows blank space that fills in a
    /// moment later. The work is the same as it ever was; it just happens after
    /// the first paint rather than before it, which is the difference between
    /// a slow open and none at all.
    ///
    /// Batched with a breath between, so the main thread stays answerable
    /// rather than blocking for a second while somebody reads.
    private func measureRemainingRuns(proxy: ScrollViewProxy) async {
        let total = conversationViewModel.runs.count
        var lower = window.lowerBound

        while lower > 0 {
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }

            // A turn in flight owns the view: growing the content above the
            // newest message while it's being written is exactly the fight
            // that made the whole message bob.
            guard !conversationViewModel.isGenerating else { return }

            // The reader has scrolled somewhere of their own accord; leave the
            // window to the scroll geometry from here.
            guard scroll.isFollowing else { return }

            lower = max(0, lower - 2)
            renderWindow = RunWindow(lowerBound: lower, upperBound: total - 1)

            // The content just grew above the reader, so put them back where
            // they were. They're at the newest message — that's what
            // `isFollowing` means here — so the bottom is where they were.
            proxy.scrollTo("bottom", anchor: .bottom)
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
        // Initial position only. Unscoped, the anchor also applies to *size
        // changes*: the scroll view re-pins the bottom edge whenever the
        // content's height moves, which is a second scroller fighting the
        // explicit follow logic. Every flap of a streaming message's height
        // moved the offset to hold the bottom still, so the whole view —
        // including the top of the message being written — visibly bobbed.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        #else
        ScrollView {
            content()
        }
        .scrollClipDisabled()
        .scrollDismissesKeyboard(.interactively)
        // Scoped for the same reason as macOS above.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        #endif
    }
}
