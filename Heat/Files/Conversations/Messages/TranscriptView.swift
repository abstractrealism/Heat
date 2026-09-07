#if os(macOS)
import SwiftUI
import AppKit
import GenKit
import HeatKit

/// The transcript, laid out by hand in an `NSScrollView`.
///
/// Everything else in this app is SwiftUI, so this wants a reason. Five
/// attempts were made to keep a `List` steady while scrolling a long
/// conversation, and each found something real without fixing it: the content
/// size moves while the list recycles rows, an offset that was valid against
/// the taller figure is past the end of the shorter one, and clamping an offset
/// to the end is the view being yanked to the bottom.
///
/// None of that is fixable from inside SwiftUI, because the content size isn't
/// ours. Here it is: the document view is exactly as tall as the heights we
/// choose, and — the part that matters — when a row above the reader turns out
/// to be a different height than assumed, **the scroll origin is moved by the
/// same amount in the same pass**, so what's on screen doesn't shift. That is
/// the one thing a `List` gave no way to say, and it's what the jumping was.
///
/// iOS keeps the SwiftUI path. It uses a `ScrollView` rather than a `List` and
/// has never shown these symptoms.
struct TranscriptView: NSViewRepresentable {

    let runs: [Run]
    let heights: RunHeightCache

    /// Which conversation these runs belong to, so the coordinator can tell a
    /// new transcript from another message arriving in this one.
    let conversationID: String

    /// Rebuilt whenever this changes, so a streaming answer redraws.
    let revision: Date

    /// Bumped to ask for a scroll; the coordinator acts on a change, so the
    /// same request twice in a row is two scrolls.
    let scrollRequest: TranscriptScroll?

    /// Builds a run's view. Held rather than called eagerly: a run outside the
    /// viewport is never built at all.
    let content: (Run) -> AnyView

    /// What sits after the last run — the generating indicator, suggestions,
    /// and any error.
    let footer: () -> AnyView

    /// Told when the reader scrolls, so following can stand down.
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed

        let document = TranscriptDocumentView()
        document.autoresizingMask = [.width]
        scrollView.documentView = document

        context.coordinator.attach(to: scrollView, document: document)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            runs: runs,
            heights: heights,
            conversationID: conversationID,
            revision: revision,
            scrollRequest: scrollRequest,
            content: content,
            footer: footer,
            onUserScroll: onUserScroll
        )
    }

    func makeCoordinator() -> TranscriptCoordinator {
        TranscriptCoordinator()
    }
}

/// What to scroll to, and when it was asked for.
struct TranscriptScroll: Equatable {
    enum Destination: Equatable {
        case bottom

        /// A run, and roughly how far down it to aim — 0 for its top, 1 for
        /// its bottom, nil to centre the run itself.
        case run(String, fraction: Double?)
    }
    var destination: Destination
    var requestedAt: Date
}

/// Flipped, so a row's y grows downwards and the arithmetic reads the way the
/// conversation does — the first run at the top.
final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Positions the rows, keeps the document as tall as their heights, and holds
/// the reader still when a height turns out to be wrong.
@MainActor
final class TranscriptCoordinator: NSObject {

    private weak var scrollView: NSScrollView?
    private weak var document: TranscriptDocumentView?

    private var runs: [Run] = []
    private var heights: RunHeightCache?
    private var content: ((Run) -> AnyView)?
    private var footerBuilder: (() -> AnyView)?
    private var onUserScroll: (() -> Void)?

    /// Hosting views for the runs currently built, by run id.
    private var hosted: [String: RunHostingView] = [:]

    /// The footer is always built: it holds what the model is doing, and that
    /// is the one thing somebody waiting is looking at.
    private var footerView: NSHostingView<AnyView>?

    private var lastRevision: Date?
    private var lastScrollRequest: TranscriptScroll?

    /// Whether new content should pull the view along with it.
    ///
    /// Worked out here rather than handed in, and that distinction was a bug
    /// worth a day. `MessageList` holds this in a deliberately non-observable
    /// box, so that tracking the scroll doesn't re-render the conversation —
    /// which is right, and which means writing to it never reaches SwiftUI.
    /// Passed through a view's value semantics it therefore never updated:
    /// the reader scrolled away, nothing re-rendered, and this stayed true
    /// for the life of the conversation. Every row that settled taller
    /// afterwards then read it and scrolled the reader back to the end.
    ///
    /// The scroll view already says everything needed to know the answer, so
    /// it is asked directly.
    private var isFollowing = true

    /// How close to the end still counts as being at it.
    private let followThreshold: CGFloat = 16

