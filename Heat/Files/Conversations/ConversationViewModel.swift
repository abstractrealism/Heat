import SwiftUI
import OSLog
import SharedKit
import GenKit
import HeatKit

private let logger = Logger(subsystem: "ConversationViewModel", category: "App")

/// Verbose development logging for the chat pipeline: requests, prompts,
/// streamed responses, and how each resulting message will be displayed.
///
/// Active only in Debug builds (what Xcode uses for ⌘R); in Release builds the
/// calls compile down to nothing, so prompts and responses never leave a
/// development machine. Output goes to the unified log under subsystem
/// "ChatDebug" — it appears in Xcode's console while running, or in
/// Console.app filtered by that subsystem.
enum ChatDebug {
    #if DEBUG
    private static let logger = Logger(subsystem: "ChatDebug", category: "App")

    /// Local time, 24-hour, to the millisecond.
    ///
    /// ISO 8601 rather than a localized style: `.dateTime.hour(...)` follows
    /// the locale's clock, so on a 12-hour Mac 16:53 logs as "04:53" and an
    /// afternoon reading can't be told from a morning one. Milliseconds
    /// because the shortest thing worth timing here — a small model returning
    /// a title — can finish inside a second, which whole seconds would round
    /// away.
    private static let clock = Date.ISO8601FormatStyle(timeZone: .current)
        .time(includingFractionalSeconds: true)
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        // Stamped into the message rather than left to the console's own
        // column: it survives a line being copied out, and Xcode hides its
        // timestamp column by default.
        let text = "[\(Date.now.formatted(clock))] " + message()
        logger.debug("\(text, privacy: .public)")
        #endif
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
@Observable
final class ConversationViewModelStore {
    static let shared = ConversationViewModelStore()

    /// Which conversations have a turn running, so a list of files can show
    /// where work is happening without holding on to the view models itself.
    ///
    /// Observed, unlike the models below: a view reading this should redraw
    /// when a turn starts or finishes. The models aren't, because they're
    /// added while a view is being built, and invalidating from there is
    /// how you get a redraw loop.
    private(set) var generatingFileIDs: Set<String> = []

    @ObservationIgnored private var models: [String: ConversationViewModel] = [:]

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
        generatingFileIDs.removeAll()
    }

