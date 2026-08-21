import Foundation
import GenKit
import SharedKit

public struct Conversation: Codable, Sendable {
    public var instructions: String
    public var suggestions: [String]
    public var toolIDs: Set<String>
    public var state: State
    public var messages: [Message]

    /// The model answering in this conversation.
    ///
    /// Empty only before the conversation has sent anything: an unused
    /// conversation follows the defaults, so a new one always starts from
    /// current settings, and its first message writes down what it actually
    /// used. After that the conversation keeps it, whether it was chosen by
    /// hand or inherited.
    ///
    /// Not stamped at creation, and not left to follow the defaults forever —
    /// both get this wrong from opposite directions. Stamping at creation
    /// freezes conversations onto whatever was configured the day they were
    /// made, which is how `toolIDs` behaves. Following indefinitely means
    /// changing a default reaches back into conversations that had already
    /// been having a different one.
    ///
    /// Both halves or neither: a model id means nothing without knowing which
    /// service it belongs to, since two services can offer the same name.
    public var serviceID: String?
    public var modelID: String?

    /// How hard the model thinks before answering here.
    ///
    /// Settled on the same terms as `serviceID`: follows the default until the
    /// conversation is used or the control is touched, and is its own from then
    /// on.
    public var thinkingEffort: ThinkingEffort?

    /// What `thinkingEffort` replaced, kept so conversations written before it
    /// keep the setting they were given. Read when `thinkingEffort` is absent
    /// and never written again — see `Conversation.effort`.
    public var thinkingEnabled: Bool?

    /// The effort this conversation was given, whichever field carries it, or
    /// nil while it's still following the default.
    public var effort: ThinkingEffort? {
        if let thinkingEffort { return thinkingEffort }
        guard let thinkingEnabled else { return nil }
        return thinkingEnabled ? .full : .off
    }

    /// Whether the tool set was chosen for this conversation rather than
    /// inherited from the Assistant instruction.
    ///
    /// An untouched conversation re-reads that instruction until its first
    /// message, so editing the default reaches conversations created before the
    /// edit. Without this, that refresh also overwrote a set somebody had just
    /// picked by hand — switch a tool on in a new conversation, send, and the
    /// choice was gone before the request was built.
    public var toolsChosen: Bool?

    /// Notes standing in for the messages up to and including
    /// `compactedThroughMessageID`.
    ///
    /// Nil after clearing, which folds the same messages away without keeping
    /// anything in their place.
    public var contextSummary: String?

    /// The last message no longer sent in full.
    ///
    /// Compaction is deliberately not destructive: the messages stay exactly
    /// where they are and the transcript reads as it always did. This only
    /// moves where the model starts reading, so the conversation someone can
    /// scroll back through and the conversation the model is given stop being
    /// the same thing.
    public var compactedThroughMessageID: String?

    public enum State: Codable, Sendable {
        case processing
        case streaming
        case suggesting
        case none
    }

    public init(instructions: String = "", suggestions: [String] = [], toolIDs: Set<String> = [], state: State = .none,
                messages: [Message] = [], serviceID: String? = nil, modelID: String? = nil,
                thinkingEnabled: Bool? = nil, contextSummary: String? = nil,
                compactedThroughMessageID: String? = nil) {
        self.contextSummary = contextSummary
        self.compactedThroughMessageID = compactedThroughMessageID
        self.instructions = instructions
        self.suggestions = suggestions
        self.toolIDs = toolIDs
        self.state = state
        self.messages = messages
        self.serviceID = serviceID
        self.modelID = modelID
        self.thinkingEnabled = thinkingEnabled
    }

    public var isEmpty: Bool {
        instructions.isEmpty && messages.isEmpty
    }
}
