import SwiftUI
import OSLog
import GenKit
import HeatKit

private let logger = Logger(subsystem: "ServiceForm", category: "App")

struct ServiceForm: View {
    @Environment(AppState.self) var state
    @Environment(ServicesManager.self) var manager

    @State var service: Service

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: enabledBinding)
                    .help("Whether to offer this service's models when picking one for a conversation. Turning it off hides them without discarding the host or token, so a service you're not using now stays configured for later.")
            }

            #if os(macOS)
            Divider()
                .padding(.vertical)
            #endif

            Section {
                TextField("Host", text: $service.host)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .help("Where this service is reached. A local Ollama is usually http://127.0.0.1:11434/api; a hosted service is its API address, such as https://api.openai.com/v1. Heat ships each service with a working address, so there's rarely a reason to change this.")

                TextField("Token", text: $service.token)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .help("The API key for services that require one. A local Ollama needs none — leave it blank.")
            } footer: {
                Text("Then Load Models to fetch what it offers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            Divider()
                .padding(.vertical)
            #endif

            Section {
                ServiceModelPicker("Chats", service.models, selection: $service.preferredChatModel)
                    .help("The model that answers your messages. This is the one to set for ordinary use.")
                ServiceModelPicker("Images", service.models, selection: $service.preferredImageModel)
                    .help("Used when the assistant generates a picture.")
                ServiceModelPicker("Embeddings", service.models, selection: $service.preferredEmbeddingModel)
                    .help("Turns text into vectors for searching by meaning rather than by wording.")
                ServiceModelPicker("Transcriptions", service.models, selection: $service.preferredTranscriptionModel)
                    .help("Turns speech into text.")
                ServiceModelPicker("Speech", service.models, selection: $service.preferredSpeechModel)
                    .help("Reads text aloud.")
                ServiceModelPicker("Summarization", service.models, selection: $service.preferredSummarizationModel)
                    .help("Used for Heat's own short jobs: naming a conversation, drafting follow-up suggestions, and condensing a web page it has read. Worth a smaller, faster model than the one answering you. Falls back to the Chats model when unset.")
            } header: {
                Text("Models")
            } footer: {
                Text("Which of this service's models to use for each job. A service is only offered for a job it can do, and only after Load Models has found something.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Load Models") {
                    handleLoadModels()
                }
                .disabled(service.token.isEmpty && service.host.isEmpty)
            }
        }
        .navigationTitle(service.name)
        .task(id: service.id) {
            await loadModels()
        }
        .onDisappear {
            handleSave()
        }
    }

    /// Written straight through to the config rather than held in `service`,
    /// which is a local copy saved only on the way out. Hiding a service should
    /// take effect in the model picker immediately, not whenever this form
    /// happens to be dismissed.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.config.isEnabled(service) },
            set: { isEnabled in
                var config = state.config
                if isEnabled {
                    config.disabledServiceIDs.remove(service.id)
                } else {
                    config.disabledServiceIDs.insert(service.id)
                }
                Task { try? await API.shared.configUpdate(config) }
            }
        )
    }

    func handleLoadModels() {
        Task { await loadModels() }
    }

    /// Fetches the models this service offers.
    ///
    /// Run from `.task(id:)` rather than `onAppear` so that selecting another
    /// service cancels it. An unowned task would carry on and write its result
    /// back through the manager after the form had moved on, which is how
    /// clicking between services ends up showing one service's models under
    /// another's name.
    func loadModels() async {
        // Nothing to connect to, and the request would sit there until it
        // timed out — which is the delay when opening a service you haven't
        // configured.
        guard !service.host.isEmpty || !service.token.isEmpty else { return }
        do {
            let client = service.modelService(session: nil)
            let models = try await client.models()
            guard !Task.isCancelled else { return }
            service.models = models
            manager.update(service: service)
        } catch {
            guard !Task.isCancelled else { return }
            state.log(error: error)
        }
    }

    func handleSave() {
        manager.update(service: service)
    }
}

struct ServiceModelPicker: View {
    let title: String
    let models: [Model]

    @Binding var selection: String?

    init(_ title: String, _ models: [Model]?, selection: Binding<String?>) {
        self.title = title
        self.models = models ?? []
        self._selection = selection
    }

    var body: some View {
        Picker(selection: $selection) {
            Text("None").tag(String?.none)
            Divider()
            ForEach(models.sorted(by: { $0.id < $1.id })) { model in
                Text(model.name ?? model.id).tag(model.id)
            }
        } label: {
            Text(title)
        }
    }
}
