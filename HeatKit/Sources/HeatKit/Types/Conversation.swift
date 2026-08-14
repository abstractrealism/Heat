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

    /// Whether the model reasons before answering here.
    ///
    /// Settled on the same terms as `serviceID`: follows the default until the
    /// conversation is used or the toggle is touched, and is its own from then
    /// on.
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