    /// Set while the coordinator is moving the scroll origin itself, so its own
    /// scrolling isn't mistaken for the reader's.
    private var isAdjustingScroll = false

    /// Set while laying out, since measuring a row can make it report a new
    /// height, which asks for another layout from inside this one.
    private var isLayingOut = false

    private var lastConversationID: String?

    /// Whether this conversation has been put at its end yet. See `update`.
    private var hasOpenedAtEnd = false

    /// Whether the reader's hand is on the scroll right now.
    ///
    /// A scroll under way is AppKit's, and moving the origin from underneath it
    /// argues with the momentum it is carrying. See `rowHeightChanged`.
    private var isLiveScrolling = false

    /// A screen's worth beyond the viewport in each direction, so an ordinary
    /// scroll finds its rows already built.
    private let overscan: CGFloat = 1.5

    func attach(to scrollView: NSScrollView, document: TranscriptDocumentView) {
        self.scrollView = scrollView
        self.document = document

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        scrollView.postsFrameChangedNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollStarted),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollEnded),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
    }

    @objc private func liveScrollStarted(_ notification: Notification) {
        isLiveScrolling = true
    }

    @objc private func liveScrollEnded(_ notification: Notification) {
        isLiveScrolling = false
    }

    func update(
        runs: [Run],
        heights: RunHeightCache,
        conversationID: String,
        revision: Date,
        scrollRequest: TranscriptScroll?,
        content: @escaping (Run) -> AnyView,
        footer: @escaping () -> AnyView,
        onUserScroll: @escaping () -> Void
    ) {
        self.heights = heights
        self.content = content
        self.footerBuilder = footer
        self.onUserScroll = onUserScroll

        let runsChanged = self.runs.map(\.id) != runs.map(\.id)
        let revisionChanged = lastRevision != revision
        let openedNewConversation = lastConversationID != conversationID
        self.runs = runs
        lastRevision = revision
        lastConversationID = conversationID

        if runsChanged {
            // A run that has gone takes its view with it.
            let live = Set(runs.map(\.id))
            for (id, view) in hosted where !live.contains(id) {
                view.removeFromSuperview()
                hosted.removeValue(forKey: id)
            }
        }

        if revisionChanged {
            // The newest run is the one a streaming answer is written into, so
            // it is the one whose view has to be refreshed in place.
            if let newest = runs.last, let view = hosted[newest.id] {
                view.rootView = rootView(for: newest, width: view.builtAtWidth)
            }
            refreshFooter()
        }

        if openedNewConversation {
            hasOpenedAtEnd = false
        }

        // Not simply "on the first update for this conversation": that update
        // arrives before the scroll view has a width and often before the runs
        // have been read from disk, so opening at the end there did nothing and
        // marked the job done. It waits until there is something to open.
        // Opening at the end is `layoutRows`'s business now: it is the only
        // place that knows the scroll view has a width to work with.
        layoutRows()

        if let scrollRequest, scrollRequest != lastScrollRequest {
            lastScrollRequest = scrollRequest
            apply(scrollRequest)
        } else if isFollowing, revisionChanged {
            scrollToBottom()
        }
    }

    // MARK: - Layout

    /// Where each run starts, as the running sum of the heights before it.
    private func offsets() -> [CGFloat] {
        guard let heights else { return [] }
        var result: [CGFloat] = []
        result.reserveCapacity(runs.count)
        var position: CGFloat = 0
        for run in runs {
            result.append(position)
            position += heights.height(for: run) + Self.rowSpacing
        }
        return result
    }

    private static let rowSpacing: CGFloat = 12

    /// The gap between a message and the edge of the pane.
    ///
    /// A `List` supplies this itself and a hand-laid document does not, so
    /// without it every message sat flush against the sides — and code blocks,
    /// which deliberately bleed 12 points wider than the text, spilled past the
    /// pane entirely. That bleed is why this is 12: it puts a code block level
    /// with the edge while the prose stands in from it.
    private static let horizontalInset: CGFloat = 12

    /// Builds and positions the rows the viewport can see, and sizes the
    /// document to the whole conversation.
    ///
    /// Two passes, because a row's height is only known once it exists. The
    /// first decides which runs are near enough to be worth building, using
    /// whatever heights are held; each of those is then built and measured, so
    /// its height stops being a guess; and the second lays everything out from
    /// the corrected figures. Positioning from the first pass is what put
    /// messages on top of one another and left gaps under others — the numbers
    /// used to place a row were not the numbers it turned out to need.
    private func layoutRows() {
        guard let scrollView, let document, let heights, let content else { return }
        guard !isLayingOut else { return }

        let paneWidth = scrollView.contentSize.width
        let width = paneWidth - Self.horizontalInset * 2
        guard width > 0 else { return }

        isLayingOut = true
        defer { isLayingOut = false }

        heights.noteViewport(width: width)

        // Here rather than only in `update`, because the first update arrives
        // before the scroll view has been given a size — so the first layout
        // that can actually do anything comes from a frame-change notification,
        // with the scroll still at the top. That is what built a transcript's
        // opening runs before scrolling away from them.
        if !hasOpenedAtEnd, !runs.isEmpty {
            hasOpenedAtEnd = true
            openAtTheEnd()
        }

        let visible = scrollView.contentView.bounds
        let padding = visible.height * overscan
        let lower = visible.minY - padding
        let upper = visible.maxY + padding

        // Pass one: what is near enough to build.
        var believed = offsets()
        var wantedIndices: [Int] = []
        for (index, run) in runs.enumerated() {
            let top = believed[index]
            let height = heights.height(for: run)
            guard top + height >= lower, top <= upper else { continue }
            wantedIndices.append(index)
        }

        // Build each of them and take its real height.
        var wanted = Set<String>()
        for index in wantedIndices {
            let run = runs[index]
            wanted.insert(run.id)

            let view: RunHostingView
            if let existing = hosted[run.id] {
                view = existing
                // The content carries its own width, so a resized pane means
                // every built row has to be rebuilt at the new one.
                if abs(view.builtAtWidth - width) > 0.5 {
                    view.rootView = rootView(for: run, width: width)
                    view.builtAtWidth = width
                }
            } else {
                view = RunHostingView(rootView: rootView(for: run, width: width))
                view.runID = run.id
                view.builtAtWidth = width
                view.onHeightChange = { [weak self] id, newHeight in
                    self?.rowHeightChanged(id: id, to: newHeight)
                }
                hosted[run.id] = view
                document.addSubview(view)
            }
            heights.record(exact: Self.height(of: view, at: width), at: width, for: run.id)
        }

        // Rows well outside the viewport give their memory back. Unlike the
        // SwiftUI attempt this is safe: the document's height doesn't depend on
        // which rows exist, only on the heights we hold.
        for (id, view) in hosted where !wanted.contains(id) {
            view.removeFromSuperview()
            hosted.removeValue(forKey: id)
        }

        // Pass two: place everything against the corrected heights.
        believed = offsets()
        for index in wantedIndices {
            let run = runs[index]
            guard let view = hosted[run.id] else { continue }
            let frame = NSRect(
                x: Self.horizontalInset,
                y: believed[index],
                width: width,
                height: heights.height(for: run)
            )
            if view.frame != frame {
                view.frame = frame
            }
        }

        let contentHeight = (believed.last ?? 0)
            + (runs.last.map { heights.height(for: $0) } ?? 0)
        let footerHeight = layoutFooter(width: width, top: contentHeight)
        let totalHeight = contentHeight + footerHeight

        // The document is the full width of the pane; the rows stand in from
        // its edges.
        if abs(document.frame.height - totalHeight) > 0.5 || abs(document.frame.width - paneWidth) > 0.5 {
            document.frame = NSRect(x: 0, y: 0, width: paneWidth, height: totalHeight)
        }
    }

    private func layoutFooter(width: CGFloat, top: CGFloat) -> CGFloat {
        guard let document, let footerBuilder else { return 0 }

        let view: NSHostingView<AnyView>
        if let existing = footerView {
            view = existing
        } else {
            view = NSHostingView(rootView: footerBuilder())
            footerView = view
            document.addSubview(view)
        }
        let height = Self.height(of: view, at: width)
        view.frame = NSRect(x: Self.horizontalInset, y: top + Self.rowSpacing, width: width, height: height)
        return height + Self.rowSpacing
    }

    /// What a hosted view wants to be, at a given width.
    ///
    /// Setting the frame width is not enough on its own: `fittingSize` asks
    /// SwiftUI for its *ideal* size, and a paragraph's ideal is to run as wide
    /// as it likes and stand one line tall. That under-reports, and a row
    /// placed at an under-reported height is a row the next message rides up
    /// over. The width is fixed on the content itself — see
    /// `rootView(for:width:)` — so there is nothing left to be ideal about.
    /// Asked without forcing a layout pass.
    ///
    /// `fittingSize` and `layoutSubtreeIfNeeded` both lay the subtree out, and
    /// AppKit refuses that from inside a layout it is already doing — "not
    /// legal … this may break in the future". Since the content carries its own
    /// explicit width, its intrinsic size already answers the question, and
    /// asking that way is legal anywhere.
    static func height(of view: NSView, at width: CGFloat) -> CGFloat {
        if abs(view.frame.width - width) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        }
        let intrinsic = view.intrinsicContentSize.height
        if intrinsic > 0, intrinsic != NSView.noIntrinsicMetric { return intrinsic }
        return view.fittingSize.height
    }

    /// A run's content, pinned to the width it will be laid out at.
    private func rootView(for run: Run, width: CGFloat) -> AnyView {
        guard let content else { return AnyView(EmptyView()) }
        return AnyView(content(run).frame(width: width))
    }

    private func refreshFooter() {
        guard let footerBuilder else { return }
        footerView?.rootView = footerBuilder()
    }

    /// A row turned out to be a different height than was assumed for it.
    ///
    /// This is the whole reason for the class. If the row sits above what the
    /// reader is looking at, everything below it — including what's on screen —
    /// is about to move by the difference, so the scroll origin moves with it
    /// and the reader sees nothing at all. A `List` gave no way to say this,
    /// which is why every height correction there was a visible jump, and why a
    /// correction large enough to shorten the document past the current offset
    /// snapped the view to the bottom.
    private func rowHeightChanged(id: String, to newHeight: CGFloat) {
        guard let scrollView, let heights else { return }
        guard !isLayingOut else { return }
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }

        let previous = heights.height(for: runs[index])
        heights.record(exact: newHeight, at: scrollView.contentSize.width, for: id)
        let corrected = heights.height(for: runs[index])
        let delta = corrected - previous
        guard abs(delta) > 0.5 else { return }

        let starts = offsets()
        let rowTop = starts[index]
        let rowBottom = rowTop + previous
        let viewportTop = scrollView.contentView.bounds.minY

        layoutRows()

        // Following means the reader is at the newest message, so put them
        // back there. Rows settle taller a moment after a thread opens — a code
        // block finishing its highlighting, a picture arriving — and the
        // opening scroll was to the end of a document that has since grown,
        // which is why a thread sometimes opened a little short of the bottom
        // with the suggestions cut off.
        if isFollowing {
            scrollToBottom()
            return
        }

        // Otherwise only when the row lies *entirely* above the reader.
        //
        // A row below them growing makes the document taller without moving
        // anything they can see. A row they are inside is the interesting case
        // and was being got wrong: its text lays out downwards, so it grows
        // below the part being read, which hasn't moved — but shifting by the
        // whole delta assumed all of it had. One such row grew by 1,988 points
        // while being scrolled into, and carried the reader that far back down
        // for a change they could not see. Guessing "nothing moved" for a row
        // under the reader's eye is wrong less often, and wrong by less.
        guard rowBottom <= viewportTop else { return }

        // Not while the reader's hand is on it.
        //
        // A scroll under way belongs to AppKit, which is carrying momentum of
        // its own, and setting the origin from underneath that argues with it —
        // no arithmetic here is right enough to win. Letting the content shift
        // during a gesture is the lesser fault: a small slip while moving,
        // against a scroll that cannot make progress at all.
        guard !isLiveScrolling else { return }

        // Read the position again rather than reusing the one captured above.
        //
        // Building a row costs tens of milliseconds, and a reader mid-scroll
        // keeps moving throughout — so setting the origin back to where they
        // were before that work threw away everything they scrolled during it.
        // That is not a jump, it is their gesture being rewound, and it is why
        // scrolling up through a thread became impossible: every row built on
        // the way up undid the flick that reached it.
        let currentTop = scrollView.contentView.bounds.minY

        #if DEBUG
        // The only line left, and it earns its place: this is the one path in
        // here that has never been seen to run. Everything the compensation
        // does is for a row settling taller *above* a reader who is sitting
        // still, and testing has been scrolling to the top, where every row is
        // below. Until this prints, the code is unproven rather than working.
        ChatDebug.log(String(
            format: "↕ held still | row %d grew %.0f | %.0f → %.0f",
            index, Double(delta), Double(currentTop), Double(currentTop + delta)))
        #endif

        isAdjustingScroll = true
        let origin = NSPoint(x: 0, y: max(0, currentTop + delta))
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isAdjustingScroll = false
    }

    /// Puts the view at the end of the conversation before a single row is
    /// built.
    ///
    /// Rows are built from wherever the scroll happens to be, and a fresh
    /// scroll view is at the top — so opening a transcript built the *first*
    /// runs, then scrolled to the newest message and built those as well.
    /// Every one of the first lot was work nobody was going to look at, and it
    /// is the whole of the difference between a six hundred millisecond open
    /// and a second.
    ///
    /// The document is sized from the heights already held — measurements from
    /// a previous visit, estimates otherwise — and the origin put at its end,
    /// so the first layout builds the tail.
    private func openAtTheEnd() {
        guard let scrollView, let document, let heights else { return }
        let paneWidth = scrollView.contentSize.width
        guard paneWidth > 0 else { return }

        heights.noteViewport(width: paneWidth - Self.horizontalInset * 2)

        var total: CGFloat = 0
        for run in runs {
            total += heights.height(for: run) + Self.rowSpacing
        }

        document.frame = NSRect(x: 0, y: 0, width: paneWidth, height: total)
        isAdjustingScroll = true
        scrollView.contentView.setBoundsOrigin(
            NSPoint(x: 0, y: max(0, total - scrollView.contentSize.height))
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isAdjustingScroll = false
    }

    // MARK: - Scrolling

    private func apply(_ request: TranscriptScroll) {
        switch request.destination {
        case .bottom:
            scrollToBottom()
        case .run(let id, let fraction):
            scrollToRun(id, fraction: fraction)
        }
    }

    private func scrollToBottom() {
        guard let scrollView, let document else { return }
        // Going to the end is what following means, so it starts again here.
        isFollowing = true
        let maxY = max(0, document.frame.height - scrollView.contentSize.height)
        isAdjustingScroll = true
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isAdjustingScroll = false
        layoutRows()
    }

    private func scrollToRun(_ id: String, fraction: Double?) {
        guard let scrollView, let index = runs.firstIndex(where: { $0.id == id }) else { return }
        // Going to a match is going away from the end.
        isFollowing = false
        let starts = offsets()
        let height = heights?.height(for: runs[index]) ?? 0
        let viewport = scrollView.contentSize.height

        let target: CGFloat
        if let fraction, height > viewport {
            // The run is taller than the view, so which part of it matters.
            // Aiming the given fraction of the way down at the middle of the
            // screen puts the match on it wherever in the run it falls, and
            // the clamping below keeps the ends of the run from overshooting.
            target = starts[index] + height * fraction - viewport / 2
        } else {
            // A run that fits is centred whole, as before — there is nowhere
            // within it that could be off screen.
            target = starts[index] - (viewport - height) / 2
        }
        let maxY = max(0, (document?.frame.height ?? 0) - viewport)

        isAdjustingScroll = true
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: min(max(0, target), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isAdjustingScroll = false
        layoutRows()
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard !isAdjustingScroll else { return }

        // The reader moved, so ask where that leaves them: at the end means
        // keep following, anywhere else means stop.
        if let scrollView, let document {
            let end = max(0, document.frame.height - scrollView.contentSize.height)
            isFollowing = end - scrollView.contentView.bounds.minY <= followThreshold
        }

        onUserScroll?()
        layoutRows()
    }

    @objc private func frameChanged(_ notification: Notification) {
        layoutRows()
    }
}

/// A hosting view that says when the size its content wants has changed.
///
/// `NSHostingView` recalculates its intrinsic size when the SwiftUI inside it
/// settles — a code block finishing its highlighting, a picture arriving — and
/// that is exactly the moment a row's height stops being a guess. Catching it
/// here is what lets the correction be applied with the scroll adjustment in
/// the same pass, rather than being noticed a frame later as a jump.
final class RunHostingView: NSHostingView<AnyView> {
    var runID: String = ""

    /// The width its content was built against, since the content carries an
    /// explicit width rather than taking it from the frame.
    var builtAtWidth: CGFloat = 0

    var onHeightChange: ((String, CGFloat) -> Void)?

    private var lastReported: CGFloat = 0

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        // So the intrinsic size is maintained and can be asked for without
        // laying anything out.
        sizingOptions = [.intrinsicContentSize]
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        reportHeight()
    }

    override func layout() {
        super.layout()
        reportHeight()
    }

    private func reportHeight() {
        guard bounds.width > 0 else { return }
        // Intrinsic rather than fitting: this is called from `layout()`, and
        // `fittingSize` lays the subtree out, which is not legal from inside a
        // layout pass. See `TranscriptCoordinator.height(of:at:)`.
        let height = intrinsicContentSize.height
        guard height > 0, height != NSView.noIntrinsicMetric else { return }
        guard abs(height - lastReported) > 0.5 else { return }
        lastReported = height
        onHeightChange?(runID, height)
    }
}
#endif
