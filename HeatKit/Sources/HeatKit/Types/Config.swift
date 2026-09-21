import Foundation
import SharedKit
import GenKit

public struct Config: Codable, Sendable {
    public var services: [Service]
    public var metadata: [String: Value]

    public init() {
        self.services = Defaults.services
        self.metadata = [:]
    }

    func apply(_ config: Config) -> Config {
        var existing = self
        existing.services = config.services
        existing.metadata = config.metadata
        return existing
    }
}

// MARK: - Personalization

extension Config {

    public var userName: String? {
        set { metadata["userName"] = (newValue != nil) ? .string(newValue!) : nil }
        get { metadata["userName"]?.stringValue }
    }

    public var userLocation: String? {
        set { metadata["userLocation"] = (newValue != nil) ? .string(newValue!) : nil }
        get { metadata["userLocation"]?.stringValue }
    }

    public var userBiography: String? {
        set { metadata["userBiography"] = (newValue != nil) ? .string(newValue!) : nil }
        get { metadata["userBiography"]?.stringValue }
    }
}

// MARK: - Service Defaults

extension Config {

    public var serviceChatDefault: String? {
        set { metadata["serviceChatDefault"] = (newValue != nil) ? .string(newValue!) : nil }
        get { metadata["serviceChatDefault"]?.stringValue }
    }

    public var serviceImageDefault: String? {
        set { metadata["serviceImageDefault"] = (newValue != nil) ? .string(newValue!) : nil }
        get { metadata["serviceImageDefault"]?.stringValue }
    }

    public var serviceEmbeddingDefault: String? {
        set { metadata["serviceEmbeddingDefault"] = (newValue != nil) ? .string(newValue!) : nil }
        get { metadata["serviceEmbeddingDefault"]?.stringValue }
    }

    public var serviceTranscriptionDefault: String? {
        set { metadata["serviceTranscriptionDefault"] = (newValue != nil) ? .string(newValue!) : nil }
        get { metadata["serviceTranscriptionDefault"]?.stringValue }
    }

    public var serviceSpeechDefault: String? {
        set { metadata["serviceSpeechDefault"] = (newValue != nil) ? .string(newValue!) : nil }
        get { metadata["serviceSpeechDefault"]?.stringValue }
    }

    public var serviceSummarizationDefault: String? {
        set { metadata["serviceSummarizationDefault"] = (newValue != nil) ? .string(newValue!) : nil }
        get { metadata["serviceSummarizationDefault"]?.stringValue }
    }
}

// MARK: - Conversation Defaults

extension Config {

    /// Whether new conversations start with reasoning switched on.
    ///
    /// On unless said otherwise, matching what a model does when left alone.
    /// Only ever the starting point: a conversation takes its own copy the
    /// first time it sends, so changing this reaches conversations started
    /// afterwards and leaves existing ones as they were.
    /// How hard new conversations think by default.
    ///
    /// Falls back to `thinkingByDefault`, which is what this replaced, so a
    /// preference set before there were levels still means what it meant.
    public var thinkingEffortByDefault: ThinkingEffort {
        set { metadata["thinkingEffortByDefault"] = .string(newValue.rawValue) }
        get {
            if let stored = metadata["thinkingEffortByDefault"]?.stringValue,
               let effort = ThinkingEffort(rawValue: stored) {
                return effort
            }
            return thinkingByDefault ? .full : .off
        }
    }

    public var thinkingByDefault: Bool {
        set { metadata["thinkingByDefault"] = .bool(newValue) }
        get { metadata["thinkingByDefault"]?.boolValue ?? true }
    }

    /// Whether earlier reasoning is taken out of the history before it's sent
    /// back to the model.
    ///
    /// On by default. Reasoning is a model's working, not its answer, and it
    /// can run many times the length of the reply it produced — so leaving it
    /// in means every later turn re-sends all of it, and a conversation eats
    /// its own context. The reasoning is only removed from what's sent; the
    /// stored message keeps it, so Show Thinking still works on old replies.
    public var stripThinkingFromContext: Bool {
        set { metadata["stripThinkingFromContext"] = .bool(newValue) }
        get { metadata["stripThinkingFromContext"]?.boolValue ?? true }
    }
}

// MARK: - Context Length

