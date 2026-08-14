import SwiftUI
import SharedKit
import HeatKit

struct ConversationView: View {
    @Environment(AppState.self) var state

    let fileID: String

    /// Shared rather than owned: see ConversationViewModelStore. A view model
    /// created here would be discarded whenever the view is torn down, taking
    /// an in-progress turn's messages and status with it.
    let conversationViewModel: ConversationViewModel

    init(file: File) {
        self.fileID = file.id
        self.conversationViewModel = ConversationViewModelStore.shared.model(for: file)
    }

    var body: some View {
        MessageList()
            .navigationTitle(conversationViewModel.title)
            .safeAreaInset(edge: .bottom, alignment: .center) {
                MessageField { (prompt, context, toolIDs) in
                    handleSubmit(prompt, context: context, toolIDs: toolIDs)
                }
                .background(.background)
            }
            .environment(conversationViewModel)
            .onChange(of: fileID) { oldValue, newValue in
                handleLoad()
            }
            .onAppear {
                handleLoad()
            }
    }

    func handleLoad() {
        // A turn still in flight owns the conversation in memory, and it is
        // further along than the copy on disk — reading over it would drop
        // the prompt and the answer arriving right now.
        guard !conversationViewModel.isGenerating else { return }
        do {
            let conversation = try state.file(Conversation.self, fileID: fileID)
            conversationViewModel.read(conversation)
        } catch {
            state.log(error: error)
        }
    }

    func handleSubmit(_ prompt: String, context: [String: String]? = nil, toolIDs: Set<String>? = nil) {
        conversationViewModel.submit(
            chat: prompt,
            context: context?.mapValues { Value.string($0) } ?? [:],
            toolIDs: toolIDs
        )
    }
}
