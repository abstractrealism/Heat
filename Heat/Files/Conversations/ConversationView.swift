import SwiftUI
import SharedKit
import HeatKit

struct ConversationView: View {
    @Environment(AppState.self) var state

    let file: File

    /// Shared rather than owned: see ConversationViewModelStore. A view model
    /// created here would be discarded whenever the view is torn down, taking
    /// an in-progress turn's messages and status with it.
    let conversationViewModel: ConversationViewModel

    init(file: File) {
        self.file = file
        self.conversationViewModel = ConversationViewModelStore.shared.model(for: file)
    }

    private var fileID: String { file.id }

    var body: some View {
        MessageList()
            // Over the thread rather than above it: a bar that takes its own
            // row would push the messages down at the moment you go looking
            // for one.
            .overlay(alignment: .topTrailing) {
                if conversationViewModel.isFinding {
                    FindBar()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: conversationViewModel.isFinding)
            .navigationTitle(conversationViewModel.title)
            .safeAreaInset(edge: .bottom, alignment: .center) {
                MessageField { (prompt, images, context, toolIDs) in
                    handleSubmit(prompt, images: images, context: context, toolIDs: toolIDs)
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
            // Leaving a conversation closes its find bar. It used to be kept,
            // on the reasoning that a browser keeps find per tab — but a tab
            // you return to still shows the page you left, whereas coming back
            // here is starting again, and a bar left open reads as one you
            // never dismissed.
            .onDisappear {
                conversationViewModel.endFind()
            }
            // Only the conversation on screen answers ⌘F. Others hold view
            // models too, and would otherwise all open a find bar nobody can
            // see.
            .onChange(of: state.findRequests) { _, _ in
                conversationViewModel.beginFind()
            }
    }

    func handleLoad() {
        // The model decides whether disk has anything it doesn't: a turn in
        // flight is left alone, and a copy already matching the file's date
        // isn't re-read — reassigning identical content still invalidates
        // every observer, which made returning to a thread cost as much as
        // opening it cold.
        conversationViewModel.load(file)
    }

    func handleSubmit(_ prompt: String, images: [URL] = [], context: [String: String]? = nil, toolIDs: Set<String>? = nil) {
        conversationViewModel.submit(
            chat: prompt,
            images: images,
            context: context?.mapValues { Value.string($0) } ?? [:],
            toolIDs: toolIDs
        )
    }
}