extension Config {

    /// Context lengths chosen for particular models, keyed by service and
    /// model together.
    ///
    /// Per model rather than per service or per conversation. It's a property
    /// of the model and the machine running it — how much memory a context
    /// costs depends on the model's size — so the same answer applies wherever
    /// that model is used, and a different one applies to the model next to it.
    ///
    /// Only the exceptions are stored. A model with no entry sends nothing and
    /// gets whatever the server would have given it anyway, which is what
    /// should happen to a model nobody has had an opinion about.
    private var contextLengths: [String: Int] {
        get {
            guard case .object(let entries)? = metadata["contextLengthByModel"] else { return [:] }
            return entries.compactMapValues(\.intValue)
        }
        set {
            metadata["contextLengthByModel"] = newValue.isEmpty
                ? nil
                : .object(newValue.mapValues { .int($0) })
        }
    }

    /// Keyed by both halves: two services can offer the same model name, and
    /// they won't be the same installation or the same machine.
    private func contextKey(serviceID: String, modelID: String) -> String {
        "\(serviceID)\u{1F}\(modelID)"
    }

    public func contextLength(serviceID: String, modelID: String) -> Int? {
        contextLengths[contextKey(serviceID: serviceID, modelID: modelID)]
    }

    /// Passing nil hands the model back to the server's default.
    public mutating func setContextLength(_ length: Int?, serviceID: String, modelID: String) {
        var lengths = contextLengths
        lengths[contextKey(serviceID: serviceID, modelID: modelID)] = length
        contextLengths = lengths
    }

    /// The ceiling on what a single reply may generate, per service.
    ///
    /// Per service rather than per model, unlike the context length: this is a
    /// policy about how long an answer is allowed to run, not a fact about what
    /// a model can hold.
    ///
    /// It matters more than it used to. Where a model reasons before answering,
    /// this bounds the reasoning *and* the reply together — so a figure chosen
    /// when replies were the only output can be spent thinking, and the answer
    /// arrives truncated.
    private var maxTokensByService: [String: Int] {
        get {
            guard case .object(let entries)? = metadata["maxTokensByService"] else { return [:] }
            return entries.compactMapValues(\.intValue)
        }
        set {
            metadata["maxTokensByService"] = newValue.isEmpty
                ? nil
                : .object(newValue.mapValues { .int($0) })
        }
    }

    public func maxTokens(serviceID: String) -> Int? {
        maxTokensByService[serviceID]
    }

    /// Passing nil returns the service to whatever the provider decides.
    public mutating func setMaxTokens(_ tokens: Int?, serviceID: String) {
        var all = maxTokensByService
        all[serviceID] = tokens
        maxTokensByService = all
    }
}

// MARK: - Service Availability

extension Config {

    /// Services the user has switched off, and doesn't want offered.
    ///
    /// Stored as the exceptions rather than as a flag on each service: a
    /// service added later is then usable without having to be enabled first,
    /// and this is an app-level display preference, not something belonging to
    /// GenKit's shared `Service` type.
    ///
    /// Distinct from `Service.status`, which reports whether a service *can*
    /// work — no host, no token. This is about whether it should be offered at
    /// all, so a configured account you don't want cluttering the model list
    /// can be hidden without deleting its credentials.
    public var disabledServiceIDs: Set<String> {
        set {
            metadata["disabledServiceIDs"] = newValue.isEmpty ? nil : .array(newValue.sorted().map { .string($0) })
        }
        get {
            guard case .array(let values)? = metadata["disabledServiceIDs"] else { return [] }
            return Set(values.compactMap(\.stringValue))
        }
    }

    public func isEnabled(_ service: Service) -> Bool {
        !disabledServiceIDs.contains(service.id)
    }

    /// Services worth offering a model from: switched on, and holding models
    /// to offer. A service that has never had its models loaded contributes
    /// nothing to a picker, so it's left out rather than listed empty.
    public var selectableServices: [Service] {
        services.filter { isEnabled($0) && !$0.models.isEmpty }
    }
}

// MARK: - Model Availability

extension Config {

