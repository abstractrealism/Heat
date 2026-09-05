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

    /// Rebuilt whenever this changes, so a streaming answer redraws.
    let revision: Date

    /// Whether new content should pull the view along with it.
    let isFollowing: Bool

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
            revision: revision,
            isFollowing: isFollowing,
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
        case run(String)
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
    private var isFollowing = true

    /// Set while the coordinator is moving the scroll origin itself, so its own
    /// scrolling isn't mistaken for the reader's.
    private var isAdjustingScroll = false

    /// Set while laying out, since measuring a row can make it report a new
    /// height, which asks for another layout from inside this one.
    private var isLayingOut = false

    /// TEMPORARY — throttle for the row-geometry logging.
    private var lastLog = Date.distantPast

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
    }

    func update(
        runs: [Run],
        heights: RunHeightCache,
        revision: Date,
        isFollowing: Bool,
        scrollRequest: TranscriptScroll?,
        content: @escaping (Run) -> AnyView,
        footer: @escaping () -> AnyView,
        onUserScroll: @escaping () -> Void
    ) {
        self.heights = heights
        self.content = content
        self.footerBuilder = footer
        self.onUserScroll = onUserScroll
        self.isFollowing = isFollowing

        let runsChanged = self.runs.map(\.id) != runs.map(\.id)
        let revisionChanged = lastRevision != revision
        self.runs = runs
        lastRevision = revision

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

        #if DEBUG
        // TEMPORARY — each built row's placed height against what it wants
        // right now. They should agree; where a row wants more than it was
        // given, that difference is what overlaps the message below it.
        if Date().timeIntervalSince(lastLog) >= 1.0, let first = wantedIndices.first {
            lastLog = .now
            let lines = wantedIndices.prefix(4).map { index -> String in
                let run = runs[index]
                let placed = heights.height(for: run)
                let wants = hosted[run.id].map { Self.height(of: $0, at: width) } ?? 0
                return String(format: "%d: top %.0f placed %.0f wants %.0f", index, believed[index], placed, wants)
            }
            ChatDebug.log("▦ rows from \(first) | " + lines.joined(separator: " | "))
        }
        #endif

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
    static func height(of view: NSView, at width: CGFloat) -> CGFloat {
        if abs(view.frame.width - width) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        }
        view.layoutSubtreeIfNeeded()
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

        // Otherwise only when the change is above the reader. A row below them
        // growing makes the document taller without moving anything they can
        // see.
        guard rowTop < viewportTop else { return }

        isAdjustingScroll = true
        let origin = NSPoint(x: 0, y: max(0, viewportTop + delta))
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isAdjustingScroll = false
    }

    // MARK: - Scrolling

    private func apply(_ request: TranscriptScroll) {
        switch request.destination {
        case .bottom:
            scrollToBottom()
        case .run(let id):
            scrollToRun(id)
        }
    }

    private func scrollToBottom() {
        guard let scrollView, let document else { return }
        let maxY = max(0, document.frame.height - scrollView.contentSize.height)
        isAdjustingScroll = true
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isAdjustingScroll = false
        layoutRows()
    }

    private func scrollToRun(_ id: String) {
        guard let scrollView, let index = runs.firstIndex(where: { $0.id == id }) else { return }
        let starts = offsets()
        let height = heights?.height(for: runs[index]) ?? 0

        // Centred, as the SwiftUI version scrolled matches into view.
        let target = starts[index] - (scrollView.contentSize.height - height) / 2
        let maxY = max(0, (document?.frame.height ?? 0) - scrollView.contentSize.height)

        isAdjustingScroll = true
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: min(max(0, target), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isAdjustingScroll = false
        layoutRows()
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard !isAdjustingScroll else { return }
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
        let height = fittingSize.height
        guard height > 0, abs(height - lastReported) > 0.5 else { return }
        lastReported = height
        onHeightChange?(runID, height)
    }
}
#endif
