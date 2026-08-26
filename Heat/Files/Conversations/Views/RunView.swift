import SwiftUI
import GenKit
import HeatKit

struct RunView: View {
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
        }
    }
}