    /// No-ops when nothing changes, so the repeated calls a streaming turn
    /// makes don't each invalidate every view watching this.
    func setGenerating(_ generating: Bool, for fileID: String) {
        if generating, !generatingFileIDs.contains(fileID) {
            generatingFileIDs.insert(fileID)
        } else if !generating, generatingFileIDs.contains(fileID) {
            generatingFileIDs.remove(fileID)
        }
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

    /// Identifies the turn currently in charge, so one that's being replaced
    /// can tell it no longer speaks for this conversation.
    @ObservationIgnored private var currentTurn: UUID?

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

    /// A human-readable error from the most recent generation attempt, shown
    /// inline in the conversation. Cleared whenever a new generation starts.
    var error: String?

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

    /// The model answering here, whether chosen for this conversation or
    /// inherited from the default.
    var selectedModel: Model? {
        try? chatService().1
    }

    var selectedModelName: String {
        guard let model = selectedModel else { return "No model" }
        return model.name ?? model.id
    }

    /// Whether a model was picked for this conversation, as opposed to it
    /// following whatever Settings has as the default.
    var hasSelectedModel: Bool {
        conversation.serviceID != nil && conversation.modelID != nil
    }

    /// Whether the model reasons before answering here — this conversation's
    /// own answer, or the default when it hasn't got one.
    var isThinkingEnabled: Bool {
        conversation.thinkingEnabled ?? state.config.thinkingByDefault
    }

    /// Settles the question for this conversation, so it stops following the
    /// default. Turning it back to match the default doesn't resume following
    /// it: an explicit choice stays explicit, which is the point of making it.
    func setThinkingEnabled(_ enabled: Bool) {
        conversation.thinkingEnabled = enabled
        persistConversation()
    }

    /// Records a model against this conversation, so it keeps answering with
    /// the same one. Summarization is untouched: naming a conversation and
    /// suggesting replies follow their own default, and there's no reason
    /// picking a bigger model to answer with should drag those along.
    func selectModel(serviceID: String, modelID: String) {
        conversation.serviceID = serviceID
        conversation.modelID = modelID
        persistConversation()
    }

    /// Hands the conversation back to whatever Settings has as the default.
    func clearSelectedModel() {
        conversation.serviceID = nil
        conversation.modelID = nil
        persistConversation()
    }

    /// Writes down what this conversation is using, the first time it sends.
    ///
    /// Until a conversation has said anything it follows the defaults, so a
    /// new one always starts from current settings. From its first message it
    /// keeps what it started with: changing the default model or the reasoning
    /// setting afterwards would otherwise reach back into conversations that
    /// had already been having a different one, and a thread you return to a
    /// week later should behave the way it did when you left it.
    ///
    /// The values written are the ones resolved for this very turn, not the
    /// raw defaults, so what gets recorded is what actually answered — even
    /// where a stale choice had to fall back.
    private func pinCurrentDefaults() {
        if conversation.serviceID == nil || conversation.modelID == nil,
           let (service, model) = try? API.shared.resolvedChatService(
            serviceID: conversation.serviceID,
            modelID: conversation.modelID
           ) {
            conversation.serviceID = service.id
            conversation.modelID = model.id
        }
        if conversation.thinkingEnabled == nil {
            conversation.thinkingEnabled = state.config.thinkingByDefault
        }
    }

    private func persistConversation() {
        let snapshot = conversation
        Task { try? await API.shared.fileUpdate(file.id, object: snapshot) }
    }

    /// The service answering this conversation: its own choice when it has
    /// one, the configured default otherwise.
    private func chatService() throws -> (ChatService, Model) {
        try API.shared.chatService(serviceID: conversation.serviceID, modelID: conversation.modelID)
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
    ///
    /// Timed from the first token rather than from the request, because
    /// loading the model and reading the prompt happen before any token
    /// arrives; counting that time makes the rate start far too low and creep
    /// upwards for the rest of the answer. Measuring only the generating part
    /// is also what the service's own figure does, so the two agree.
    private(set) var liveTokensPerSecond: Double?

    /// Counted on every delta but only read when publishing, so the running
    /// total doesn't drag a re-render along with each token.
    @ObservationIgnored private var streamedDeltas = 0
    @ObservationIgnored private var firstDeltaAt: Date?

    /// How many deltas had arrived when the reasoning block closed, used to
    /// apportion the token total between reasoning and answer.
    @ObservationIgnored private var deltasAtEndOfThinking: Int?

    /// Shows a streamed message, replacing the earlier version of it.
    private func publish(_ message: Message) {
        if let index = conversation.messages.firstIndex(where: { $0.id == message.id }) {
            conversation.messages[index] = message
        } else {
            ChatDebug.log("← stream produced new message | role: \(message.role.rawValue) | id: \(message.id)")
            conversation.messages.append(message)
        }
        conversation.state = .streaming
        file.modified = .now

        // n tokens span n-1 gaps, measured from the first one.
        if let first = firstDeltaAt, streamedDeltas > 1 {
            let elapsed = Date().timeIntervalSince(first)
            liveTokensPerSecond = elapsed > 0.5 ? Double(streamedDeltas - 1) / elapsed : nil
        }
    }

    /// Divides the reported token total between reasoning and answer.
    ///
    /// The service counts everything it generated as a single number, so this
    /// is an approximation: it splits that total in the same proportion as the
    /// deltas that arrived either side of the reasoning block closing, and
    /// rounds, because presenting it to the token would claim a precision it
    /// doesn't have. Enough to see roughly where the time went.
    /// The conversation as it goes out to the model, with earlier reasoning
    /// left behind when Settings says so.
    ///
    /// Only what's sent is affected. The stored messages keep their reasoning,
    /// so Show Thinking still opens on replies from weeks ago — this is about
    /// not making the model re-read its own scratch work on every turn.
    ///
    /// Assistant turns only. A user is entitled to write `<think>` in a
    /// message — quoting a transcript, asking about the tag itself — and
    /// rewriting what somebody typed is not on.
    private func historyForRequest() -> [Message] {
        guard state.config.stripThinkingFromContext else { return conversation.messages }
        return conversation.messages.map { message in
            guard message.role == .assistant else { return message }
            var message = message
            // Mapped rather than replaced wholesale: a message can carry
            // images and files alongside its text, and those have to survive.
            message.contents = message.contents?.map { content in
                guard case .text(let text) = content else { return content }
                return .text(removingThinking(from: text))
            }
            return message
        }
    }

    /// Strips `<think>` and `<thinking>` blocks, including one left open.
    ///
    /// The unterminated case is the one that matters: a model that reasons
    /// and never gets to an answer leaves the tag hanging, and everything
    /// after it is working rather than reply — that whole message is what
    /// would otherwise be sent back as though it were something the assistant
    /// had said.
    private func removingThinking(from text: String) -> String {
        var out = text
        for tag in ["think", "thinking"] {
            while let open = out.range(of: "<\(tag)>", options: [.caseInsensitive]) {
                if let close = out.range(of: "</\(tag)>", options: [.caseInsensitive],
                                         range: open.upperBound..<out.endIndex) {
                    out.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    out.removeSubrange(open.lowerBound..<out.endIndex)
                }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyThinkingSplit(to messageID: String?) {
        guard let messageID,
              let boundary = deltasAtEndOfThinking,
              streamedDeltas > 0,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              let total = conversation.messages[index].metadata["outputTokens"]?.intValue
        else { return }

        let share = Double(boundary) / Double(streamedDeltas)
        let thinking = Int(((Double(total) * share) / 10).rounded()) * 10
        conversation.messages[index].metadata["thinkingTokens"] = .int(min(thinking, total))
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

        // A superseded turn keeps unwinding after its replacement has started,
        // so it can't simply clear the flag on its way out — it would clear
        // the one the new turn just set. The token says which turn is current.
        let token = UUID()
        currentTurn = token
        ConversationViewModelStore.shared.setGenerating(true, for: file.id)

        generateTask = Task {
            defer {
                if currentTurn == token {
                    ConversationViewModelStore.shared.setGenerating(false, for: file.id)
                }
            }
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
        error = nil
        do {
            let (service, model) = try chatService()
            pinCurrentDefaults()

            var context = context
            // Lowercase to match {{datetime}} in the instructions. The lookup
            // is an exact dictionary hit, so DATETIME matched nothing and the
            // prompt went out reading "The current date is ."
            context["datetime"] = .string(Date.now.formatted())

            // Uppercase here on purpose, unlike the lowercase template
            // placeholders: this key isn't substituted into the instructions,
            // it's the one GenKit looks for to build the user_context block.
            if let profile = state.userProfile {
                context["MEMORIES"] = .string(profile)
            }

            ChatDebug.log("→ chat request | model: \(model.id) | tools: \(conversation.toolIDs.sorted().joined(separator: ", ")) | history: \(conversation.messages.count) messages")
            // The resolved prompt, not the stored template: logging the
            // template shows placeholders like {{datetime}} still in place and
            // says nothing about whether they were filled in.
            ChatDebug.log("→ system prompt (after substitution): \(PromptTemplate(conversation.instructions, with: context))")
            ChatDebug.log("→ user profile: \(state.userProfile ?? "<none set>")")
            ChatDebug.log("→ user prompt: \(prompt)")

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
            req.with(history: historyForRequest())
            req.with(tools: Toolbox.get(names: conversation.toolIDs))
            req.with(context: context)
            if !isThinkingEnabled {
                req.with(option: "think", value: .bool(false))
            }

            // Generate response stream
            var streamUpdates = 0
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
            firstDeltaAt = nil
            deltasAtEndOfThinking = nil
            liveTokensPerSecond = nil

            for try await message in stream {
                try Task.checkCancellation()
                streamUpdates += 1
                streamedDeltas += 1
                if firstDeltaAt == nil { firstDeltaAt = .now }

                // Note where reasoning ended so the totals can be split later.
                // Only scanned until found, so it costs nothing afterwards.
                if deltasAtEndOfThinking == nil, let content = message.content,
                   content.contains("</think>") || content.contains("</thinking>") {
                    deltasAtEndOfThinking = streamedDeltas
                }

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
            applyThinkingSplit(to: pending?.id)
            liveTokensPerSecond = nil

            // See generateSuggestions: a cancelled stream ends quietly, so
            // check before touching state or starting follow-up work.
            try Task.checkCancellation()

            // Reset conversation state
            conversation.state = .none

            // Just the tally. This used to dump the last eight messages in
            // full on every turn, which was how a message that had gone
            // missing from the conversation got found — but it reprints the
            // whole history once per turn, so the log grew quadratically and
            // buried the request/response lines worth reading. Each new
            // message is already announced as it arrives.
            ChatDebug.log("← stream finished after \(streamUpdates) updates | conversation now has \(conversation.messages.count) messages")

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
            // conversation now, and this cancellation was deliberate. This has
            // to come first, before anything below writes state.
            if error is CancellationError || Task.isCancelled { return }

            // Surface the failure inline and clear any in-progress state so the
            // indicator doesn't spin forever.
            conversation.state = .none
            self.error = errorMessage(for: error)
            throw Error.generationError("\(error)")
        }
    }

    /// Maps an error to a friendly, actionable message for display in the
    /// conversation. Falls back to the raw description for unexpected errors.
    private func errorMessage(for error: Swift.Error) -> String {
        if let apiError = error as? API.Error {
            switch apiError {
            case .missingService:
                return "No default chat service is selected. Choose one in Settings → Services under \"Defaults.\""
            case .missingModel:
                return "No chat model is selected for the current service. Pick one in Settings → Services."
            case .missingConfig:
                return "Missing configuration. Try restarting the app or resetting data in the menu."
            }
        }
        return "\(error)"
    }

    /// The service for Heat's own short jobs — naming a conversation, drafting
    /// follow-up suggestions.
    ///
    /// These are mechanical next to answering someone, and a smaller model
    /// handles them fine and faster. Settings already has a Summarization
    /// default for exactly this shape of work, so use it when one is chosen
    /// and fall back to the chat model when it isn't.
    private func taskService() throws -> (ChatService, Model) {
        if let summarization = try? API.shared.preferredSummarizationService() {
            return summarization
        }
        return try API.shared.preferredChatService()
    }

    func generateSuggestions() async throws {
        let (service, model) = try taskService()

        // Cached instructions
        let instruction = try state.file(Instruction.self, fileID: Defaults.instructionSuggestionsID)

        // Flattened message history
        let messages = conversation.messages
        let history = preparePlainTextHistory(messages)
        let content = PromptTemplate(instruction.instructions, with: ["history": .string(history)])

        // Initial request
        var req = ChatSessionRequest(service: service, model: model)
        req.with(history: [.init(role: .user, content: content)])

        // Never reason for this, whatever the user's Thinking setting says —
        // that setting is about answers, and this is housekeeping nobody reads
        // the working for. On a small model it isn't merely wasteful: asked to
        // suggest three replies, qwen3.5:0.8b spent 30,000 characters thinking
        // and then produced no answer at all, which arrives here as an empty
        // suggestion list an hour later. The same prompt with reasoning off
        // answers in under five seconds.
        req.with(option: "think", value: .bool(false))

        // Indicate we are suggesting
        conversation.state = .suggesting

        ChatDebug.log("→ suggestions request | model: \(model.id)")

        // Generate suggestions stream
        var lastResponse = ""
        let stream = ChatSession.shared.stream(req)
        for try await message in stream {
            try Task.checkCancellation()
            guard let content = message.content else { continue }
            lastResponse = content

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

        if conversation.suggestions.isEmpty {
            ChatDebug.log("← suggestions: none — no <suggested_replies> tag in the reply: \(unparsed(lastResponse))")
        } else {
            ChatDebug.log("← suggestions: \(conversation.suggestions)")
        }
    }

    func generateTitle() async throws {
        guard file.name == nil else { return }

        let (service, model) = try taskService()

        // Cached instructions
        let instruction = try state.file(Instruction.self, fileID: Defaults.instructionTitleID)

        // Flatted message history
        let messages = conversation.messages
        let history = preparePlainTextHistory(messages)
        let content = PromptTemplate(instruction.instructions, with: ["history": .string(history)])

        // Initial request
        var req = ChatSessionRequest(service: service, model: model)
        req.with(history: [.init(role: .user, content: content)])

        // As with suggestions: naming a conversation is not worth reasoning
        // about, and on a small model reasoning is what stops it answering.
        req.with(option: "think", value: .bool(false))

        // The model is logged at the request, not just with the result: this
        // is the leg that changes when Summarization points somewhere other
        // than the chat model, and the gap to "← title" covers both loading
        // that model and generating with it.
        ChatDebug.log("→ title request | model: \(model.id)")

        // Generate suggestions stream
        var lastResponse = ""
        let stream = ChatSession.shared.stream(req)
        for try await message in stream {
            try Task.checkCancellation()
            guard let content = message.content else { continue }
            lastResponse = content

            let name = "title"
            let result = try ContentParser.shared.parse(input: content, tags: [name])
            let tag = result.first(tag: name)
            let tagIsEmpty = tag?.content?.isEmpty ?? true

            file.name = tagIsEmpty ? nil : tag?.content
            file.modified = .now
        }

        // As above: don't let a cancelled turn fall through to saving.
        try Task.checkCancellation()

        if let name = file.name {
            ChatDebug.log("← title: \(name)")
        } else {
            ChatDebug.log("← title: none — no <title> tag in the reply: \(unparsed(lastResponse))")
        }
    }

    /// What a model actually said, when what it said couldn't be used.
    ///
    /// Title and suggestions are read out of `<title>` and `<suggested_replies>`
    /// tags, and a reply without them yields nothing at all — no error, no
    /// title, an empty suggestion list. That reads exactly like a request that
    /// never happened, when in fact it succeeded and the model simply answered
    /// in prose. Smaller models do this constantly: they write the right title
    /// and then don't wrap it. Showing the reply makes the difference between
    /// "the model is unreachable" and "this model can't follow the format"
    /// obvious at a glance.
    private func unparsed(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "<empty reply>" }
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
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
        currentTurn = nil
        ConversationViewModelStore.shared.setGenerating(false, for: file.id)
        conversation.state = .none

        let snapshot = conversation
        Task { try? await API.shared.fileUpdate(file.id, object: snapshot) }
    }

    // MARK: - Private

    @Sendable // Determine tool to execute and return response before next turn of the conversation
    private func prepareToolResponse(toolCall: ToolCall) async throws -> ToolCallResponse {
        ChatDebug.log("→ tool call: \(toolCall.function?.name ?? "unknown") | args: \(toolCall.function?.arguments ?? "<none>")")
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
