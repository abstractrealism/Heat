import SwiftUI
import GenKit
import HeatKit

struct RenderThinking: View {
    @Environment(ConversationViewModel.self) private var conversationViewModel

    let tag: ContentParser.Result.Tag

    @State private var disclosed = false

    init(_ tag: ContentParser.Result.Tag) {
        self.tag = tag
    }

    /// Reasoning still being written has no closing tag yet.
    private var isStreaming: Bool { !tag.hasClosingTag }

    /// The block being written follows the conversation, so the status line at
    /// the foot of the page can close it. Finished blocks keep their own state,
    /// so closing the live one doesn't shut every earlier one as well.
    private var isDisclosed: Bool {
        isStreaming ? conversationViewModel.isStreamingThinkingExpanded : disclosed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                // Collapsed by default: reasoning is usually long and isn't
                // the answer, but it's there when you want to see the working.
                Label(
                    isDisclosed ? "Hide Thinking" : "Show Thinking",
                    systemImage: isDisclosed ? "chevron.down" : "chevron.right"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isDisclosed {
                RenderText(tag.content, tags: ["reflection"])
                    .padding(.leading)
                    .overlay(
                        Rectangle()
                            .fill(.primary.opacity(0.5))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity),
                        alignment: .leading
                    )
                    .opacity(0.5)
            }
        }
        .onChange(of: isStreaming) { _, stillStreaming in
            // Keep what was on screen when the block finished. Without this it
            // would fall back to its own state the moment reasoning ended, and
            // shut in front of somebody reading it.
            if !stillStreaming {
                disclosed = conversationViewModel.isStreamingThinkingExpanded
            }
        }
    }

    private func toggle() {
        if isStreaming {
            conversationViewModel.isStreamingThinkingExpanded.toggle()
        } else {
            disclosed.toggle()
        }
    }
}
