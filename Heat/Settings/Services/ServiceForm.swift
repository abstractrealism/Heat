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
                TextField("Host", text: $service.host)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .help("Where this service is reached. A local Ollama is usually http://127.0.0.1:11434/api; a hosted service is its API address, such as https://api.openai.com/v1. Leave blank to use the service's default.")

                TextField("Token", text: $service.token)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .help("The API key for services that require one. A local Ollama needs none — leave it blank.")
            } footer: {
                Text("Fill in what this service needs, then Load Models to fetch what it offers.")
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
                    .help("Condenses long text. Often worth a smaller, faster model than the one answering you.")
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
        .onAppear {
            handleLoadModels()
        }
        .onDisappear {
            handleSave()
        }
    }

    func handleLoadModels() {
        Task {
            do {
                let client = service.modelService(session: nil)
                service.models = try await client.models()
                manager.update(service: service)
            } catch {
                state.log(error: error)
            }
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
