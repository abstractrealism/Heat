import Foundation
import GenKit
import SharedKit

public struct Conversation: Codable, Sendable {
    public var instructions: String
    public var suggestions: [String]
    public var toolIDs: Set<String>
    public var state: State
    public var messages: [Message]

    /// The model answering in this conversation, when one was picked for it.
    ///
    /// Left empty until somebody actually chooses, rather than stamped with
    /// the default when the conversation is created. A conversation nobody has
    /// made a decision about should follow the default in Settings, including
    /// after that default changes — copying the value in at creation would
    /// freeze every existing conversation onto whatever was configured that
    /// day, which is how `toolIDs` behaves and is not worth repeating.
    ///
    /// Both halves or neither: a model id means nothing without knowing which
    /// service it belongs to, since two services can offer the same name.
    public var serviceID: String?
    public var modelID: String?

    /// Whether the model reasons before answering here, when this
    /// conversation has been told one way or the other.
    ///
    /// Unset means follow the default in Settings, on the same terms as
    /// `serviceID`: a conversation nobody has decided about should move when
    /// that default moves.
    public var thinkingEnabled: Bool?

    public enum State: Codable, Sendable {
        case processing
        case streaming
        case suggesting
        case none
    }

    public init(instructions: String = "", suggestions: [String] = [], toolIDs: Set<String> = [], state: State = .none,
                messages: [Message] = [], serviceID: String? = nil, modelID: String? = nil,
                thinkingEnabled: Bool? = nil) {
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
