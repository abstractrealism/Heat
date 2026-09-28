import SwiftUI
import GenKit
import HeatKit

struct RunView: View {
    @Environment(AppState.self) private var state

    let run: Run

    @State private var showAllMessages = false

    init(_ run: Run) {
        self.run = run
    }

    /// Whether this run is holding anything back.
    ///
    /// The button used to appear whenever a run had more than one message,
    /// which counted tool calls and their responses — both of which show
    /// anyway, and each of which already discloses its own detail. So a run
    /// offered to reveal work that was in front of you the whole time, under a
    /// label that never changed to say it had been pressed.
    private var hasHiddenMessages: Bool {
        run.messages.contains { !$0.shouldShowInRun }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasHiddenMessages {
                Button {
                    showAllMessages.toggle()
                } label: {
                    Text(showAllMessages ? "Hide Work" : "Show Work")
                }
                .buttonStyle(.bordered)
            }

            ForEach(run.messages) { message in
                if showAllMessages || message.shouldShowInRun {
                    MessageView(message)
                        // Reachable on iOS, where the list is a ScrollView and
                        // anything named is an anchor. On macOS it's a List,
                        // where only rows are — find scrolls to the run there.
                        .id(message.id)
                }
            }

            // After the run rather than beside each refusal. A turn that
            // searches asks three or four times, and during a hold every one
            // of them is refused — four copies of the same advice would read
            // as four separate problems.
            if wasRateLimited && !hasFallback {
                SearchRateLimitNotice()
            }
        }
    }

    private var wasRateLimited: Bool {
        run.messages.contains { $0.metadata["searchRateLimited"]?.boolValue == true }
    }

    /// Checked as the run is drawn rather than recorded when it happened, so
    /// that setting a key up stops the advice appearing on old runs too. It
    /// is advice, and advice that has been taken shouldn't keep asking.
    private var hasFallback: Bool {
        state.config.searchProviders.contains { $0.kind != .duckDuckGo && $0.isReady }
    }
}

/// Said when DuckDuckGo refused a run's searches and nothing else could
/// answer them.
///
/// The model is told search is unavailable and passes that on, which is all
/// it should say: what to do about it is a fact about Heat's Settings, and a
/// model improvising instructions about an app's UI gets them wrong. So the
/// remedy is offered by the app, where it is either true or absent.
///
/// Orange rather than red, and quiet: nothing is broken, the answer just
/// went without the web. Orange is what the Tools pane already uses for a
/// provider that isn't set up.
struct SearchRateLimitNotice: View {
    var body: some View {
        Label {
            Text("You've reached DuckDuckGo's rate limit, so this answer went without the web. A Brave Search API key in Settings ▸ Tools would let Heat keep searching when this happens.")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.orange)
        }
        .font(.footnote)
        .textSelection(.enabled)
    }
}
