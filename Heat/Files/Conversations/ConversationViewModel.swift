import SwiftUI
import OSLog
import SharedKit
import Textual
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

    /// Which models have been asked for, least recently first. Held separately
    /// because a dictionary has no order to evict by, and evicting without one
    /// meant evicting everything.
    @ObservationIgnored private var recency: [String] = []

    /// Caps idle models so browsing many conversations doesn't hold them all
    /// in memory. A generating model is never evicted, and a view already
    /// showing an evicted model keeps its own reference.
    private let idleLimit = 8

    func model(for file: File) -> ConversationViewModel {
        recency.removeAll { $0 == file.id }
        recency.append(file.id)

        if let existing = models[file.id] {
            return existing
        }
        let model = ConversationViewModel(file: file)
        models[file.id] = model
        evictIdleModelsIfNeeded()
        return model
    }

    func removeAll() {
        models.removeAll()
        recency.removeAll()
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

    /// Drops the least recently used idle models until the cache is back inside
    /// its limit.
    ///
    /// This used to empty the cache instead of trimming it: on reaching the
    /// limit it removed *every* idle model, so opening a ninth conversation
    /// discarded the other eight. Stepping through conversations therefore
    /// re-read and re-decoded each one from disk almost every time — the very
    /// thing holding them was meant to avoid, and worst on the conversations
    /// where it costs most.
    private func evictIdleModelsIfNeeded() {
        guard models.count > idleLimit else { return }
        for id in recency {
            guard models.count > idleLimit else { break }
            guard let model = models[id], !model.isGenerating else { continue }
            models.removeValue(forKey: id)
        }
        recency.removeAll { models[$0] == nil }
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

    /// Whether the reasoning currently being written is shown.
    ///
    /// Held here rather than in the block that draws it, so the status line at
    /// the foot of the conversation can close it too. Reasoning can run for
    /// pages, and its own Hide control scrolls away with it — leaving the only
    /// way to shut it the one place you'd have to scroll back to find.
    ///
    /// Only the block still being written follows this. Finished ones keep
    /// their own state, so closing the live one doesn't shut every earlier one
    /// in the conversation.
    var isStreamingThinkingExpanded = false

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
        text = CodeFence.readableFences(in: text).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// How hard the model thinks here — this conversation's own answer, or the
    /// default when it hasn't got one.
    var thinkingEffort: ThinkingEffort {
        conversation.effort ?? state.config.thinkingEffortByDefault
    }

    /// Whether the model reasons at all, which is all the request carries.
    /// Brief is the prompt's doing, not the request's — see `ThinkingEffort`.
    var isThinkingEnabled: Bool {
        effectiveThinkingEffort.isThinking
    }

    /// Models that reason whatever they're told.
    ///
    /// GPT-OSS ignores `think: false` outright. Measured rather than assumed:
    /// Off against `gpt-oss:20b` still produced 980 characters of reasoning,
    /// the same as `true` and the same as saying nothing — and Ollama's own
    /// documentation states the trace cannot be disabled.
    ///
    /// Matched on the id because nothing the server reports distinguishes it:
    /// the capability list is the same shape as every other reasoning model's.
    /// It does report `general.architecture: "gptoss"`, which would be a better
    /// key since it survives retagging, but that isn't carried as far as
    /// `Model`. If a model is ever found that belongs here and isn't caught,
    /// this is the list to add it to.
    private static let alwaysReasoningModels = ["gpt-oss"]

    var modelAlwaysReasons: Bool {
        guard let id = selectedModel?.id.lowercased() else { return false }
        return Self.alwaysReasoningModels.contains { id.contains($0) }
    }

    /// The efforts this service can be asked for.
    ///
    /// Off is included even where it won't be honoured. It used to be dropped,
    /// on the reasoning that offering it was worse than not — which was true
    /// while the only alternative was a control that read Off while the model
    /// reasoned anyway. It can be struck through now, and a struck-through
    /// option explains itself where a missing one just leaves the menu a
    /// different length on different models.
    var availableThinkingEfforts: [ThinkingEffort] {
        selectedServiceKind.map { ThinkingEffort.offered(by: $0) } ?? ThinkingEffort.universal
    }

    /// Whether asking for no reasoning will actually be honoured.
    ///
    /// Two ways it isn't, and they differ in mechanism rather than in
    /// consequence: a local model that takes the instruction and ignores it,
    /// and a service that refuses the request outright. The control treats
    /// them alike because there's nothing for someone to do differently.
    var thinkingCannotBeTurnedOff: Bool {
        modelAlwaysReasons || modelRefusesToStopThinking
    }

    /// Whether the level in force is the substitute Off turned into, rather
    /// than something asked for. What the control says about itself differs:
    /// one is a choice, the other is the nearest thing to a choice that
    /// couldn't be honoured.
    var isStandingInForOff: Bool {
        thinkingCannotBeTurnedOff && thinkingEffort == .off
    }

    /// The kind of service answering here, which decides what the thinking
    /// control has to offer: an effort level is a thing a particular API
    /// takes, and they don't agree on what the levels are.
    var selectedServiceKind: Service.Kind? {
        resolvedChatService?.0.kind
    }

    private var resolvedChatService: (Service, Model)? {
        try? API.shared.resolvedChatService(
            serviceID: conversation.serviceID,
            modelID: conversation.modelID
        )
    }

    /// Whether the chosen model reaches the web on its own.
    ///
    /// Heat's own web search is a tool it runs itself — the model asks, Heat
    /// fetches, Heat hands back the results — so switching it off genuinely
    /// stops it. A model with search built in ignores all of that, which makes
    /// the tool switch look as though it governs something it doesn't.
    var modelSearchesTheWebItself: Bool {
        guard let (service, model) = resolvedChatService else { return false }
        return service.hasBuiltInWebSearch(modelID: model.id)
    }

    /// Whether the service will refuse to be told not to reason.
    ///
    /// Only a known refusal counts. An unrecognised model reads as nil, and
    /// nil stays quiet: the request degrades to the least reasoning if the
    /// guess is wrong, so there's nothing to warn anybody about in advance.
    var modelRefusesToStopThinking: Bool {
        guard let (service, model) = resolvedChatService else { return false }
        return service.canDisableThinking(modelID: model.id) == false
    }

    /// What the model will actually do — which is what the control should say
    /// and what the request should carry.
    ///
    /// Off on a model that can't stop becomes Brief, the least it can be asked
    /// for. That is closer to what was wanted than the alternative: sending
    /// `false` to GPT-OSS is ignored and lands on its *medium* default, so
    /// asking for none currently gets more reasoning than asking for little.
    var effectiveThinkingEffort: ThinkingEffort {
        // Said in the terms this service uses. A conversation keeps the effort
        // it was given and can be moved to another provider afterwards, whose
        // levels are its own — so what was asked for is translated rather than
        // sent somewhere it means nothing.
        let chosen = selectedServiceKind.map { thinkingEffort.offered(by: $0) } ?? thinkingEffort
        guard chosen == .off, thinkingCannotBeTurnedOff else { return chosen }
        // The least it will do, which is what the request will ask for. `off`
        // is skipped explicitly: it's the first level a service offers, and
        // answering with it here would say nothing had changed.
        return availableThinkingEfforts.first { $0 != .off } ?? .brief
    }

    /// Switches a tool on or off for this conversation alone.
    ///
    /// Until now a conversation could only gain tools — a template's set was
    /// merged in and nothing took it out again, so one use of a template armed
    /// a tool for the life of the conversation. The Assistant instruction is
    /// still where the default for new conversations lives; this doesn't touch
    /// it, so turning something off here doesn't quietly rewrite a setting that
    /// applies everywhere else.
    func setTool(_ toolID: String, enabled: Bool) {
        if enabled {
            conversation.toolIDs.insert(toolID)
        } else {
            conversation.toolIDs.remove(toolID)
        }
        // Marks the set as this conversation's own, so the refresh that keeps an
        // unused conversation current stops overwriting it.
        conversation.toolsChosen = true
        file.modified = .now
        persistConversation()
        let names = conversation.toolIDs.sorted().joined(separator: ", ")
        ChatDebug.log("⚒︎ tools for this conversation: \(names.isEmpty ? "none" : names)")
    }

    /// Settles the question for this conversation, so it stops following the
    /// default. Turning it back to match the default doesn't resume following
    /// it: an explicit choice stays explicit, which is the point of making it.
    func setThinkingEffort(_ effort: ThinkingEffort) {
        conversation.thinkingEffort = effort
        // Cleared rather than left behind: the two would otherwise disagree,
        // and `effort` prefers this one, so a stale value would be a trap for
        // anyone reading the file.
        conversation.thinkingEnabled = nil
        persistConversation()
        ChatDebug.log("◇ thinking effort for this conversation: \(effort.rawValue)")
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

    /// Takes a fresh copy of the Assistant instruction while the conversation
    /// still hasn't said anything.
    ///
    /// A conversation carries its own copy of the system prompt and tool set,
    /// taken when the file was created — and ⌘N creates the file before a word
    /// is typed. So an untouched conversation sitting in the sidebar from last
    /// week was holding last week's prompt, and editing the instruction in
    /// Settings appeared to do nothing until a conversation was made after the
    /// edit. Refreshing here puts these on the same footing as the model and
    /// the reasoning setting: current until first used, then fixed.
    ///
    /// Still fixed from the first message rather than followed forever. The
    /// answers in a conversation were produced under particular instructions,
    /// and rewriting them afterwards would leave a transcript that no longer
    /// makes sense as a whole.
    private func refreshInstructionIfUnused() {
        guard conversation.messages.isEmpty else { return }
        guard let instruction = try? state.file(Instruction.self, fileID: Defaults.instructionAssistantID) else {
            return
        }
        conversation.instructions = instruction.instructions

        // Unless somebody has already picked for this conversation. Refreshing
        // over an explicit choice was worse than the staleness it was meant to
        // fix: switching a tool on in a new conversation and sending lost the
        // choice between the click and the request.
        if conversation.toolsChosen != true {
            conversation.toolIDs = instruction.toolIDs
        }
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
        if conversation.effort == nil {
            conversation.thinkingEffort = state.config.thinkingEffortByDefault
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

    /// Whether this model has read its conversation from disk yet. Needed
    /// because a fresh model already holds the file it was created from —
    /// matching dates alone would say there's nothing to load.
    @ObservationIgnored private var hasLoadedFromDisk = false

    /// Brings the conversation in from disk, if there's anything new there.
    ///
    /// Called every time the view appears, which with cached view models is
    /// every switch back to a thread — and reassigning `conversation`
    /// invalidates everything observing it, identical content or not, which
    /// made returning to a thread cost as much as opening it cold. The model
    /// bumps `file.modified` itself whenever it writes, so a date that matches
    /// means the copy in memory is the copy on disk, and there is nothing to
    /// do. Dates that differ always load: the stale direction fails safe.
    ///
    /// A turn in flight owns the conversation in memory outright — it is
    /// further along than the copy on disk, and reading over it would drop
    /// the prompt and the answer arriving right now.
    func load(_ file: File) {
        guard !isGenerating else { return }
        if hasLoadedFromDisk, file.modified == self.file.modified { return }
        do {
            let conversation = try state.file(Conversation.self, fileID: file.id)
            self.conversation = conversation
            self.file = file
            hasLoadedFromDisk = true

            // A find can be set up before the conversation is here: opening a
            // search result asks the store for a view model, which arrives
            // empty, and hands it the query — so the matches were counted
            // against nothing and stayed at nothing until ⌘F recounted them.
            if isFinding {
                updateFindMatches()
            }
        } catch {
            state.log(error: error)
        }
    }

    /// What each run measured last time it was drawn, so a run off screen can
    /// reserve its space without being laid out. See `RunHeightCache`.
    ///
    /// Held here rather than in the view for the same reason the find state is:
    /// the view is torn down when you switch threads, and throwing the
    /// measurements away would make coming back cost a cold open. Marked
    /// `@ObservationIgnored` because it is written to during layout — anything
    /// observing it would schedule a render pass from inside one.
    @ObservationIgnored let runHeights = RunHeightCache()

    /// One selection across the whole conversation.
    ///
    /// Every message is its own `StructuredText`, and on macOS every run is
    /// its own hosting view with an environment of its own — so without a
    /// scope to share, each of them kept a live selection independently, and
    /// selecting in one message left the last selection standing in another.
    /// Held here so it lasts as long as the conversation does.
    @ObservationIgnored let selectionScope = TextSelectionScope()

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
    /// The context this conversation's model will actually be given.
    ///
    /// In order of how much they're worth believing: a length chosen for this
    /// model, which is sent with the request and so decides the matter; what
    /// the model was last seen loaded with; and failing both, the maximum it
    /// was built for — which the server will very likely not grant, so it's a
    /// last resort rather than an answer.
    var effectiveContextLength: Int? {
        guard let model = selectedModel else { return nil }
        if let serviceID = conversation.serviceID,
           let chosen = state.config.contextLength(serviceID: serviceID, modelID: model.id) {
            return chosen
        }
        return model.loadedContextWindow ?? model.contextWindow
    }

    /// How much of the model's context this conversation is occupying.
    ///
    /// Counted from what the server reported rather than estimated: every
    /// response carries the prompt size it was evaluated against, so the last
    /// one says exactly how much context the conversation took, and adding its
    /// own output gives what the next prompt starts from. No tokenizer, and no
    /// guessing at a model's particular one.
    ///
    /// Nil until there's something to measure against — no reply yet, or a
    /// service that doesn't report a context length. Better nothing than a bar
    /// showing a number nobody can stand behind.
    var contextUsage: (used: Int, limit: Int)? {
        guard let limit = effectiveContextLength, limit > 0 else { return nil }
        guard let last = conversation.messages.last(where: { $0.role == .assistant }),
              let input = last.metadata["inputTokens"]?.intValue,
              let output = last.metadata["outputTokens"]?.intValue
        else { return nil }

        // Reasoning counts against the reply that produced it but won't be
        // sent again, so it shouldn't count towards what the next turn costs.
        // The split is approximate — see applyThinkingSplit — which is why
        // this is a gauge rather than a readout.
        var carried = output
        if state.config.stripThinkingFromContext,
           let thinking = last.metadata["thinkingTokens"]?.intValue {
            carried = max(0, output - thinking)
        }
        return (used: input + carried, limit: limit)
    }

    /// The messages still sent in full: everything after the compaction point.
    ///
    /// Nothing is deleted, so a boundary pointing at a message that has gone
    /// leaves the whole conversation active rather than silently hiding it.
    var activeMessages: [Message] {
        guard let boundary = conversation.compactedThroughMessageID,
              let index = conversation.messages.firstIndex(where: { $0.id == boundary })
        else { return conversation.messages }
        return Array(conversation.messages.dropFirst(index + 1))
    }

    /// The run the compaction point falls in, so the transcript can mark where
    /// the model's view of the conversation begins.
    var compactedThroughRunID: String? {
        guard let boundary = conversation.compactedThroughMessageID else { return nil }
        return runs.first { run in run.messages.contains { $0.id == boundary } }?.id
    }

    /// Whether there is anything worth compacting: messages the model is still
    /// being sent in full.
    var canCompact: Bool {
        !activeMessages.isEmpty && !isGenerating
    }

    /// The system prompt, with anything compacted away described in it.
    ///
    /// Carried in the system prompt rather than as a message in the history.
    /// It isn't something anybody said, and putting it in the transcript means
    /// choosing a role to attribute it to — either inventing a user turn that
    /// would sit next to a real one, or putting words in the assistant's mouth.
    private func systemForRequest(context: [String: Value]) -> String {
        var instructions = PromptTemplate(conversation.instructions, with: context)

        if let steer = briefThinkingSteer() {
            instructions += "\n\n\(steer)"
        }

        guard let summary = conversation.contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty
        else { return instructions }

        return """
            \(instructions)

            <conversation_summary>
            The earlier part of this conversation isn't shown in full. These are \
            notes on what happened, for your use:

            \(summary)
            </conversation_summary>
            """
    }

    /// The line that keeps reasoning short, when this conversation asked for
    /// brief thinking.
    ///
    /// Added to the prompt as it goes out, never to the stored instruction:
    /// effort is a per-conversation choice that can change between messages,
    /// and writing it into the Assistant prompt would apply it everywhere and
    /// leave it there.
    ///
    /// This is the whole of what Brief does. Ollama's graded `think` was
    /// measured across four local models and only one honoured it — see
    /// `ThinkingEffort` for the numbers.
    private func briefThinkingSteer() -> String? {
        guard effectiveThinkingEffort == .brief else { return nil }
        guard let instruction = try? state.file(Instruction.self, fileID: Defaults.instructionThinkingBriefID) else {
            return nil
        }
        let text = instruction.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

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
        let messages = activeMessages
        guard state.config.stripThinkingFromContext else { return messages }
        return messages.map { message in
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

    // MARK: - Find

    /// Whether the find bar is up for this conversation.
    ///
    /// Held here rather than in the view so it survives the view being torn
    /// down and rebuilt — switching away from a conversation and back keeps
    /// the search that was running, the same reason the view model is shared.
    var isFinding = false

    private(set) var findQuery = ""
    private(set) var findMatches: [ConversationSearch.Match] = []
    private(set) var findIndex = 0

    /// The message the find bar is pointing at, which the list scrolls to and
    /// the message draws itself against.
    var currentFindMessageID: String? {
        guard isFinding, findMatches.indices.contains(findIndex) else { return nil }
        return findMatches[findIndex].messageID
    }

    /// The run holding the current match, which is what the list can actually
    /// be scrolled to — a run is a row, and only rows are scroll anchors.
    var currentFindRunID: String? {
        guard let messageID = currentFindMessageID else { return nil }
        return runs.first { run in run.messages.contains { $0.id == messageID } }?.id
    }

    /// The match being looked at, identified so that stepping between two in
    /// the same message counts as a change.
    ///
    /// The run id can't stand in for this: two matches in one run share it, so
    /// watching the run meant stepping between them moved the mark and left
    /// the view where it was.
    var currentFindMatchID: String? {
        guard isFinding, findMatches.indices.contains(findIndex) else { return nil }
        return findMatches[findIndex].id
    }

    /// Roughly how far down its run the current match sits, from 0 at the top
    /// to 1 at the bottom.
    ///
    /// Measured in characters, which is a guess — a code block or a picture
    /// occupies height out of all proportion to the text around it. It is the
    /// only clue available from outside the text engine, though, and a guess
    /// is enough here: the view scrolls so the match is *somewhere on screen*,
    /// which a whole viewport of tolerance forgives a lot of.
    ///
    /// Without it, stepping between two matches in one long message moved the
    /// mark and not the view, which reads as a button that doesn't work.
    var currentFindFractionInRun: Double? {
        guard isFinding, findMatches.indices.contains(findIndex) else { return nil }
        let match = findMatches[findIndex]
        guard let run = runs.first(where: { run in
            run.messages.contains { $0.id == match.messageID }
        }) else { return nil }

        var precedingLength = 0
        var offsetInRun: Int?
        for message in run.messages {
            if message.id == match.messageID {
                offsetInRun = precedingLength + match.characterOffset
            }
            precedingLength += ConversationSearch.searchableText(of: message).count
        }

        guard let offsetInRun, precedingLength > 0 else { return nil }
        return min(max(Double(offsetInRun) / Double(precedingLength), 0), 1)
    }

    /// Which occurrence inside the given message the find bar is pointing at,
    /// or nil if the current match is in some other message.
    ///
    /// Counted within the message rather than across the conversation, because
    /// that's the number the message itself can act on: it marks its own
    /// occurrences and needs to know which of them is the one being looked at.
    func currentFindOrdinal(in messageID: String) -> Int? {
        guard isFinding, findMatches.indices.contains(findIndex) else { return nil }
        let match = findMatches[findIndex]
        guard match.messageID == messageID else { return nil }
        return match.ordinal
    }

    func beginFind() {
        isFinding = true
        updateFindMatches()
    }

    func endFind() {
        isFinding = false
        findQuery = ""
        findMatches = []
        findIndex = 0
    }

    func setFindQuery(_ query: String) {
        findQuery = query
        updateFindMatches()
    }

    func findNext() {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + 1) % findMatches.count
    }

    func findPrevious() {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
    }

    /// Recomputed from scratch on every change rather than kept in step.
    ///
    /// A conversation is a few hundred kilobytes at most and the scan is one
    /// pass over it; state that had to be invalidated as messages stream in
    /// would be a standing source of wrong answers.
    private func updateFindMatches() {
        findMatches = ConversationSearch.matches(for: findQuery, in: conversation.messages)
        // Clamped rather than reset: typing another letter usually narrows the
        // same match rather than meaning a fresh search.
        findIndex = min(findIndex, max(findMatches.count - 1, 0))
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
    func submit(chat prompt: String, images: [URL] = [], context: [String: Value] = [:], toolIDs: Set<String>? = nil) {
        // Intercepted before a message is made from it: these act on the
        // conversation rather than being said in it. Not when something is
        // attached, though — a picture with "/clear" typed beside it is a
        // message, and running the command would throw the picture away.
        if images.isEmpty, let command = SlashCommand(prompt) {
            perform(command)
            return
        }
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
                    conversation = stored
                    hasLoadedFromDisk = true
                }

                // Before the tools below are merged in, or a template's tools
                // would be wiped by the refresh on the very turn they were
                // chosen for.
                refreshInstructionIfUnused()

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

                try await generate(chat: prompt, images: images, context: context)
            } catch {
                guard !Task.isCancelled else { return }
                state.log(error: error)
            }
        }
    }

    /// Generate a response using text as the only input. Add context—often memories—to augment the system prompt. Optionally force a tool call.
    func generate(chat prompt: String, images: [URL] = [], context: [String: Value] = [:], toolChoice: Tool? = nil) async throws {
        error = nil
        currentJob = .answer
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

            // Effort and the reply ceiling ride along because they're the two
            // settings that differ per service, and the ones a refusal is
            // most often about.
            let ceiling = conversation.serviceID
                .flatMap { state.config.maxTokens(serviceID: $0) }
                .map(String.init) ?? "provider default"
            ChatDebug.log("→ chat request | service: \(selectedServiceKind?.rawValue ?? "unknown") | model: \(model.id) | effort: \(effectiveThinkingEffort.rawValue) (asked \(thinkingEffort.rawValue)) | longest reply: \(ceiling) | tools: \(conversation.toolIDs.sorted().joined(separator: ", ")) | images: \(images.count) | history: \(conversation.messages.count) messages")

            // Named individually, because an image that fails to reach the
            // model is indistinguishable from one it looked at and didn't
            // recognise — the reply reads the same either way.
            for url in images {
                let size = (try? Data(contentsOf: url).count) ?? -1
                ChatDebug.log("→ image: \(url.lastPathComponent) | \(size < 0 ? "UNREADABLE at \(url.path)" : "\(size) bytes")")
            }
            // The resolved prompt, not the stored template: logging the
            // template shows placeholders like {{datetime}} still in place and
            // says nothing about whether they were filled in.
            ChatDebug.log("→ system prompt (after substitution): \(systemForRequest(context: context))")
            ChatDebug.log("→ user profile: \(state.userProfile ?? "<none set>")")
            ChatDebug.log("→ user prompt: \(prompt)")

            // New user message
            // PNG because that's what the picker writes. The format travels
            // with the image as its media type, so claiming JPEG describes the
            // file wrongly to any service that reads it.
            let imageContent = images.map { Message.Content.image(.init(url: $0, format: .png)) }
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
            req.with(system: systemForRequest(context: context))
            req.with(history: historyForRequest())
            req.with(tools: Toolbox.get(names: conversation.toolIDs))
            req.with(context: context)
            // Only when one was chosen for this model. Saying nothing is what
            // lets the server apply its own default, and naming a value costs
            // a reload whenever it differs from what's already loaded.
            if let serviceID = conversation.serviceID,
               let contextLength = state.config.contextLength(serviceID: serviceID, modelID: model.id) {
                req.with(option: "num_ctx", value: .int(contextLength))
            }
            // The shared vocabulary, sent as it stands. Each service turns it
            // into whatever its own API takes — a `think` level for a local
            // model, a thinking mode and an effort for Anthropic — because
            // they don't agree on what the levels are, and this is not the
            // place to know that.
            req.with(option: "effort", value: .string(effectiveThinkingEffort.rawValue))

            // What a single reply may generate. Bounds the reasoning and the
            // answer together where a model reasons, so it can't be left at a
            // figure chosen for replies alone.
            if let serviceID = conversation.serviceID,
               let maxTokens = state.config.maxTokens(serviceID: serviceID) {
                req.with(option: "max_tokens", value: .int(maxTokens))
            }

            // Generate response stream
            var streamUpdates = 0
            let stream = ChatSession.shared.stream(req, runLoopLimit: Self.toolRoundLimit, timeouts: Self.turnTimeouts)
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
            noteModelUnavailableIfRefused(error)
            self.error = errorMessage(for: error)

            // The prompt is saved as soon as it's sent, so the conversation on
            // disk says `.processing`. Clearing that only in memory leaves a
            // thread that reads as generating for good: reopening it, or
            // restarting the app, brings the indicator back with no turn
            // behind it. Best-effort — a failed save must not replace the
            // failure being reported.
            try? await API.shared.fileUpdate(file.id, object: conversation)

            throw Error.generationError("\(error)")
        }
    }

    /// Stops offering a model the service has said it won't serve.
    ///
    /// Only the attempt can tell. A withdrawn model stays in OpenAI's model
    /// list, and its published deprecation notice names the dated snapshot
    /// while the list offers the undated alias — so neither can be checked
    /// against the other without also hiding models that still work. The
    /// refusal names the model that was actually asked for.
    ///
    /// Narrow on purpose: gone, or never there. Everything else — a bad key,
    /// a server that didn't answer, a rate limit — is about the moment rather
    /// than the model, and hiding a model over a passing failure would be
    /// worse than the failure. Reversible from the service's pane either way.
    private func noteModelUnavailableIfRefused(_ error: Swift.Error) {
        let message = "\(error)".lowercased()
        let refused = message.contains("has been deprecated")
            || message.contains("does not exist")
            || message.contains("has been removed")
        guard refused, let (service, model) = resolvedChatService else { return }

        var config = API.shared.config
        guard !config.isModelUnavailable(model, in: service) else { return }
        config.markModelUnavailable(model, in: service)
        Task { try? await API.shared.configUpdate(config) }

        ChatDebug.log("← \(service.name) won't serve \(model.id); no longer offering it")
    }

    /// Which configured service a failed request was made to, worked out from
    /// the URL the error names.
    ///
    /// Matched on host and port, and where several services share those, on
    /// whichever one's path the failing URL is under — two OpenAI-compatible
    /// services on one machine differ only by their path.
    private func failingService(for error: NSError) -> Service? {
        let url = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }
        guard let url, let host = url.host() else { return nil }

        let candidates = API.shared.config.services.filter { service in
            guard let serviceURL = URL(string: service.host) else { return false }
            return serviceURL.host() == host && serviceURL.port == url.port
        }
        if candidates.count > 1 {
            let byPath = candidates.first { service in
                guard let path = URL(string: service.host)?.path(), !path.isEmpty else { return false }
                return url.path().hasPrefix(path)
            }
            if let byPath { return byPath }
        }
        return candidates.first
    }

    /// What a turn is doing, so a failure can say which part of it failed.
    ///
    /// An answer arriving and then a follow-up job failing reads, without
    /// this, as though the answer itself had gone wrong.
    enum TurnJob {
        case answer
        case suggestions
        case title

        var failurePrefix: String {
            switch self {
            case .answer: ""
            case .suggestions: "Couldn't draft follow-up suggestions. "
            case .title: "Couldn't name this conversation. "
            }
        }
    }

    @ObservationIgnored private var currentJob: TurnJob = .answer

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

        // Whether the service could be reached at all. A local server that
        // isn't running refuses the connection immediately and cleanly, but
        // the error says so as a wall of NSError user info with "Could not
        // connect to the server" somewhere in the middle of it — which in a
        // conversation reads as noise rather than as the one thing it needs
        // to say, which is that nothing is listening.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            // Named from the URL that actually failed, which the error carries.
            //
            // Asking which service this *conversation* answers with was wrong
            // whenever the failure came from one of the jobs that follow an
            // answer: those go to the Summarization service, so a working
            // Anthropic conversation whose local Ollama was down reported that
            // Anthropic hadn't answered — sending someone to check a server
            // that had just replied perfectly well. Reading the URL covers
            // titles, suggestions and anything added later without any of them
            // having to say which service they used.
            let service = failingService(for: nsError)
                ?? (try? API.shared.resolvedChatService(
                    serviceID: conversation.serviceID,
                    modelID: conversation.modelID
                ).0)
            let name = service?.name ?? "The model service"
            let host = service.map { " at \($0.host)" } ?? ""
            let job = currentJob.failurePrefix

            switch nsError.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost:
                return "\(job)\(name) didn't answer\(host). Check that it's running."
            case NSURLErrorTimedOut:
                return "\(job)\(name) took too long to answer\(host). It may be loading a model, or it may have stopped responding."
            default:
                return "\(job)\(name) couldn't be reached\(host): \(nsError.localizedDescription)"
            }
        }

        if let sessionError = error as? ChatSessionError {
            let name = (try? API.shared.resolvedChatService(
                serviceID: conversation.serviceID,
                modelID: conversation.modelID
            ).0.name) ?? "The model service"
            switch sessionError {
            case .maxRunLoopLimit:
                // Not a token ceiling, whatever "limit" suggests: the model
                // answered every tool result with another tool call, round
                // after round, and never got to an answer. Everything it did
                // up to then is kept in the thread.
                return "The model called tools \(Self.toolRoundLimit) times in a row without finishing an answer, so Heat stopped it. What it found is kept above; try asking again, or with Tools off."
            case .timedOut(let seconds, let afterTools):
                let allowed = seconds >= 120 ? "\(Int(seconds / 60)) minutes" : "\(Int(seconds)) seconds"
                return afterTools
                    ? "\(name) didn't start answering within \(allowed) of getting the tool results. Reading them can take a local model a while; what the tools found is kept above."
                    : "\(name) didn't start answering within \(allowed). It may be loading a model, or it may have stopped responding."
            default:
                return "\(sessionError)"
            }
        }

        return "\(error)"
    }

    /// How many rounds of tool calls a single turn may run before Heat
    /// stops it — each round being a tool result answered with another call.
    ///
    /// A ceiling on rounds, not on tokens. Ten is gen-kit's default, named
    /// here so the message that reports it can say the number.
    private static let toolRoundLimit = 10

    /// How long a round may take to start answering.
    ///
    /// A minute for the first token of a turn, which has never been hit.
    /// Five for a round that follows tool results, because the model is
    /// reading everything the tools returned before it can say a word — a
    /// turn with ten searches behind it took a local 27B model longer than
    /// a minute over that, and the minute was the whole of what it got.
    /// The session's own inactivity timeout (`API`) sits at the larger
    /// figure so it never cuts in first.
    private static let turnTimeouts = ChatSession.RoundTimeouts(firstToken: 60, afterTools: 300)

    /// For jobs whose prompt is large by nature — condensing a whole
    /// conversation, concluding from a long stretch of reasoning — the
    /// first token gets the longer allowance.
    private static let heavyPromptTimeouts = ChatSession.RoundTimeouts(firstToken: 300)

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
        currentJob = .suggestions
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
        req.with(option: "effort", value: .string(ThinkingEffort.off.rawValue))

        // Indicate we are suggesting
        conversation.state = .suggesting

        ChatDebug.log("→ suggestions request | model: \(model.id)")

        // Generate suggestions stream
        var lastResponse = ""
        let stream = ChatSession.shared.stream(req, timeouts: Self.turnTimeouts)
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

        // Suggestions are a list, so a salvaged tag has to hold more than one
        // line — otherwise a model that answered in prose would have its one
        // sentence offered as a reply to send.
        if conversation.suggestions.isEmpty, let salvaged = salvagedTag(from: lastResponse) {
            let lines = salvaged.content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if lines.count > 1 {
                conversation.suggestions = lines
                file.modified = .now
                ChatDebug.log("← suggestions taken from <\(salvaged.name)>, which isn't <suggested_replies>")
            }
        }

        if conversation.suggestions.isEmpty {
            ChatDebug.log("← suggestions: none — no usable tag in the reply: \(unparsed(lastResponse))")
        } else {
            ChatDebug.log("← suggestions: \(conversation.suggestions)")
        }
    }

    func generateTitle() async throws {
        currentJob = .title
        // The copy held here was taken when the conversation was opened, so a
        // rename since then is on disk and not in it. That mattered twice over:
        // the guard below read the old name and named an already-named
        // conversation, and the save at the end of the turn wrote the whole
        // stale record back — which is why renaming a thread lasted exactly
        // until its next message.
        if let stored = try? API.shared.file(file.id) {
            file = stored
        }
        guard file.name == nil else { return }

        // Two attempts at most. What this recovers from is a reply carrying no
        // usable tag, which is a sampling accident rather than a settled fact
        // about the model — the same request often lands the second time, and
        // naming a conversation is one short call to the summarization model.
        //
        // It works *because* nothing pins a temperature on this request. An
        // identical sample would fail identically, so anyone adding one here
        // should expect the retry to stop earning its keep.
        for attempt in 1...2 {
            let outcome: TitleOutcome
            do {
                outcome = try await attemptTitle(attempt)
            } catch {
                // A cancelled turn is deliberate; it must not try again, and it
                // must not report a failure either.
                if error is CancellationError || Task.isCancelled { throw error }
                guard attempt == 1 else { throw error }
                ChatDebug.log("← title attempt 1 failed (\(error)) — trying once more")
                continue
            }

            switch outcome {
            case .named, .declined:
                return
            case .unusable:
                try Task.checkCancellation()
                if attempt == 1 {
                    ChatDebug.log("← title attempt 1 was unusable — trying once more")
                }
            }
        }
    }

    /// How an attempt at naming a conversation turned out.
    private enum TitleOutcome {
        /// A title, which is the end of it.
        case named

        /// A well-formed but empty `<title>`, which the instruction explicitly
        /// asks for when a conversation has no clear topic — greetings, thanks,
        /// a question too vague to summarise.
        ///
        /// **This is an answer, not a failure.** Measured on the shape titles
        /// are actually generated on — one exchange, right after the first turn
        /// — the model declines about a third of thin conversations and titles
        /// every substantial one (20/20). Retrying a decline would cost a
        /// second call on the commonest thin case and still, correctly, produce
        /// no title.
        case declined

        /// Nothing to work with: no tag, or a mangled one. The only outcome
        /// worth another draw, since it's a sampling accident.
        case unusable
    }

    private func attemptTitle(_ attempt: Int) async throws -> TitleOutcome {
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
        req.with(option: "effort", value: .string(ThinkingEffort.off.rawValue))

        // The model is logged at the request, not just with the result: this
        // is the leg that changes when Summarization points somewhere other
        // than the chat model, and the gap to "← title" covers both loading
        // that model and generating with it.
        ChatDebug.log("→ title request | model: \(model.id)\(attempt > 1 ? " | attempt \(attempt)" : "")")

        // Generate suggestions stream
        var lastResponse = ""
        let stream = ChatSession.shared.stream(req, timeouts: Self.turnTimeouts)
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

        // A title is one short line, so a salvaged tag has to look like one.
        // Without that, a model that wrapped a paragraph in <answer> would name
        // the conversation with the paragraph.
        if file.name == nil, let salvaged = salvagedTag(from: lastResponse),
           !salvaged.content.contains("\n"), salvaged.content.count <= 120 {
            file.name = salvaged.content
            file.modified = .now
            ChatDebug.log("← title: \(salvaged.content) — taken from <\(salvaged.name)>, which isn't <title>")
        }

        if let name = file.name {
            ChatDebug.log("← title: \(name)\(attempt > 1 ? " (attempt \(attempt))" : "")")
            return .named
        }

        // Read once more from the finished reply rather than trusting what the
        // stream left behind: mid-stream, an unclosed <title> also parses as an
        // empty one, and that would read as a decline.
        let closingTag = (try? ContentParser.shared.parse(input: lastResponse, tags: ["title"]))?
            .first(tag: "title")
        if let closingTag, closingTag.hasClosingTag {
            ChatDebug.log("← title: none — the model judged there was no clear topic")
            return .declined
        }

        if attempt > 1 {
            // The first attempt's miss is already logged by the caller, which
            // says it's about to try again — saying "none" there would read as
            // the end of the story.
            ChatDebug.log("← title: none after \(attempt) attempts — no usable tag in the reply: \(unparsed(lastResponse))")
        }
        return .unusable
    }

    /// Content from whatever tag a reply used, when it didn't use the one it
    /// was asked for.
    ///
    /// A model that can't quite hold a format usually produces the right answer
    /// in the wrong wrapper — `<topic>` where `<title>` was asked for,
    /// `<replies>` for `<suggested_replies>`. Both were seen from models in
    /// ordinary use. Taking the tag it did use turns a near miss into a result
    /// instead of nothing at all.
    ///
    /// Run once, after a stream has ended having found nothing, so it costs a
    /// single pass over a short reply rather than a pass per token.
    ///
    /// Reasoning tags are skipped: that's the model's working, and a model that
    /// reasoned and then failed to tag its answer would otherwise have its
    /// scratch notes promoted to the answer.
    private func salvagedTag(from response: String) -> (name: String, content: String)? {
        let ignored: Set<String> = ["think", "thinking", "reflection", "scratchpad", "reasoning"]
        var remainder = Substring(response)

        while let open = remainder.firstMatch(of: /<([A-Za-z][A-Za-z0-9_-]*)>/) {
            let name = String(open.1)
            let afterOpen = remainder[open.range.upperBound...]

            // An unclosed tag tells us nothing about where its content ends.
            guard let close = afterOpen.range(of: "</\(name)>") else {
                remainder = afterOpen
                continue
            }
            let content = plainText(afterOpen[..<close.lowerBound])
            if !ignored.contains(name.lowercased()), !content.isEmpty {
                return (name, content)
            }
            remainder = afterOpen[close.upperBound...]
        }
        return nil
    }

    /// The text inside a salvaged tag, without any markup it wrapped.
    ///
    /// The outer tag is the answer's wrapper; anything nested inside it is
    /// decoration the model added, and taking the content whole would put
    /// `<b>THIS</b> is a title` in the sidebar. Only well-formed tags are
    /// removed, so a title that genuinely reads "a < b" keeps its bracket.
    ///
    /// Runs of spaces are collapsed where a tag used to sit, but line breaks
    /// are left alone — suggestions are one per line, and joining them would
    /// turn a list into a sentence.
    private func plainText(_ content: some StringProtocol) -> String {
        String(content)
            .replacing(/<\/?[A-Za-z][A-Za-z0-9_-]*(\s[^>]*)?>/, with: "")
            .replacing(/[ \t]{2,}/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Commands

    func perform(_ command: SlashCommand) {
        switch command {
        case .compact(let guidance):
            compact(guidance: guidance)
        case .clear:
            clearContext()
        }
    }

    /// Folds everything sent so far into notes, and starts the model reading
    /// from after them.
    ///
    /// The transcript is untouched. What changes is where the model begins, so
    /// scrolling back still shows the whole conversation while the next request
    /// carries notes in place of it.
    func compact(guidance: String? = nil) {
        guard canCompact else { return }

        error = nil
        generateTask?.cancel()

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
                try await generateCompaction(guidance: guidance)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                conversation.state = .none
                self.error = errorMessage(for: error)
                state.log(error: error)
            }
        }
    }

    /// Hands the model a blank slate without summarizing anything.
    ///
    /// Immediate and local: there's nothing to generate, so it doesn't go
    /// through a turn. The messages stay put, as with compaction — this only
    /// says the model shouldn't be shown them.
    func clearContext() {
        guard !isGenerating, let last = conversation.messages.last else { return }
        conversation.compactedThroughMessageID = last.id
        conversation.contextSummary = nil
        conversation.suggestions = []
        file.modified = .now
        persistConversation()
        ChatDebug.log("✂︎ context cleared | \(conversation.messages.count) messages left in the transcript, none sent")
    }

    private func generateCompaction(guidance: String?) async throws {
        let (service, model) = try taskService()
        let instruction = try state.file(Instruction.self, fileID: Defaults.instructionCompactionID)

        // What the model is currently being sent, plus any notes already
        // standing in for what came before — so compacting twice folds the
        // earlier notes in rather than dropping them.
        var history = preparePlainTextHistory(activeMessages)
        if let existing = conversation.contextSummary, !existing.isEmpty {
            history = """
                Notes on the conversation before this point:
                \(existing)

                \(history)
                """
        }

        // Phrased here rather than in the template so the prompt reads as
        // ordinary prose when nobody asked for anything in particular.
        let guidanceSection = guidance.map {
            "\nThe user has asked you to be sure to carry over the following: \($0)\n"
        } ?? ""

        let content = PromptTemplate(instruction.instructions, with: [
            "history": .string(history),
            "guidance": .string(guidanceSection),
        ])

        var req = ChatSessionRequest(service: service, model: model)
        req.with(history: [.init(role: .user, content: content)])
        req.with(option: "effort", value: .string(ThinkingEffort.off.rawValue))

        conversation.state = .suggesting
        ChatDebug.log("→ compaction request | model: \(model.id) | folding \(activeMessages.count) messages")

        var summary: String?
        var lastResponse = ""
        let stream = ChatSession.shared.stream(req, timeouts: Self.heavyPromptTimeouts)
        for try await message in stream {
            try Task.checkCancellation()
            guard let content = message.content else { continue }
            lastResponse = content

            let result = try ContentParser.shared.parse(input: content, tags: ["summary"])
            if let text = result.first(tag: "summary")?.content, !text.isEmpty {
                summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        try Task.checkCancellation()

        conversation.state = .none

        // A conversation is not worth losing to a model that wouldn't answer in
        // the requested shape. Nothing moves unless there are notes to move it
        // to, and the log says what came back instead.
        guard let summary, !summary.isEmpty else {
            ChatDebug.log("← compaction produced no <summary> tag, nothing compacted: \(unparsed(lastResponse))")
            error = "Couldn't compact: the model didn't return a summary. Try again, or use a more capable Summarization model."
            return
        }

        conversation.contextSummary = summary
        conversation.compactedThroughMessageID = conversation.messages.last?.id
        conversation.suggestions = []
        file.modified = .now
        persistConversation()

        ChatDebug.log("← compaction: folded away \(conversation.messages.count) messages into \(summary.count) characters")
    }

    /// Stops the current turn at the user's request.
    ///
    /// Unlike the cancellation that happens when a new prompt supersedes a
    /// turn, nothing is about to take ownership of the conversation here, so
    /// this resets the state itself and saves whatever did arrive rather than
    /// discarding a partial answer.
    /// Whether a turn is far enough along that its reasoning could be cut
    /// short — the model is thinking and hasn't started answering.
    var canAnswerNow: Bool {
        isGenerating && isReasoning && partialReasoning != nil
    }

    /// Stops the model reasoning and asks it to answer from what it has.
    ///
    /// Ollama offers nothing for this: a generation cannot be told to stop
    /// thinking and start answering, so the turn is cancelled and reissued.
    /// What makes that cheap rather than wasteful is that the reasoning
    /// already written is handed back — the model doesn't start again, it
    /// concludes.
    ///
    /// The reasoning travels as an ordinary assistant turn, which was the one
    /// shape that behaved on every model tested. Prefilling a closed `<think>`
    /// block is faster on GPT-OSS but leaks stray tags into the answer on
    /// models that write reasoning inline, and it leans on prefill continuation
    /// that varies by template. A `thinking` field on an input message is
    /// accepted and ignored outright.
    ///
    /// The nudge is sent and not stored, like the Brief steer: it's an
    /// instruction about this one reply, not something said in the
    /// conversation.
    func answerNow() {
        guard canAnswerNow else { return }

        // Counted before cancelling, because cancelling is what makes it
        // uncountable: the server reports its totals only on a final chunk,
        // which a cancelled stream never sends. One delta is one token for
        // Ollama — the same assumption the live rate already runs on — so this
        // is an estimate, and shown as one.
        let abandonedTokens = streamedDeltas
        generateTask?.cancel()

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
                try await concludeFromReasoning(abandonedTokens: abandonedTokens)
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                conversation.state = .none
                self.error = errorMessage(for: error)
                state.log(error: error)
            }
        }
    }

    /// The reasoning written so far, and which message holds it.
    private var partialReasoning: (messageID: String, text: String)? {
        guard let message = conversation.messages.last, message.role == .assistant,
              let content = message.content
        else { return nil }

        for tag in ["think", "thinking"] {
            guard let open = content.range(of: "<\(tag)>") else { continue }
            var reasoning = String(content[open.upperBound...])
            if let close = reasoning.range(of: "</\(tag)>") {
                reasoning = String(reasoning[..<close.lowerBound])
            }
            let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (message.id, trimmed)
        }
        return nil
    }

    private func concludeFromReasoning(abandonedTokens: Int) async throws {
        guard let (messageID, reasoning) = partialReasoning else { return }
        error = nil

        let (service, model) = try chatService()
        var context: [String: Value] = ["datetime": .string(Date.now.formatted())]
        if let profile = state.userProfile {
            context["MEMORIES"] = .string(profile)
        }

        // Everything before the half-written turn, then the reasoning as its
        // own turn and the ask. The unfinished message itself is left out —
        // it's the thing being replaced.
        var history = historyForRequest()
        if history.last?.id == messageID {
            history.removeLast()
        }
        history.append(Message(role: .assistant, content: reasoning))
        history.append(Message(role: .user, content: Self.answerNowPrompt))

        var req = ChatSessionRequest(service: service, model: model, toolCallback: prepareToolResponse)
        req.with(system: systemForRequest(context: context))
        req.with(history: history)
        req.with(tools: Toolbox.get(names: conversation.toolIDs))
        req.with(context: context)
        if let serviceID = conversation.serviceID,
           let contextLength = state.config.contextLength(serviceID: serviceID, modelID: model.id) {
            req.with(option: "num_ctx", value: .int(contextLength))
        }
        // For this reply only. The conversation's own setting is untouched, so
        // the next turn reasons as before.
        req.with(option: "effort", value: .string(ThinkingEffort.off.rawValue))

        ChatDebug.log("→ answer now | model: \(model.id) | reasoning handed back: \(reasoning.count) chars")

        conversation.state = .streaming

        // The reasoning is kept, closed off where it was interrupted, and the
        // answer written after it — so the turn ends up looking like any other
        // rather than as two messages, one of them half a thought.
        var answer = ""
        var furtherReasoning: String?

        // The counts arrive on the streamed message, and the reply is written
        // into the interrupted one — so they have to be carried across, or the
        // turn ends with no model name and no tokens under it.
        var usage: [String: Value] = [:]

        // A model that can't stop reasoning does it again here, so this reply
        // gets the same delta-boundary split an ordinary turn gets — counted
        // separately from the reasoning that was abandoned, which came from a
        // different request.
        var deltas = 0
        var deltasAtClose: Int?

        let stream = ChatSession.shared.stream(req, timeouts: Self.heavyPromptTimeouts)
        for try await message in stream {
            try Task.checkCancellation()
            deltas += 1
            let (extra, visible) = separateReasoning(from: message.content ?? "")
            answer = visible
            if let extra {
                furtherReasoning = extra
                if deltasAtClose == nil { deltasAtClose = deltas }
            }
            usage = message.metadata
            merge(compose(reasoning, furtherReasoning, answer), usage: usage, into: messageID)
        }

        try Task.checkCancellation()

        usage["interruptedThinkingTokens"] = .int(abandonedTokens)
        // Named explicitly either way, so a figure from the cancelled turn
        // can't survive on the message and be read as this reply's.
        usage["thinkingTokens"] = .int(furtherThinkingTokens(
            total: usage["outputTokens"]?.intValue,
            closedAt: deltasAtClose,
            of: deltas
        ))

        merge(compose(reasoning, furtherReasoning, answer), usage: usage, into: messageID)

        // applyThinkingSplit isn't used: it reads the counters of the turn that
        // was cancelled, which describe the abandoned reasoning rather than
        // this reply. The same apportioning is done above from this stream's
        // own deltas, and the abandoned tokens are carried separately.
        liveTokensPerSecond = nil
        conversation.state = .none
        ChatDebug.log("← answer now: \(answer.count) chars")

        // The rest of what finishing a turn means. Skipping straight to saving
        // left the conversation with no suggestions, no title, and no usage
        // line — the turn had ended without ever being finished.
        NotificationManager.shared.responseCompleted(
            conversation: file.name ?? "Heat",
            preview: responsePreview
        )
        try await generateSuggestions()
        try await generateTitle()

        try await API.shared.fileUpdate(file.id, object: conversation)
        try await API.shared.fileUpdate(file)
    }

    /// How much of this reply was the model reasoning again rather than
    /// answering, apportioned the way an ordinary turn's is.
    private func furtherThinkingTokens(total: Int?, closedAt: Int?, of deltas: Int) -> Int {
        guard let total, let closedAt, deltas > 0 else { return 0 }
        let share = Double(closedAt) / Double(deltas)
        let thinking = Int(((Double(total) * share) / 10).rounded()) * 10
        return min(thinking, total)
    }

    /// One reasoning block, then the answer — the shape an uninterrupted turn
    /// already has.
    private func compose(_ reasoning: String, _ further: String?, _ answer: String) -> String {
        var thinking = reasoning
        if let further, !further.isEmpty {
            thinking += "\n\n" + further
        }
        return "<think>\n\(thinking)\n</think>\n\n" + answer
    }

    /// Splits a reply into any reasoning it carried and the answer itself.
    ///
    /// A model that cannot stop reasoning produces a fresh block even with
    /// thinking switched off — GPT-OSS returned 159 characters of it when asked
    /// to answer now. Left alone that would sit beside the reasoning already
    /// preserved, giving one turn two thinking blocks; folded together there is
    /// one, as there would have been had nothing interrupted it.
    private func separateReasoning(from content: String) -> (reasoning: String?, answer: String) {
        for tag in ["think", "thinking"] {
            guard let open = content.range(of: "<\(tag)>"),
                  let close = content.range(of: "</\(tag)>", range: open.upperBound..<content.endIndex)
            else { continue }

            let reasoning = content[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = (content[..<open.lowerBound] + content[close.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (reasoning.isEmpty ? nil : reasoning, answer)
        }
        return (nil, content)
    }

    /// Writes into the interrupted message rather than adding another, keeping
    /// the reasoning and the answer as one turn.
    private func merge(_ content: String, usage: [String: Value], into messageID: String) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }

        // Merged rather than assigned, so anything the interrupted turn was
        // already carrying — pictures a tool found, say — isn't dropped along
        // with it.
        for (key, value) in usage {
            conversation.messages[index].metadata[key] = value
        }
        // `content` is a read-only view over `contents`, so the text has to go
        // back the way it came. Images and anything else the turn was carrying
        // are kept — only the text is replaced.
        var contents = conversation.messages[index].contents ?? []
        contents.removeAll { if case .text = $0 { true } else { false } }
        conversation.messages[index].contents = [.text(content)] + contents
        conversation.messages[index].modified = .now
        file.modified = .now
    }

    /// What's asked for when the reasoning is cut short.
    ///
    /// Measured against the alternatives: without an explicit instruction the
    /// models restated the question or rambled. Naming the reasoning as the
    /// thing to conclude from is what produces an answer rather than a
    /// re-derivation.
    private static let answerNowPrompt =
        "Answer now, based on the reasoning above. Don't reason further."

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
