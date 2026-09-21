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
            .help("Which service answers your messages when a conversation hasn't been given one of its own.")
            Picker("Images", selection: $manager.serviceImageDefault) {
                servicePickerView(\.supportsImages)
            }
            .help("Which service generates a picture when the assistant is asked for one.")
            Picker("Summarization", selection: $manager.serviceSummarizationDefault) {
                servicePickerView(\.supportsSummarization)
            }
            .help("Which service handles Heat's own short jobs: naming a conversation, drafting suggestions, condensing a page it has read. Falls back to the Chats service when unset.")

            // See the note in ServiceForm: nothing reads these three yet.
            Picker("Embeddings (Not Implemented)", selection: $manager.serviceEmbeddingDefault) {
                servicePickerView(\.supportsEmbeddings)
            }
            .help("Heat doesn't use this yet — the setting is remembered for when it does.")
            Picker("Transcriptions (Not Implemented)", selection: $manager.serviceTranscriptionDefault) {
                servicePickerView(\.supportsTranscriptions)
            }
            .help("Heat doesn't use this yet — the setting is remembered for when it does.")
            Picker("Speech (Not Implemented)", selection: $manager.serviceSpeechDefault) {
                servicePickerView(\.supportsSpeech)
            }
            .help("Heat doesn't use this yet — the setting is remembered for when it does.")
        }

        Section {
            Picker("Thinking in new conversations", selection: thinkingEffortBinding) {
                // The universal three rather than every level: a default
                // applies to whichever service a new conversation ends up
                // using, so it can't be stated in one service's own
                // vocabulary. Services with graded effort map these onto it.
                ForEach(ThinkingEffort.universal) { effort in
                    Text(effort.label).tag(effort)
                }
            }
            .help("How hard the model thinks in new conversations. Each conversation keeps whatever it started with, so changing this affects conversations begun afterwards and leaves existing ones alone. Any conversation can be changed from the button beside its message field. Brief asks the model in the prompt to keep its reasoning short — how well that lands varies by model, and the wording is editable under Instructions. Models that can't reason are unaffected.")

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
    private var thinkingEffortBinding: Binding<ThinkingEffort> {
        Binding(
            get: { state.config.thinkingEffortByDefault },
            set: { effort in
                var config = state.config
                config.thinkingEffortByDefault = effort
                // Kept in step so a downgrade, or anything still reading the
                // old key, doesn't disagree with what was just chosen.
                config.thinkingByDefault = effort.isThinking
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