    /// Which models someone has decided about, either way.
    ///
    /// Stored as decisions rather than as a list of what's on, so a model that
    /// appears later — a provider adding one, or a local install — is judged
    /// by the same rule as the rest instead of being invisible until found and
    /// switched on by hand.
    private var modelChoices: [String: Bool] {
        get {
            guard case .object(let entries)? = metadata["modelEnabledByService"] else { return [:] }
            return entries.compactMapValues(\.boolValue)
        }
        set {
            metadata["modelEnabledByService"] = newValue.isEmpty
                ? nil
                : .object(newValue.mapValues { .bool($0) })
        }
    }

    /// Keyed by both halves, as context lengths are: two services can offer
    /// the same model name and not mean the same installation.
    private func modelKey(serviceID: String, modelID: String) -> String {
        "\(serviceID)\u{1F}\(modelID)"
    }

    /// Whether to offer this model when picking one for a conversation.
    ///
    /// An explicit decision wins. Failing that the service guesses from the
    /// name — see `Service.isLikelyChatModel(modelID:)` — because OpenAI keeps
    /// every model it has ever served and most of them aren't for
    /// conversation, so "everything until told otherwise" starts anybody new
    /// with a list of 130 they'd have to prune by hand.
    public func isModelEnabled(_ model: Model, in service: Service) -> Bool {
        if let decided = modelChoices[modelKey(serviceID: service.id, modelID: model.id)] {
            return decided
        }
        return service.isLikelyChatModel(modelID: model.id)
    }

    /// Whether a decision has been recorded, as opposed to the guess standing.
    public func isModelChoiceExplicit(_ model: Model, in service: Service) -> Bool {
        modelChoices[modelKey(serviceID: service.id, modelID: model.id)] != nil
    }

    /// Passing nil forgets the decision and returns the model to the guess.
    public mutating func setModelEnabled(_ enabled: Bool?, for model: Model, in service: Service) {
        var choices = modelChoices
        choices[modelKey(serviceID: service.id, modelID: model.id)] = enabled
        modelChoices = choices
    }

    /// Forgets every decision for one service.
    public mutating func clearModelChoices(in service: Service) {
        let prefix = "\(service.id)\u{1F}"
        modelChoices = modelChoices.filter { !$0.key.hasPrefix(prefix) }
    }

    /// The models to offer for a conversation.
    public func enabledModels(in service: Service) -> [Model] {
        service.models.filter { isModelEnabled($0, in: service) && !isModelUnavailable($0, in: service) }
    }

    /// Models the service has refused to serve.
    ///
    /// Separate from the switches above, and it isn't a preference: a model
    /// here can't be used at all, so it's hidden rather than switched off.
    ///
    /// Learned from the refusal, because nothing else knows. A withdrawn model
    /// stays in OpenAI's model list — `/v1/models` went on reporting
    /// `gpt-4o-search-preview` long after requests for it started failing —
    /// and the published deprecation list names the dated *snapshot* while the
    /// list offers the undated alias, so neither source can be matched against
    /// the other without also condemning models that still work. The attempt
    /// is the only thing that can say.
    private var unavailableModelKeys: Set<String> {
        get {
            guard case .array(let entries)? = metadata["unavailableModels"] else { return [] }
            return Set(entries.compactMap(\.stringValue))
        }
        set {
            metadata["unavailableModels"] = newValue.isEmpty
                ? nil
                : .array(newValue.sorted().map { .string($0) })
        }
    }

    public func isModelUnavailable(_ model: Model, in service: Service) -> Bool {
        unavailableModelKeys.contains(modelKey(serviceID: service.id, modelID: model.id))
    }

    public mutating func markModelUnavailable(_ model: Model, in service: Service) {
        unavailableModelKeys.insert(modelKey(serviceID: service.id, modelID: model.id))
    }

    /// How many of a service's models are hidden this way, so a pane can say
    /// so rather than quietly showing a shorter list than the service offers.
    public func unavailableModelCount(in service: Service) -> Int {
        service.models.filter { isModelUnavailable($0, in: service) }.count
    }

    /// Forgets the refusals for one service — for a model that comes back, or
    /// one refused for a reason that has since been fixed.
    public mutating func clearUnavailableModels(in service: Service) {
        let prefix = "\(service.id)\u{1F}"
        unavailableModelKeys = unavailableModelKeys.filter { !$0.hasPrefix(prefix) }
    }
}
