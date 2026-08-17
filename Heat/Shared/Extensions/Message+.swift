import SwiftUI
import GenKit
import HeatKit

extension Message {

    /// Whether this message appears without the run having to be expanded.
    ///
    /// Tool calls and their responses show. They don't render their contents —
    /// each is a single line ("Browsing website...", "Browsed website") that
    /// discloses its own detail when clicked, and an assistant message calling
    /// a tool carries its own Show Thinking. Hiding them put a second
    /// disclosure around things that already had one, so a run reported that
    /// there was work to see while the work was one line long.
    ///
    /// Left as a real question rather than always true: a message with nothing
    /// to show for itself should still be able to say so, and the run collapses
    /// again the moment anything answers false.
    var shouldShowInRun: Bool {
        true
    }

    var hasImage: Bool {
        for content in contents ?? [] {
            switch content {
            case .image:
                return true
            default:
                continue
            }
        }
        return false
    }
}
