import SwiftUI
import OSLog
import GenKit
import HeatKit

private let logger = Logger(subsystem: "ServiceForm", category: "App")

struct ServiceForm: View {
    @Environment(AppState.self) var state
    @Environment(ServicesManager.self) var manager

    @State var service: Service

    /// How the last attempt to load this service's models went.
    ///
    /// Shown rather than only logged. A failure went to Heat's own log store,
    /// which has no viewer anywhere in the app, so pressing Load Models with a
    /// wrong address or a bad key was indistinguishable from pressing a button
    /// that wasn't wired to anything.
    private enum ModelLoad: Equatable {
        case idle
        case loading
        case loaded(found: Int, withdrawn: Int)
        case failed(String)
    }

    @State private var modelLoad: ModelLoad = .idle

    /// Held as a value rather than written at the call site.
    ///
    /// A string literal passed to `help` is read as a localization key and run
    /// through the markdown parser, which turns the two addresses in it into
    /// links — and a tooltip can only carry unstyled text, so AppKit complained
    /// on every appearance: "Only unstyled text can be used with help(_:)".
    /// A `String` value takes a different overload, and is shown as written.
    private static let hostHelp = "Where this service is reached. A local Ollama is usually http://127.0.0.1:11434/api; a hosted service is its API address, such as https://api.openai.com/v1. Heat ships each service with a working address, so there's rarely a reason to change this."

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
                    .help(Self.hostHelp)

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
                ServiceModelPicker(
                    "Chats",
                    service.models,
                    help: "The model that answers your messages. This is the one to set for ordinary use.",
                    selection: $service.preferredChatModel
                )
                ServiceModelPicker(
                    "Images",
                    service.models,
                    help: "Used when the assistant generates a picture.",
                    selection: $service.preferredImageModel
                )
                ServiceModelPicker(
                    "Summarization",
                    service.models,
                    help: "Used for Heat's own short jobs: naming a conversation, drafting follow-up suggestions, and condensing a web page it has read. Worth a smaller, faster model than the one answering you. Falls back to the Chats model when unset.",
                    selection: $service.preferredSummarizationModel
                )

