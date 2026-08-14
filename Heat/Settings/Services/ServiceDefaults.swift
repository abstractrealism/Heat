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
                .help("Whether new conversations start with reasoning switched on. Each conversation can be switched the other way from the button beside its message field, and keeps that answer afterwards — changing this moves only the conversations nobody has decided about. Models that can't reason are unaffected.")
        } header: {
            Text("Conversations")
        } footer: {
            Text("Where new conversations start. Heat's own prompts — naming a conversation, drafting suggestions — never reason, whatever this says.")
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
