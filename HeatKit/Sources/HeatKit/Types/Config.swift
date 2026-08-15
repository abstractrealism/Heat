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