                // Nothing reads these yet: there is no embedding, transcription
                // or speech call anywhere in the app. Said in the label rather
                // than left to be discovered, since a setting that appears to
                // configure something is a claim, and left alone these three
                // were the same sort of lie as a thinking toggle that changed
                // nothing. Kept rather than hidden so what's coming is visible,
                // and so a choice made now survives until it's read.
                ServiceModelPicker(
                    "Embeddings (Not Implemented)",
                    service.models,
                    help: "Turns text into vectors for searching by meaning rather than by wording. Heat doesn't use this yet — the setting is remembered for when it does.",
                    selection: $service.preferredEmbeddingModel
                )
                ServiceModelPicker(
                    "Transcriptions (Not Implemented)",
                    service.models,
                    help: "Turns speech into text. Heat doesn't use this yet — the setting is remembered for when it does.",
                    selection: $service.preferredTranscriptionModel
                )
                ServiceModelPicker(
                    "Speech (Not Implemented)",
                    service.models,
                    help: "Reads text aloud. Heat doesn't use this yet — the setting is remembered for when it does.",
                    selection: $service.preferredSpeechModel
                )
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
                .disabled(modelLoad == .loading || (service.token.isEmpty && service.host.isEmpty))
            } footer: {
                switch modelLoad {
                case .idle:
                    EmptyView()
                case .loading:
                    Text("Asking \(service.name)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .loaded(let found, let withdrawn):
                    Text(
                        withdrawn > 0
                            ? "Found \(found) models. \(withdrawn) have been withdrawn and are hidden."
                            : (found == 1 ? "Found 1 model." : "Found \(found) models.")
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            modelAvailabilitySection
            contextLengthSection
            maxTokensSection
        }
        .navigationTitle(service.name)
        .task(id: service.id) {
            await loadModels()
        }
        .onDisappear {
            handleSave()
        }
    }

    // MARK: - Which models to offer

    /// What's been typed to narrow the list. A service can offer 130 models,
    /// which is more than anyone scrolls through to find the one they meant.
    @State private var modelFilter = ""

    /// Everything the service offers and will actually serve. A model it has
    /// refused is left out entirely rather than shown switched off — it isn't
    /// a choice anybody has, so a switch for it would be one that does
    /// nothing.
    private var offerableModels: [Model] {
        service.models.filter { !state.config.isModelUnavailable($0, in: service) }
    }

    private var filteredModels: [Model] {
        let query = modelFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return offerableModels }
        return offerableModels.filter {
            $0.id.lowercased().contains(query) || ($0.name?.lowercased().contains(query) ?? false)
        }
    }

    @ViewBuilder
    private var modelAvailabilitySection: some View {
        Section {
            if service.models.isEmpty {
                Text("Load Models first, then choose which of them to offer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button("Enable All") { setAllModels(true) }
                    Button("Disable All") { setAllModels(false) }
                    if guessDiscriminates {
                        Button("Use Suggested") { clearModelChoices() }
                            .help("Forgets every choice here and goes back to Heat's guess: models that look like they're for conversation are offered, and video, image, audio, embedding and pre-chat models aren't.")
                    }
                    Spacer(minLength: 0)
                    Text("\(enabledCount) of \(offerableModels.count)")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if service.models.count > 8 {
                    TextField("Filter", text: $modelFilter)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                ForEach(filteredModels) { model in
                    Toggle(isOn: modelBinding(for: model)) {
                        HStack(spacing: 6) {
                            Text(model.name ?? model.id)
                            // Marks the rows Use Suggested would turn on, so
                            // the note names what it says: a suggestion.
                            //
                            // It used to mark every row without an explicit
                            // decision, which meant the ones the guess had
                            // decided *against* were labelled "suggested"
                            // too — nearly the whole list, saying the
                            // opposite of what it meant.
                            //
                            // And then it marked only rows nobody had decided
                            // about, which read as a bug: unticking a model
                            // took the tag away and re-ticking it never
                            // brought it back, because re-ticking records a
                            // decision where before there had been none. The
                            // model was as suggested as it ever was. What the
                            // tag describes is the suggestion, not whether it
                            // still stands unanswered.
                            if guessDiscriminates, service.isLikelyChatModel(modelID: model.id) {
                                Text("suggested")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                if filteredModels.isEmpty {
                    Text("No model matches “\(modelFilter)”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Said rather than left as a shorter list than the service
                // reports, and reversible: the judgement came from one refused
                // request, and a model can come back or be refused for a
                // reason since fixed.
                let unavailable = state.config.unavailableModelCount(in: service)
                if unavailable > 0 {
                    LabeledContent(
                        unavailable == 1
                            ? "1 model hidden as unavailable"
                            : "\(unavailable) models hidden as unavailable"
                    ) {
                        Button("Show Again") { clearUnavailableModels() }
                            .help("Brings back models hidden because \(service.name) publishes them as withdrawn, or refused a request for them. Loading models again will hide the withdrawn ones a second time.")
                    }
                    .font(.footnote)
                }
            }
        } header: {
            Text("Models to Offer")
        } footer: {
            Text("Which of this service's models appear in the picker beside the message field. The defaults above are unaffected, so a model can answer for this service without being offered per conversation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var enabledCount: Int {
        offerableModels.filter { state.config.isModelEnabled($0, in: service) }.count
    }

    /// Whether the suggestion says anything about *this* service.
    ///
    /// It's a guess from the model's name, and it exists for OpenAI, which
    /// lists around 130 models and means half a dozen of them for
    /// conversation. Everywhere else it keeps everything — so every row would
    /// carry a "suggested" tag saying nothing, beside a button that does what
    /// Enable All already does. Both are left out where that's so.
    private var guessDiscriminates: Bool {
        offerableModels.contains { !service.isLikelyChatModel(modelID: $0.id) }
    }

    private func clearUnavailableModels() {
        var config = state.config
        config.clearUnavailableModels(in: service)
        Task { try? await API.shared.configUpdate(config) }
    }

    private func modelBinding(for model: Model) -> Binding<Bool> {
        Binding(
            get: { state.config.isModelEnabled(model, in: service) },
            set: { isOn in
                var config = state.config
                config.setModelEnabled(isOn, for: model, in: service)
                Task { try? await API.shared.configUpdate(config) }
            }
        )
    }

    private func setAllModels(_ enabled: Bool) {
        var config = state.config
        for model in service.models {
            config.setModelEnabled(enabled, for: model, in: service)
        }
        Task { try? await API.shared.configUpdate(config) }
    }

    private func clearModelChoices() {
        var config = state.config
        config.clearModelChoices(in: service)
        Task { try? await API.shared.configUpdate(config) }
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

    // MARK: - Maximum reply length

    /// Powers of two again, for the same reason: 256 to 65,536 spans eight
    /// doublings, and linearly the short end would be a sliver of the track.
    private static let minReplyExponent = 8.0    // 256
    private static let maxReplyExponent = 16.0   // 65,536

    @ViewBuilder
    private var maxTokensSection: some View {
        Section {
            let chosen = state.config.maxTokens(serviceID: service.id)

            Slider(
                value: maxTokensExponentBinding,
                in: Self.minReplyExponent...Self.maxReplyExponent,
                step: 1
            )
            .help("The most a single reply may generate. Where a model reasons before answering, this covers the reasoning and the reply together — so a figure that was generous for answers alone can be spent thinking, and the answer arrives cut off.")
            // Dimmed while nothing is set, because then nothing here is in
            // force: the knob has to sit somewhere, and a knob sitting at
            // 16k beside a caption reading "Provider default" was read as
            // 16k being the default. It isn't — the request carries no
            // ceiling at all and the provider picks, which on Groq was 3,072.
            .opacity(chosen == nil ? 0.45 : 1)

            LabeledContent("Longest reply") {
                HStack(spacing: 8) {
                    Text(maxTokensCaption)
                        .monospacedDigit()
                        .foregroundStyle(chosen == nil ? .secondary : .primary)
                    if chosen != nil {
                        Button("Use Default") {
                            updateMaxTokens(nil)
                        }
                    }
                }
            }
        } header: {
            Text("Longest Reply")
        } footer: {
            Text("Per service, since it's a limit on how long an answer may run rather than anything about a particular model. Left alone, the provider decides — and what it decides is often well short of what the model could write, especially where reasoning is counted against the same figure.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var maxTokensCaption: String {
        guard let chosen = state.config.maxTokens(serviceID: service.id) else {
            // Named where it's been seen. No endpoint publishes what it
            // allows a reply left to itself, so the only thing that can say
            // is a reply that ran into it — and until one has, there is
            // genuinely nothing to report but the fact that we aren't asking.
            guard let seen = replyCeilingSeen else { return "Provider default" }
            return "Provider default (\(seen.formatted(.number.grouping(.automatic))) seen)"
        }
        return chosen.formatted(.number.grouping(.automatic)) + " tokens"
    }

    /// What this provider allowed a reply on the current Chats model, if a
    /// reply has ever been cut off by it.
    private var replyCeilingSeen: Int? {
        guard let model = chatModel else { return nil }
        return state.config.replyCeilingSeen(serviceID: service.id, modelID: model.id)
    }

    private var maxTokensExponentBinding: Binding<Double> {
        Binding(
            get: {
                // Where it starts when there's nothing set: what the provider
                // was seen to allow, so taking hold of the slider begins at
                // the figure that cut a reply off rather than at an invented
                // one. 16k only where nothing has been observed — it's the
                // ceiling gen-kit itself defaults to for Anthropic, and as
                // good a place to start as any.
                let current = state.config.maxTokens(serviceID: service.id)
                    ?? replyCeilingSeen
                    ?? 16384
                return log2(Double(min(max(current, 256), 65536)))
            },
            set: { exponent in
                updateMaxTokens(Int(pow(2, exponent.rounded())))
            }
        )
    }

    private func updateMaxTokens(_ tokens: Int?) {
        var config = state.config
        config.setMaxTokens(tokens, serviceID: service.id)
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
        modelLoad = .loading
        do {
            let client = service.modelService(session: nil)
            let models = try await client.models()
            guard !Task.isCancelled else { return }
            service.models = models
            manager.update(service: service)
            modelLoad = .loaded(found: models.count, withdrawn: 0)
            await hideWithdrawnModels(among: models)
        } catch {
            guard !Task.isCancelled else { return }
            state.log(error: error)
            modelLoad = .failed(failureMessage(for: error))
        }
    }

    /// Hides the models the service has published as withdrawn.
    ///
    /// Best effort, and deliberately silent when it can't be done: this reads
    /// a documentation page, and a page that has moved or been restructured
    /// must not stop models from loading. Failing here leaves every model
    /// offered, which is where things stood before — and a request for a dead
    /// one is still caught when the service refuses it.
    private func hideWithdrawnModels(among models: [Model]) async {
        // What's known regardless of the page — aliases the page doesn't
        // name — so a fresh install doesn't suggest a model that failed on
        // this one, and so the page being unreachable hides those at least.
        var withdrawn = ModelDeprecations.alreadyKnown(for: service.kind)
        do {
            withdrawn.formUnion(try await ModelDeprecations.withdrawnModelIDs(for: service.kind))
        } catch {
            logger.warning("couldn't read \(service.name)'s deprecations: \(error)")
        }
        guard !Task.isCancelled else { return }

        let affected = models.filter { withdrawn.contains($0.id) }
        guard !affected.isEmpty else { return }

        var config = state.config
        for model in affected {
            config.markModelUnavailable(model, in: service)
        }
        try? await API.shared.configUpdate(config)

        guard !Task.isCancelled else { return }
        modelLoad = .loaded(found: models.count, withdrawn: affected.count)
        logger.info("hid \(affected.count) withdrawn models for \(service.name)")
    }

    /// What to say when a service won't answer.
    ///
    /// The address is the likeliest thing to be wrong, and wrong in a
    /// particular way: an API's documentation shows the endpoint you'd curl,
    /// which is the base address plus a path, and pasting that in leaves every
    /// request reaching for a path underneath it. So the address Heat ships is
    /// offered whenever it differs from what's in the field.
    private func failureMessage(for error: Swift.Error) -> String {
        // A URL error's `description` is a wall of user info; its
        // localizedDescription is the one sentence worth reading. The reverse
        // is true of the services' own error enums, which describe themselves.
        let nsError = error as NSError
        let detail = nsError.domain == NSURLErrorDomain
            ? nsError.localizedDescription
            : "\(error)"

        var message = "Couldn't load models. \(detail)"
        if let shipped = Defaults.services.first(where: { $0.kind == service.kind })?.host,
           !shipped.isEmpty, shipped != service.host {
            message += "\n\nHeat's address for \(service.name) is \(shipped)"
        }
        return message
    }

    func handleSave() {
        manager.update(service: service)
    }
}

struct ServiceModelPicker: View {
    let title: String
    let models: [Model]

    /// Carried in rather than applied at the call site.
    ///
    /// `.help()` on the outside of this view attaches to the composed view,
    /// and a Form splits a labelled control into separate cells — so the
    /// tooltip ended up on a container with nothing to hover over and never
    /// appeared. On the picker itself it has a control to belong to.
    let help: String

    @Binding var selection: String?

    init(_ title: String, _ models: [Model]?, help: String = "", selection: Binding<String?>) {
        self.title = title
        self.models = models ?? []
        self.help = help
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
        .help(help)
    }
}
