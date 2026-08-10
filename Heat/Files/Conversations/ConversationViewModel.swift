import SwiftUI
import OSLog
import SharedKit
import GenKit
import HeatKit

private let logger = Logger(subsystem: "ConversationViewModel", category: "App")

enum ChatPreference {
    /// Whether reasoning models should think before answering.
    static let thinkingEnabled = "thinkingEnabled"

    /// On by default, matching what a model does when left alone. Only the
    /// off state is ever sent: a model that can't reason rejects a request
    /// asking it to, so staying quiet is what keeps mixed model setups working.
    static var isThinkingEnabled: Bool {
        UserDefaults.standard.object(forKey: thinkingEnabled) as? Bool ?? true
    }
}

/// Keeps one view model per conversation, alive beyond the view showing it.
///
/// `FileDetail` gives each conversation view an `.id`, so navigating to
/// another file tears the view down. When the view model went with it, a turn
/// that was still generating lost its home: the work carried on (the task
/// holds the model), but coming back built an empty model and read the
/// conversation from disk, which the turn hasn't written yet — so the prompt,
/// the status, and the answer had all apparently vanished. Sharing the model
/// means returning to a conversation rejoins the turn already in progress.
@MainActor
final class ConversationViewModelStore {
    static let shared = ConversationViewModelStore()

    private var models: [String: ConversationViewModel] = [:]

    /// Caps idle models so browsing many conversations doesn't hold them all
    /// in memory. A generating model is never evicted, and a view already
    /// showing an evicted model keeps its own reference.
    private let idleLimit = 8

    func model(for file: File) -> ConversationViewModel {
        if let existing = models[file.id] {
            return existing
        }
        evictIdleModelsIfNeeded()
        let model = ConversationViewModel(file: file)
        models[file.id] = model
        return model
    }

    func removeAll() {
        models.removeAll()
    }

    private func evictIdleModelsIfNeeded() {
        guard models.count >= idleLimit else { return }
        for (id, model) in models where !model.isGenerating {
            models.removeValue(forKey: id)
        }
    }
}

@Observable @MainActor
final class ConversationViewModel {
    var file: File
    var conversation: Conversation = .init()

    private let state = AppState.shared
    private var generateTask: Task<Void, Never>? = nil

    enum Error: Swift.Error, CustomStringConvertible {
        case generationError(String)
        case unexpectedError(String)
        case notFound(String)

        public var description: String {
            switch self {
            case .generationError(let detail):
                return "Generation error: \(detail)"
            case .unexpectedError(let detail):
                return "Unexpected error: \(detail)"
            case .notFound(let detail):
                return "Not Found error: \(detail)"
            }
        }
    }

    /// Suggested replies the user can use to respond.
    var suggestions: [String] {
        Array((conversation.suggestions).prefix(3))
    }

    /// What the assistant is doing right now, for the status indicator.
    ///
    /// These are the phases the service actually tells us about. A local model
    /// being loaded into memory is *not* one of them: Ollama sends nothing at
    /// all until generation starts, and only reports `load_duration` once the
    /// response is finished, so loading and prompt evaluation are both just
    /// `.waiting` from here.
    enum Phase: Equatable {
        case idle
        case waiting      // request sent, nothing streamed back yet
        case thinking     // streaming reasoning inside an unclosed think tag
        case responding   // streaming the visible answer
        case suggesting   // generating follow-up suggestions
    }

    var phase: Phase {
        switch conversation.state {
        case .processing:
            return .waiting
        case .streaming:
            if isReasoning { return .thinking }
            return lastMessageHasVisibleText ? .responding : .waiting
        case .suggesting:
            return .suggesting
        case .none:
            return .idle
        }
    }

    /// True while a turn is running, used to offer a stop control.
    var isGenerating: Bool {
        conversation.state != .none
    }

    private var lastMessageHasVisibleText: Bool {
        guard let last = conversation.messages.last, last.role == .assistant else { return false }
        let text = last.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !text.isEmpty
    }

