import SwiftUI
import GenKit
import HeatKit

/// What each run measured, so a run that isn't on screen can reserve its space
/// without being laid out.
///
/// This is the "reserve the height, skip the render" idea: a browser spells it
/// `content-visibility: auto` with `contain-intrinsic-size`. Opening a
/// transcript costs what it costs because a `List` is NSTableView-backed and
/// variable-height rows are all measured — 18 runs and ~24,000 points of
/// content took 1.2 seconds of layout, and the renderer barely mattered
/// (MarkdownUI paid 1.21s where Textual paid 1.29s).
///
/// **Not** an estimate that changes its mind. `LazyVStack` was tried first and
/// reverted: it guesses the size of what it hasn't built, so `contentSize`
/// lurched by ~1,700 points between frames and the follow logic — which infers
/// everything from `contentSize` — became unsound. A measurement is a fact,
/// and a fact stays put. Where there is no measurement yet, the estimate below
/// is at least *stable*, which is the property that actually matters: the
/// follow logic needs consistent deltas, not perfect ones.
///
/// Deliberately not `@Observable`, and held through `@ObservationIgnored`: it
/// is written to during layout, and anything observing it would schedule
/// another render pass from inside a render pass. Same reasoning as
/// `MessageList.ScrollIntent`.
@MainActor
final class RunHeightCache {

    /// What each run measured, and how wide it was when it did.
    ///
    /// The width travels with the height because a height is only meaningful
    /// at the width it was taken at — and, more sharply, because a row can be
    /// measured before the list has given it its real width, which produces a
    /// height several times too large. Keeping the width lets those be
    /// recognised and thrown away rather than believed.
    private var measured: [String: (width: CGFloat, height: CGFloat)] = [:]

    /// The pane's current width, as last reported by scroll geometry.
    private var paneWidth: CGFloat = 0

    /// How far a measurement's width may be from the pane's and still count.
    ///
    /// Wide enough to absorb a macOS overlay scrollbar arriving and leaving,
    /// which changes the container width by a handful of points mid-scroll.
    /// Clearing every measurement each time that happened is what produced the
    /// yank: the content lost half its height in a single event, and an offset
    /// valid a moment earlier was past the end.
    private static let widthTolerance: CGFloat = 24

    func noteViewport(width: CGFloat) {
        guard width > 0 else { return }
        paneWidth = width
    }

    /// Records a height, unless the row plainly wasn't laid out properly.
    ///
    /// A row built far outside the viewport — as the background pass does —
    /// can be measured before the list has told it how wide it is, and text
    /// asked to fit a sliver is very tall indeed. Those readings inflated a
    /// thread to twice its real height, and pinning rows to them made the
    /// collapse worse when they were eventually corrected.
    func record(_ height: CGFloat, at width: CGFloat, for runID: String) {
        guard height > 0, width > 0, paneWidth > 0 else { return }
        guard abs(width - paneWidth) <= Self.widthTolerance else { return }

        // Rounded, so sub-pixel jitter between passes doesn't count as a
        // change worth reacting to.
        let rounded = (height * 2).rounded() / 2

        // The tallest this run has been seen at this width, not the latest.
        //
        // A row is measured many times over its life and the readings
        // disagree, because content settles after it is first built — a code
        // block is highlighted asynchronously, a picture arrives late. Taking
        // the latest lets a row shrink back to a half-built state; taking the
        // tallest cannot, and being too tall shows a gap where being too short
        // overlaps the next message.
        if let existing = measured[runID], abs(existing.width - paneWidth) <= Self.widthTolerance {
            measured[runID] = (width, max(existing.height, rounded))
        } else {
            measured[runID] = (width, rounded)
        }
    }

    /// What a run measured, if that measurement still applies at this width.
    ///
    /// Checked per entry rather than by clearing the lot: a stale entry simply
    /// stops answering, and is replaced the moment its run is drawn again.
    func measuredHeight(for runID: String) -> CGFloat? {
        guard let entry = measured[runID] else { return nil }
        guard abs(entry.width - paneWidth) <= Self.widthTolerance else { return nil }
        return entry.height
    }

    /// What a run should occupy: what it measured, or failing that a guess
    /// from how much text it holds.
    func height(for run: Run) -> CGFloat {
        measuredHeight(for: run.id) ?? Self.estimate(for: run, width: paneWidth)
    }

    /// A stable guess, from character count.
    ///
    /// Deterministic on purpose. Accuracy matters less than never changing its
    /// mind for the same input: an estimate that wobbles is what made
    /// `LazyVStack` untenable. It is also only ever wrong *above* the reader —
    /// the transcript opens at the bottom, so corrections higher up don't move
    /// what's being looked at.
    static func estimate(for run: Run, width: CGFloat) -> CGFloat {
        // Only what is actually set as text. A tool message draws one line —
        // "Browsed website", disclosing its detail when asked — while carrying
        // thousands of characters of results, so counting its content
        // estimated a tool-heavy thread at several times its real height. That
        // is why a conversation full of code and tool calls behaved worse than
        // a longer one without them.
        let characters = run.messages.reduce(0) { total, message in
            guard message.role != .tool else { return total }
            return total + (message.content?.count ?? 0)
        }
        let toolLines = run.messages.reduce(0) { total, message in
            message.role == .tool ? total + 1 : total
        }

        // Roughly: how many characters fit on a line at this width, at the
        // chat font, then a line's height for each line, plus the chrome a
        // message carries (padding, the usage line, spacing between runs).
        let charactersPerLine = max(20.0, Double(width > 0 ? width : 700) / 7.4)
        let lines = max(1.0, (Double(characters) / charactersPerLine).rounded(.up))
        let messageChrome = 44.0 * Double(max(1, run.messages.count - toolLines))
        return CGFloat(lines * 20.0 + messageChrome + Double(toolLines) * 30.0)
    }
}

