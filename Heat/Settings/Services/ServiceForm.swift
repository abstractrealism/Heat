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

            contextLengthSection
        }
        .navigationTitle(service.name)
        .task(id: service.id) {
            await loadModels()
        }
        .onDisappear {
            handleSave()
        }
    }

    // MARK: - Context length

    /// The model this section is about: the one this service answers with.
    private var chatModel: Model? {
        service.models.first { $0.id == service.preferredChatModel }
    }

    /// Context lengths are powers of two, and the useful range spans two
    /// orders of magnitude — so the slider moves in exponents. Linear, the
    /// bottom half of the range would be unreachable by hand.
    private static let minExponent = 11.0   // 2,048
    private static let maxExponent = 20.0   // 1,048,576

    private func exponentRange(for model: Model) -> ClosedRange<Double> {
        let ceiling = model.contextWindow.map { Double(log2(Double($0))) } ?? Self.maxExponent
        return Self.minExponent...max(Self.minExponent + 1, min(ceiling, Self.maxExponent))
    }

    @ViewBuilder
    private var contextLengthSection: some View {
        Section {
            if let model = chatModel {
                let chosen = state.config.contextLength(serviceID: service.id, modelID: model.id)

                Slider(
                    value: contextExponentBinding(for: model),
                    in: exponentRange(for: model),
                    step: 1
                )
                .help("How much context to load \(model.name ?? model.id) with. Larger holds more conversation before the oldest messages start dropping out, and costs memory — the cache scales with length, so a big model at full context can need several gigabytes on top of its weights. Changing it makes the model reload on the next message.")

                LabeledContent("Context length") {
                    HStack(spacing: 8) {
                        Text(contextLengthCaption(for: model))
                            .monospacedDigit()
                            .foregroundStyle(chosen == nil ? .secondary : .primary)
                        if chosen != nil {
                            Button("Use Default") {
                                updateContextLength(nil, for: model)
                            }
                        }
                    }
                }
            } else {
                Text("Pick a Chats model above to set its context length.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Context Length for the Current Model")
        } footer: {
            Text("Remembered per model, so each one keeps its own. Left alone, the server decides — which is usually well below what the model could take.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func contextLengthCaption(for model: Model) -> String {
        if let chosen = state.config.contextLength(serviceID: service.id, modelID: model.id) {
            return chosen.formatted(.number.grouping(.automatic)) + " tokens"
        }
        if let loaded = model.loadedContextWindow {
            return "Server default (\(loaded.formatted(.number.grouping(.automatic))))"
        }
        return "Server default"
    }

    /// Starts where the model already is, so dragging adjusts from what's in
    /// force rather than jumping to some arbitrary point on the scale.
    private func contextExponentBinding(for model: Model) -> Binding<Double> {
        Binding(
            get: {
                let current = state.config.contextLength(serviceID: service.id, modelID: model.id)
                    ?? model.loadedContextWindow
                    ?? model.contextWindow
                    ?? 8192
                return log2(Double(max(current, 2048)))
            },
            set: { exponent in
                updateContextLength(Int(pow(2, exponent.rounded())), for: model)
            }
        )
    }

    private func updateContextLength(_ length: Int?, for model: Model) {
        var config = state.config
        config.setContextLength(length, serviceID: service.id, modelID: model.id)
        Task { try? await API.shared.configUpdate(config) }
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