    /// The opening of the latest answer, for a notification preview.
    ///
    /// Anything up to the end of a reasoning block is dropped: a model that
    /// thinks out loud would otherwise fill the preview with its scratchpad
    /// instead of the answer that was actually waited for.
    private var responsePreview: String? {
        guard var text = conversation.messages.last?.content else { return nil }
        for tag in ["think", "thinking"] {
            if let close = text.range(of: "</\(tag)>", options: [.caseInsensitive, .backwards]) {
                text = String(text[close.upperBound...])
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 140 ? text.prefix(140).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    /// True when the assistant has opened a reasoning tag it hasn't closed.
    /// Reasoning models stream their scratchpad first, which can run for a
    /// long time and collapses into a "Thinking" block, so the status line
    /// says that's what's happening rather than implying an answer is coming.
    private var isReasoning: Bool {
        guard let last = conversation.messages.last, last.role == .assistant,
              let content = last.content else { return false }
        return ["think", "thinking"].contains { tag in
            let opened = content.components(separatedBy: "<\(tag)>").count - 1
            let closed = content.components(separatedBy: "</\(tag)>").count - 1
            return opened > closed
        }
    }

    /// The instructions (system prompt) that's sent with every request.'
    var instructions: [Message] {
        let instructions = Message(role: .system, content: conversation.instructions)
        return [instructions]
    }

    /// The whole conversation history.
    var messages: [Message] {
        conversation.messages
    }

    /// The conversation history aggregated by Run which packages up all tool calls and responses into a Run.
    var runs: [Run] {
        prepareRuns()
    }

    var title: String {
        file.name ?? "Heat"
    }

    var subtitle: String {
        guard let (_, model) = try? API.shared.preferredChatService() else { return "Unknown model" }
        return model.name ?? model.id
    }

    init(file: File) {
        self.file = file
    }

    func read(_ conversation: Conversation) {
        self.conversation = conversation
    }

    /// How often a streaming answer is published to the view. Fast enough to
    /// read as continuous, slow enough that re-rendering a long answer doesn't
    /// dominate the machine.
    private let streamPublishInterval: TimeInterval = 0.1

    /// Tokens per second while a turn is still running.
    ///
    /// The service only reports its own counts once a response is finished, so
    /// until then this counts stream deltas — one token each for Ollama — over
    /// elapsed time. It's an estimate, and it gives way to the service's real
    /// figures the moment they arrive.
    private(set) var liveTokensPerSecond: Double?

    /// Counted on every delta but only read when publishing, so the running
    /// total doesn't drag a re-render along with each token.
    @ObservationIgnored private var streamedDeltas = 0
    @ObservationIgnored private var streamStartedAt: Date?

    /// Shows a streamed message, replacing the earlier version of it.
    private func publish(_ message: Message) {
        if let index = conversation.messages.firstIndex(where: { $0.id == message.id }) {
            conversation.messages[index] = message
        } else {
            conversation.messages.append(message)
        }
        conversation.state = .streaming
        file.modified = .now

        if let started = streamStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            liveTokensPerSecond = elapsed > 0.5 ? Double(streamedDeltas) / elapsed : nil
        }
    }

    // MARK: - Generators

    /// Starts a new turn of the conversation, cancelling whatever is still
    /// generating from the previous one.
    ///
    /// A turn keeps working after its answer arrives — it goes on to request
    /// suggested replies and a title — and those requests write to the shared
    /// conversation state. With a slow model they can still be running when
    /// the user sends the next prompt, at which point their results are stale
    /// and their writes clobber the new turn's state. Cancelling first means
    /// only one turn ever owns the conversation.
    func submit(chat prompt: String, context: [String: Value] = [:], toolIDs: Set<String>? = nil) {
        generateTask?.cancel()
        generateTask = Task {
            do {
                if conversation.isEmpty {
                    let stored = try state.file(Conversation.self, fileID: file.id)
                    read(stored)
                }

                // Augment the tool set associated with the conversation, it's a better user experience to keep
                // around tools used with custom instructions so the assistant can use them for followup questions.
                //
                // These have to go into the conversation held here: the request
                // is built from it, and so is every save. Merging them into the
                // stored copy instead left them out of the turn they were
                // chosen for, and the save at the start of that turn wrote this
                // copy straight back over them, so they were lost entirely.
                if let toolIDs {
                    conversation.toolIDs.formUnion(toolIDs)
                }

                try await generate(chat: prompt, context: context)
            } catch {
                guard !Task.isCancelled else { return }
                state.log(error: error)
            }
        }
    }

    /// Generate a response using text as the only input. Add context—often memories—to augment the system prompt. Optionally force a tool call.
    func generate(chat prompt: String, images: [URL] = [], context: [String: Value] = [:], toolChoice: Tool? = nil) async throws {
        do {
            let (service, model) = try API.shared.preferredChatService()

            var context = context
            context["DATETIME"] = .string(Date.now.formatted())

            // New user message
            let imageContent = images.map { Message.Content.image(.init(url: $0, format: .jpeg)) }
            let textContent = Message.Content.text(PromptTemplate(prompt, with: context))

            let userMessage = Message(role: .user, contents: [textContent] + imageContent)
            conversation.messages.append(userMessage)
            conversation.suggestions = []
            conversation.state = .processing

            // Save the prompt now rather than only when the whole turn is
            // done, so it isn't lost if the app stops before the answer lands.
            try await API.shared.fileUpdate(file.id, object: conversation)

            // Initial request
            var req = ChatSessionRequest(service: service, model: model, toolCallback: prepareToolResponse)
            req.with(system: PromptTemplate(conversation.instructions, with: context))
            req.with(history: conversation.messages)
            req.with(tools: Toolbox.get(names: conversation.toolIDs))
            req.with(context: context)
            if !ChatPreference.isThinkingEnabled {
                req.with(option: "think", value: .bool(false))
            }

            // Generate response stream
            let stream = ChatSession.shared.stream(req)
            // Publishing every token re-renders the message, and rendering
            // means re-parsing the whole answer as markdown and laying it out
            // again — work that grows with the answer while tokens keep
            // arriving at a fixed rate. With reasoning shown that text is long
            // enough to saturate a core. Publishing on an interval keeps the
            // text visibly moving for a fraction of the work; the stream is
            // still consumed as fast as it arrives.
            var pending: Message?
            var lastPublished = Date.distantPast

            streamedDeltas = 0
            streamStartedAt = .now
            liveTokensPerSecond = nil

            for try await message in stream {
                try Task.checkCancellation()
                streamedDeltas += 1

                // A new message means the previous one is done, so let its
                // last tokens through before moving on.
                if let pending, pending.id != message.id {
                    publish(pending)
                }
                pending = message

                if Date().timeIntervalSince(lastPublished) >= streamPublishInterval {
                    publish(message)
                    lastPublished = .now
                }
            }

            // Whatever the last interval didn't cover.
            if let pending {
                publish(pending)
            }

            // See generateSuggestions: a cancelled stream ends quietly, so
            // check before touching state or starting follow-up work.
            try Task.checkCancellation()

            // Reset conversation state
            conversation.state = .none

            // The answer is what someone stepped away from, so tell them here
            // rather than after the suggestions and title that follow it.
            NotificationManager.shared.responseCompleted(
                conversation: file.name ?? "Heat",
                preview: responsePreview
            )

            // Generate suggestions
            try await generateSuggestions()

            // Generate title
            try await generateTitle()

            // Cache conversation
            try await API.shared.fileUpdate(file.id, object: conversation)
            try await API.shared.fileUpdate(file)
        } catch {
            // A turn that was superseded by a newer prompt must not touch the
            // conversation state or report a failure — the new turn owns the
            // conversation now, and this cancellation was deliberate.
            if error is CancellationError || Task.isCancelled { return }
            throw Error.generationError("\(error)")
        }
    }

    func generateSuggestions() async throws {
        let (service, model) = try API.shared.preferredChatService()

        // Cached instructions
        let instruction = try state.file(Instruction.self, fileID: Defaults.instructionSuggestionsID)

        // Flattened message history
        let messages = conversation.messages
        let history = preparePlainTextHistory(messages)
        let content = PromptTemplate(instruction.instructions, with: ["history": .string(history)])

        // Initial request
        var req = ChatSessionRequest(service: service, model: model)
        req.with(history: [.init(role: .user, content: content)])

        // Indicate we are suggesting
        conversation.state = .suggesting

        // Generate suggestions stream
        let stream = ChatSession.shared.stream(req)
        for try await message in stream {
            try Task.checkCancellation()
            guard let content = message.content else { continue }

            let name = "suggested_replies"
            let result = try ContentParser.shared.parse(input: content, tags: [name])
            let tag = result.first(tag: name)

            guard let content = tag?.content else { continue }
            let suggestions = content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)

            conversation.suggestions = suggestions
            file.modified = .now
        }

        // Cancelling a turn ends the stream without throwing — the loop body
        // simply stops running, so its checkCancellation never fires. Test for
        // it here, before writing state a newer turn may already own.
        try Task.checkCancellation()

        // Set conversation state
        conversation.state = .none
    }

    func generateTitle() async throws {
        guard file.name == nil else { return }

        let (service, model) = try API.shared.preferredChatService()

        // Cached instructions
        let instruction = try state.file(Instruction.self, fileID: Defaults.instructionTitleID)

        // Flatted message history
        let messages = conversation.messages
        let history = preparePlainTextHistory(messages)
        let content = PromptTemplate(instruction.instructions, with: ["history": .string(history)])

        // Initial request
        var req = ChatSessionRequest(service: service, model: model)
        req.with(history: [.init(role: .user, content: content)])

        // Generate suggestions stream
        let stream = ChatSession.shared.stream(req)
        for try await message in stream {
            try Task.checkCancellation()
            guard let content = message.content else { continue }

            let name = "title"
            let result = try ContentParser.shared.parse(input: content, tags: [name])
            let tag = result.first(tag: name)
            let tagIsEmpty = tag?.content?.isEmpty ?? true

            file.name = tagIsEmpty ? nil : tag?.content
            file.modified = .now
        }

        // As above: don't let a cancelled turn fall through to saving.
        try Task.checkCancellation()
    }

    /// Stops the current turn at the user's request.
    ///
    /// Unlike the cancellation that happens when a new prompt supersedes a
    /// turn, nothing is about to take ownership of the conversation here, so
    /// this resets the state itself and saves whatever did arrive rather than
    /// discarding a partial answer.
    func cancel() {
        generateTask?.cancel()
        generateTask = nil
        conversation.state = .none

        let snapshot = conversation
        Task { try? await API.shared.fileUpdate(file.id, object: snapshot) }
    }

    // MARK: - Private

    @Sendable // Determine tool to execute and return response before next turn of the conversation
    private func prepareToolResponse(toolCall: ToolCall) async throws -> ToolCallResponse {
        if let tool = Toolbox(name: toolCall.function?.name) {
            switch tool {
            case .generateImages:
                let messages = await ImageGeneratorTool.handle(toolCall)
                return .init(messages: messages, shouldContinue: false)
            case .searchWeb:
                let messages = await WebSearchTool.handle(toolCall)
                return .init(messages: messages, shouldContinue: true)
            case .browseWeb:
                let messages = await WebBrowseTool.handle(toolCall)
                return .init(messages: messages, shouldContinue: true)
            case .searchCalendar:
                let messages = await CalendarSearchTool.handle(toolCall)
                return .init(messages: messages, shouldContinue: true)
            }
        } else {
            let toolResponse = Message(
                role: .tool,
                content: "Unknown tool.",
                toolCallID: toolCall.id,
                name: toolCall.function?.name,
                metadata: ["label": .string("Unknown tool")]
            )
            return .init(messages: [toolResponse], shouldContinue: false)
        }
    }

    private func prepareRuns() -> [Run] {
        var runs: [Run] = []
        var currentRun = Run()

        // Cluster message runs
        for message in messages {
            if currentRun.id == message.runID {
                currentRun.messages.append(message)
                currentRun.ended = message.modified
            } else {
                if !currentRun.messages.isEmpty {
                    runs.append(currentRun)
                }
                let runID = (message.runID != nil && !message.runID!.isEmpty) ? message.runID! : message.id
                currentRun = Run(
                    id: runID,
                    messages: [message],
                    started: message.created,
                    ended: message.modified
                )
            }
        }

        // Append remaining run
        if !currentRun.messages.isEmpty {
            runs.append(currentRun)
        }

        return runs
    }

    private func preparePlainTextHistory(_ messages: [Message]) -> String {
        var out = ""
        for message in messages {
            out += message.role.rawValue + ":\n"
            for content in message.contents ?? [] {
                guard case .text(let text) = content else { continue }
                out += text + "\n"
            }
            out += "\n"
        }
        return out
    }
}