/// The span of runs that get rendered for real; everything outside reserves
/// its height and draws nothing.
///
/// Computed from the cache rather than from layout, so asking the question
/// costs no measuring: the runs' positions are the running sum of their
/// heights.
struct RunWindow: Equatable {
    var lowerBound: Int
    var upperBound: Int

    static let all = RunWindow(lowerBound: 0, upperBound: .max)

    func contains(_ index: Int) -> Bool {
        index >= lowerBound && index <= upperBound
    }

    /// The span covering both.
    ///
    /// Kept for the tail window, which is unioned into whatever scrolling
    /// decides. It was briefly used to stop windows narrowing at all, on the
    /// theory that a run reverting to a reserved height is what dropped the
    /// content size — it wasn't, and rows are pinned now, so a run reserves
    /// exactly the height it was being held at either way.
    func union(_ other: RunWindow) -> RunWindow {
        RunWindow(
            lowerBound: min(lowerBound, other.lowerBound),
            upperBound: max(upperBound, other.upperBound)
        )
    }

    /// How much to render beyond the viewport in each direction. A screen's
    /// worth means an ordinary scroll finds its content already built, and a
    /// fast one finds it a moment later — the blank-then-fill that any
    /// virtualized list shows when it is outrun.
    private static let overscan: CGFloat = 1.5

    /// The runs that intersect the viewport, padded by the overscan.
    ///
    /// Always includes the last run, whatever the scroll position: it is what
    /// a streaming answer is written into, and reserving space for it instead
    /// of rendering it would leave the answer invisible while it arrives.
    @MainActor
    static func around(
        offset: CGFloat,
        viewportHeight: CGFloat,
        runs: [Run],
        heights: RunHeightCache
    ) -> RunWindow {
        // Before the scroll view has been laid out there is no viewport to
        // measure against. Answering "everything" there is how the first
        // attempt built the whole conversation on a second visit: the runs
        // were already loaded, so a zero-height geometry event assigned the
        // widest possible window before the tail one could apply.
        guard !runs.isEmpty, viewportHeight > 0 else {
            return .tail(runs: runs, heights: heights)
        }

        let padding = viewportHeight * overscan
        let top = offset - padding
        let bottom = offset + viewportHeight + padding

        var lower = 0
        var upper = runs.count - 1
        var position: CGFloat = 0
        var foundLower = false

        for (index, run) in runs.enumerated() {
            let height = heights.height(for: run)
            let runBottom = position + height

            if !foundLower {
                if runBottom >= top {
                    lower = index
                    foundLower = true
                }
            }
            if position > bottom {
                upper = max(index - 1, lower)
                break
            }
            position = runBottom
        }

        if !foundLower {
            lower = max(runs.count - 1, 0)
            upper = runs.count - 1
        }
        return RunWindow(lowerBound: lower, upperBound: max(upper, lower))
    }

    /// The window to open with, before any scroll geometry exists.
    ///
    /// This is the whole point of the exercise and the easy thing to get
    /// wrong: the geometry handler cannot narrow the window until the list has
    /// been laid out once, and laying it out once is exactly the cost being
    /// avoided. Starting wide and narrowing later builds every run and then
    /// throws the work away.
    ///
    /// A transcript opens at its newest message, so the runs worth building
    /// are the last few. Walks back from the end until a screen and its
    /// overscan are covered, using whatever heights are known — measurements
    /// if this thread has been opened before, estimates if not.
    ///
    /// The viewport height is a guess because nothing has been measured yet.
    /// Guessing too large only costs a few extra runs; too small would leave a
    /// gap at the bottom, so it errs high.
    @MainActor
    static func tail(runs: [Run], heights: RunHeightCache, viewportHeight: CGFloat = 1000) -> RunWindow {
        guard !runs.isEmpty else { return .all }

        let budget = viewportHeight * (1 + overscan)
        var covered: CGFloat = 0
        var lower = runs.count - 1

        for index in stride(from: runs.count - 1, through: 0, by: -1) {
            lower = index
            covered += heights.height(for: runs[index])
            if covered >= budget { break }
        }
        return RunWindow(lowerBound: lower, upperBound: runs.count - 1)
    }
}

/// Reports what a run actually measured, so the next time it is off screen it
/// can reserve exactly that much.
///
/// A background rather than an overlay, and `Color.clear` rather than a
/// `GeometryReader`, so it takes the size it is given instead of proposing one.
struct RunHeightReporter: ViewModifier {
    let runID: String
    let heights: RunHeightCache

    func body(content: Content) -> some View {
        content.background {
            Color.clear
                // Width as well as height: the cache uses it to tell a real
                // measurement from one taken before the list said how wide the
                // row was.
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    heights.record(size.height, at: size.width, for: runID)
                }
        }
    }
}

extension View {
    func reportingHeight(of runID: String, into heights: RunHeightCache) -> some View {
        modifier(RunHeightReporter(runID: runID, heights: heights))
    }
}
