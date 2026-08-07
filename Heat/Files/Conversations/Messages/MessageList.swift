import SwiftUI
import SharedKit
import HeatKit

struct MessageList: View {
    @Environment(AppState.self) var state
    @Environment(ConversationViewModel.self) var conversationViewModel

    var body: some View {
        ScrollViewReader { proxy in
            MessageListScrollView {

                // Show message run history
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(conversationViewModel.runs) { run in
                        RunView(run)
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
                        GeneratingIndicator("Generating")
                    case .thinking:
                        GeneratingIndicator("Thinking")
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
            .onChange(of: conversationViewModel.file.modified) { _, _ in
                proxy.scrollTo("bottom")
            }
            .onAppear {
                proxy.scrollTo("bottom")
            }
            .onOpenURL { url in
                if let suggestion = url.queryParameters["suggestion"] {
                    handleSubmit(suggestion.replacingOccurrences(of: "+", with: " "))
                }
                proxy.scrollTo("bottom")
            }
        }
    }

    func handleSubmit(_ prompt: String) {
        conversationViewModel.submit(chat: prompt)
    }
}

/// Wrapper for scrolling message views. Using a `List` has much better scrolling performance on macOS.
/// On iOS the `List` studders when text is streaming and the scroll position is updated.
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
