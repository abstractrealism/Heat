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

    /// Measured heights by run id, valid only for `width`.
    private var measured: [String: CGFloat] = [:]

    /// The pane width these measurements were taken at. Height depends on how
    /// wide the text may run, so a different width invalidates all of them.
    private var width: CGFloat = 0

    /// Drops everything if the pane changed width.
    ///
    /// An invalidated cache is a cache *miss*, not a failure — the estimate
    /// takes over, which is the same path a thread opens through the first
    /// time. Resizing therefore degrades to a cold open rather than breaking
    /// anything, and re-measures as the reader scrolls.
    func invalidateIfNeeded(width newWidth: CGFloat) {
        guard abs(newWidth - width) > 0.5 else { return }
        width = newWidth
        measured.removeAll(keepingCapacity: true)
    }

    func record(_ height: CGFloat, for runID: String) {
        // Rounded, so sub-pixel jitter between passes doesn't count as a
        // change worth reacting to.
        measured[runID] = (height * 2).rounded() / 2
    }

    func measuredHeight(for runID: String) -> CGFloat? {
        measured[runID]
    }

    /// What a run should occupy: what it measured, or failing that a guess
    /// from how much text it holds.
    func height(for run: Run) -> CGFloat {
        measured[run.id] ?? Self.estimate(for: run, width: width)
    }

    /// A stable guess, from character count.
    ///
    /// Deterministic on purpose. Accuracy matters less than never changing its
    /// mind for the same input: an estimate that wobbles is what made
    /// `LazyVStack` untenable. It is also only ever wrong *above* the reader —
    /// the transcript opens at the bottom, so corrections higher up don't move
    /// what's being looked at.
    static func estimate(for run: Run, width: CGFloat) -> CGFloat {
        let characters = run.messages.reduce(0) { total, message in
            total + (message.content?.count ?? 0)
        }

        // Roughly: how many characters fit on a line at this width, at the
        // chat font, then a line's height for each line, plus the chrome a
        // message carries (padding, the usage line, spacing between runs).
        let charactersPerLine = max(20.0, Double(width > 0 ? width : 700) / 7.4)
        let lines = max(1.0, (Double(characters) / charactersPerLine).rounded(.up))
        let messageChrome = 44.0 * Double(max(1, run.messages.count))
        return CGFloat(lines * 20.0 + messageChrome)
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
        guard !runs.isEmpty, viewportHeight > 0 else { return .all }

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
        // The newest run always renders — see above.
        upper = max(upper, runs.count - 1 - 0)
        return RunWindow(lowerBound: lower, upperBound: max(upper, lower))
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
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    guard height > 0 else { return }
                    heights.record(height, for: runID)
                }
        }
    }
}

extension View {
    func reportingHeight(of runID: String, into heights: RunHeightCache) -> some View {
        modifier(RunHeightReporter(runID: runID, heights: heights))
    }
}
