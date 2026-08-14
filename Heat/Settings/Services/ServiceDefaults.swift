import SwiftUI
import GenKit
import HeatKit

struct ServiceDefaults: View {
    @Environment(AppState.self) var state
    @Environment(ServicesManager.self) var manager

    var body: some View {
        @Bindable var manager = manager
        Section("Defaults") {
            Picker("Chats", selection: $manager.serviceChatDefault) {
                servicePickerView(\.supportsChats)
            }
            Picker("Images", selection: $manager.serviceImageDefault) {
                servicePickerView(\.supportsImages)
            }
            Picker("Embeddings", selection: $manager.serviceEmbeddingDefault) {
                servicePickerView(\.supportsEmbeddings)
            }
            Picker("Transcriptions", selection: $manager.serviceTranscriptionDefault) {
                servicePickerView(\.supportsTranscriptions)
            }
            Picker("Speech", selection: $manager.serviceSpeechDefault) {
                servicePickerView(\.supportsSpeech)
            }
            Picker("Summarization", selection: $manager.serviceSummarizationDefault) {
                servicePickerView(\.supportsSummarization)
            }
        }

        Section {
            Toggle("Thinking on in new conversations", isOn: thinkingBinding)
                .help("Whether new conversations start with reasoning switched on. Each conversation keeps whatever it started with, so changing this affects conversations begun afterwards and leaves existing ones alone. Any conversation can be switched the other way from the button beside its message field. Models that can't reason are unaffected.")

            Toggle("Remove thinking from prompt context", isOn: stripThinkingBinding)
                .help("Leaves earlier reasoning out of what's sent back to the model. Reasoning is the model's working, not its answer, and it often runs many times the length of the reply — so keeping it means every later message re-sends all of it, filling the context window and slowing each turn. Your conversation keeps its thinking either way; Show Thinking still works. Turn this off only if you want the model to reread how it got to its earlier answers.")
        } header: {
            Text("Conversations")
        } footer: {
            Text("Where new conversations start. Existing ones keep what they began with. Heat's own prompts — naming a conversation, drafting suggestions — never reason, whatever this says.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Written straight to the config rather than through the manager, which
    /// saves on dismissal: this is one switch, and a conversation opened
    /// before the settings window closes should already see it.
    private var thinkingBinding: Binding<Bool> {
        Binding(
            get: { state.config.thinkingByDefault },
            set: { enabled in
                var config = state.config
                config.thinkingByDefault = enabled
                Task { try? await API.shared.configUpdate(config) }
            }
        )
    }

    private var stripThinkingBinding: Binding<Bool> {
        Binding(
            get: { state.config.stripThinkingFromContext },
            set: { enabled in
                var config = state.config
                config.stripThinkingFromContext = enabled
                Task { try? await API.shared.configUpdate(config) }
            }
        )
    }

    func servicePickerView(_ prop: KeyPath<Service, Bool>) -> some View {
        Group {
            Text("None").tag(String?.none)
            Divider()
            ForEach(manager.services.filter { $0[keyPath: prop] }) { service in
                Text(service.name).tag(service.id)
            }
        }
    }
}
