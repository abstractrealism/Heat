import SwiftUI
import AVKit
import QuickLook
import Textual
import GenKit
import HeatKit

struct MessageView: View {
    @Environment(AppState.self) var state
    @Environment(ConversationViewModel.self) private var conversationViewModel

    let message: Message

    @State var isCopied = false
    @State var isPlaying = false
    @State var player: AVPlayer?

    init(_ message: Message) {
        self.message = message
    }

    var body: some View {
        VStack(alignment: horizontalAlignment, spacing: 12) {
           switch message.role {
            case .system:
               SystemContentsView(message.contents)
            case .user:
               // Constrain user bubbles so they hug their content and sit on the
               // trailing side of the pane, like a typical messaging app.
               UserContentsView(message.contents)
                   .frame(maxWidth: 480, alignment: .trailing)
            case .assistant:
               AssistantContentsView(message.contents)
               ForEachToolCall(message.toolCalls) { toolCall in
                   ToolCallView(toolCall)
               }
               MessageCutOffView(message)
               MessageUsageView(message)
            case .tool:
               ToolContentsView(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        // The matches themselves are marked, in the text, by the renderer.
        //
        // A tint behind the whole message stood in for that while the text
        // couldn't be marked at all: it said "somewhere in here" because
        // nothing could say where. Now that each match is marked where it
        // sits, tinting the message as well only draws the eye away from the
        // word it is meant to land on.
        .environment(\.findHighlightQuery, inTextQuery)
        // Joins the context menu the text already offers. Scoped to the
        // message rather than the run so that the item acts on the one under
        // the pointer: a run is a whole exchange, and "this message" has to
        // mean the one you asked about.
        .textual.textContextMenuItems(copyMessageItems)
    }

    /// Copying a message whole, without selecting it first.
    ///
    /// What gets copied is the text as it was written — the markdown source
    /// with reasoning stripped, which is the same text a find searches. Only
    /// offered where there is any: a tool message's content is the machinery
    /// of an answer rather than the answer.
    private var copyMessageItems: [TextContextMenuItem] {
        let text = ConversationSearch.searchableText(of: message)
        guard !text.isEmpty else { return [] }
        return [
            .init(title: "Copy Message") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #else
                UIPasteboard.general.string = text
                #endif
            }
        ]
    }

    /// What this message should mark, if anything: the query, and which of its
    /// own occurrences is the one being looked at.
    ///
    /// Only messages that match hand anything down. The query used to ride the
    /// environment of the whole list, so every keystroke changed it for every
    /// message and re-parsed the entire thread — scoped here, a keystroke
    /// touches only the messages it matches.
    private var inTextQuery: FindHighlight? {
        let query = conversationViewModel.findQuery
        guard !query.isEmpty, conversationViewModel.isFinding else { return nil }
        guard conversationViewModel.findMatches.contains(where: { $0.messageID == message.id })
        else { return nil }
        return FindHighlight(
            query: query,
            current: conversationViewModel.currentFindOrdinal(in: message.id)
        )
    }

    /// User messages align to the trailing edge; everything else stays leading.
    private var horizontalAlignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }
}

// Contents

struct SystemContentsView: View {
    let contents: [Message.Content]

    init(_ contents: [Message.Content]?) {
        self.contents = contents ?? []
    }

    var body: some View {
        ContentsView(contents)
            .render(role: .system)
    }
}

struct AssistantContentsView: View {
    let contents: [Message.Content]

    init(_ contents: [Message.Content]?) {
        self.contents = contents ?? []
    }

    var body: some View {
        ContentsView(contents)
            .render(role: .assistant)
    }
}

struct UserContentsView: View {
    let contents: [Message.Content]

    init(_ contents: [Message.Content]?) {
        self.contents = contents ?? []
    }

    var body: some View {
        ContentsView(contents)
            .render(role: .user)
    }
}

struct ToolContentsView: View {
    let message: Message

    @State var isDisclosed = false
    @State var imagePreviewURL: URL? = nil

    init(_ message: Message) {
        self.message = message
    }

    /// Pictures a search found, carried on the message rather than in its
    /// content — see WebSearchTool for why they aren't content.
    private var foundImages: [FoundImage] {
        guard let entries = message.metadata["images"]?.arrayValue else { return [] }
        var seen = Set<URL>()
        return entries.compactMap { entry in
            guard let fields = entry.objectValue,
                  let image = fields["image"]?.stringValue.flatMap(URL.init(string:)),
                  seen.insert(image).inserted
            else { return nil }
            return FoundImage(image: image, source: fields["source"]?.stringValue.flatMap(URL.init(string:)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isDisclosed.toggle()
            } label: {
                ToolResponseName(message)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Outside the disclosure. A search for pictures that shows none
            // until something is clicked has not really answered, and the
            // model has already told the user they are here.
            if !foundImages.isEmpty {
                ImageStripView(images: foundImages)
            }

            if isDisclosed {
                ContentsView(message.contents)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if message.hasImage {
                isDisclosed = true
            }
        }
    }
}

struct ContentsView: View {
    let contents: [Message.Content]

    init(_ contents: [Message.Content]?) {
        self.contents = contents ?? []
    }

    var body: some View {
        if !contents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(contents.indices, id: \.self) {
                    switch contents[$0] {
                    case .text(let text):
                        RenderText(text, tags: ["thinking", "think", "artifact", "output", "summary", "image_search_query"])
                    case .image(let image):
                        ContentImageView(url: image.url, detail: image.detail)

                    // TODO: Handle these content types
                    case .audio:
                        Text("Audio is unhandled right now.")
                    case .json:
                        Text("JSON is unhandled right now")
                    case .file:
                        Text("File is unhandled right now")
                    }
                }
            }
            // The truncation hack this used to carry —
            // `.fixedSize(horizontal: false, vertical: true)` — is gone. It
            // forced an ideal-height measurement of every message before the
            // real layout, doubling the layout work for a whole transcript,
            // and it was guarding against MarkdownUI clipping a word.
            // StructuredText sets `.lineLimit(nil)` itself for exactly that
            // reason, so the guard has a better owner now. If truncation ever
            // comes back, it belongs on the one view that truncates, not on
            // every message.
        }
    }
}

struct ContentImageView: View {
    let url: URL
    let detail: String?

    @State private var showingPreviewURL: URL? = nil
    @State private var showingDetailText = false

    var body: some View {
        Button {
            showingPreviewURL = url
        } label: {
            PictureView(url: url)
                .frame(width: 300, height: 300)
                .clipShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .quickLookPreview($showingPreviewURL)
        .overlay(alignment: .bottomTrailing) {
            if let detail {
                Button {
                    showingDetailText.toggle()
                } label: {
                    Image(systemName: "text.magnifyingglass")
                        .imageScale(.large)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 5))
                        .foregroundStyle(.white)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingDetailText) {
                    NavigationStack {
                        ContentImagePromptView(text: detail)
                    }
                    #if os(macOS)
                    .frame(width: 300)
                    .frame(maxHeight: 200)
                    #endif
                }
            }
        }
    }
}

struct ContentImagePromptView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .padding()
        }
        #if !os(macOS)
        .navigationTitle("Prompt")
        #endif
    }
}

// Tool Calls

struct ForEachToolCall<Content: View>: View {
    let toolCalls: [ToolCall]
    let content: (ToolCall) -> Content

    init(_ toolCalls: [ToolCall]?, @ViewBuilder content: @escaping (ToolCall) -> Content) {
        self.toolCalls = toolCalls ?? []
        self.content = content
    }

    var body: some View {
        ForEach(toolCalls, id: \.id) { toolCall in
            content(toolCall)
        }
    }
}

struct ToolCallView: View {
    let toolCall: ToolCall

    @State var isDisclosed = false

    init(_ toolCall: ToolCall) {
        self.toolCall = toolCall
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isDisclosed.toggle()
            } label: {
                ToolCallName(toolCall.function?.name ?? "Unknown")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isDisclosed {
                Text(toolCall.function?.arguments ?? "Unknown")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ToolCallName: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        if let tool = Toolbox(name: name) {
            switch tool {
            case .generateImages:
                Text("Generating image(s)...")
            case .searchCalendar:
                Text("Searching calendar...")
            case .searchWeb:
                Text("Searching web...")
            case .browseWeb:
                Text("Browsing website...")
            }
        } else {
            Text("Unknown tool...")
        }
    }
}

// Tool Responses

/// What a tool call did, in a line.
///
/// Prefers the `label` the tool wrote for itself. Every tool has been
/// setting one — "Searched web for 'ferry times'", "Found 3 calendar
/// items" — and nothing read them, so every row said the same four words
/// whatever had happened, including when the tool had failed. The name is
/// still there for messages with no label, which is anything from before
/// this and anything that doesn't bother.
struct ToolResponseName: View {
    let message: Message

    init(_ message: Message) {
        self.message = message
    }

    var body: some View {
        if let label = message.metadata["label"]?.stringValue, !label.isEmpty {
            // One line: a label carries the query, and a long question
            // shouldn't push the rest of the run down the screen.
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let tool = Toolbox(name: message.name ?? "") {
            switch tool {
            case .generateImages:
                Text("Generated image(s)")
            case .searchCalendar:
                Text("Searched calendar")
            case .searchWeb:
                Text("Searched web")
            case .browseWeb:
                Text("Browsed website")
            }
        } else {
            Text("Unknown tool")
        }
    }
}

/// Says when a reply stopped because it ran out of room rather than because
/// it was finished.
///
/// Nothing else says. A reply at the ceiling simply ends — mid-sentence, or
/// partway through a numbered list — with no error, nothing in the log a
/// reader would see, and an answer that looks as though the model lost
/// interest. The service reports it as a finish reason and it was recorded
/// and never shown.
///
/// Worth its own line rather than a footnote to the token count, because
/// what to do about it is different: ask the model to go on, or raise
/// Longest Reply for this service and ask again.
struct MessageCutOffView: View {
    let message: Message

    init(_ message: Message) {
        self.message = message
    }

    var body: some View {
        if message.finishReason == .length {
            Label(
                "This reply reached its length limit and stopped here. Ask the model to continue, or raise Longest Reply in Settings ▸ Services.",
                systemImage: "scissors"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }
}

/// When a response happened and what it cost, shown quietly beneath it.
///
/// The counts cover the whole generation. Where the service reports what
/// reasoning cost it's shown as counted; where it doesn't, the split is
/// apportioned from the stream and marked with ≈. Input the service already
/// had cached is noted inside the input figure rather than beside it, being
/// part of it.
struct MessageUsageView: View {
    @Environment(ConversationViewModel.self) private var conversationViewModel

    let message: Message

    init(_ message: Message) {
        self.message = message
    }

    var body: some View {
        if !isStreaming, let summary {
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    /// Whether this is the reply being written right now.
    ///
    /// The line used to appear the moment the message did, because the time
    /// is known from the start — so a timestamp sat under a growing answer
    /// for the whole generation, saying when it began while looking like it
    /// was saying when it ended. It belongs with the rest of the line, and
    /// arrives when the rest of the line does.
    ///
    /// The reply being written is the last message: between tool rounds the
    /// last message is the tool's, and the assistant message above it has
    /// finished and should say so.
    ///
    /// Not `isGenerating`, which stays true through `.suggesting` while the
    /// follow-up prompts and the title are written. The answer is finished by
    /// then, and waiting for those would hold the line back a second or two
    /// after the thing it describes had visibly stopped. The switch is
    /// exhaustive on purpose, so another state has to be thought about rather
    /// than defaulting to hidden.
    private var isStreaming: Bool {
        guard message.id == conversationViewModel.conversation.messages.last?.id else {
            return false
        }
        switch conversationViewModel.conversation.state {
        case .processing, .streaming: return true
        case .suggesting, .none: return false
        }
    }

    private var summary: String? {
        var parts: [String] = []

        // When this was said. First, because it's the one part of the line
        // that means something on its own — a reply with no counts against it
        // still happened at a time, and looking back through a conversation
        // is the commonest reason to want any of this.
        //
        // The time alone for today, the date as well for anything older: a
        // bare "10:32 AM" on something from last week reads as this morning.
        parts.append(
            Calendar.current.isDateInToday(message.modified)
                ? message.modified.formatted(date: .omitted, time: .shortened)
                : message.modified.formatted(date: .abbreviated, time: .shortened)
        )

        // First, because it's the thing that makes the rest mean something:
        // a conversation can change model between messages, so tokens and
        // tok/s can't be compared without knowing what produced them.
        //
        // Shown whenever it's known rather than only alongside the counts.
        // Every service reports it on the first chunk and the totals on the
        // last, so a reply that was stopped has a model and no totals — and
        // which model wrote something is worth as much on an abandoned
        // answer as on a finished one. It used to be behind the guard below,
        // so a stopped reply said nothing but the time.
        if let model = message.metadata["model"]?.stringValue, !model.isEmpty {
            parts.append(model)
        }

        guard let output = message.metadata["outputTokens"]?.intValue else {
            return interrupted(parts)
        }

        // Reasoning the model was doing when Skip Thinking cut it off. Counted
        // from the abandoned request, so it's shown apart from anything this
        // reply reasoned: pressing Skip usually means wanting to know how long
        // it had been going round in circles, and folding the two together
        // would answer a different question.
        let interrupted = message.metadata["interruptedThinkingTokens"]?.intValue ?? 0

        // A figure the service counted, where there is one. Every other
        // number here is counted, and this one used to be the exception:
        // deltas standing in for tokens, because a local model reports no
        // such figure. The hosted services do, so it's read in preference —
        // and what's shown says which it is, since an apportioned number and
        // a counted one deserve different confidence.
        let counted = message.metadata["reasoningTokens"]?.intValue
        let thinking = counted ?? message.metadata["thinkingTokens"]?.intValue ?? 0

        // Everything the model produced, across both requests when there were
        // two. Input is counted once: the second request re-sent much the same
        // prompt, and there's no figure for what the cancelled one evaluated.
        let produced = output + interrupted

        // The splits are approximate — deltas standing in for tokens, see
        // applyThinkingSplit — so they're marked with ≈ rather than presented
        // as counted figures.
        var outputDetail = "\(format(produced)) out"
        var breakdown: [String] = []
        if interrupted > 0 {
            breakdown.append("\(format(interrupted)) thinking (interrupted)")
        }
        if thinking > 0 {
            breakdown.append("\(format(thinking)) thinking")
        }
        // A split only says something where the reasoning is part of the
        // output. Grok reported 1,396 reasoning tokens against 306 of output,
        // which are not a whole and a part, and subtracting gave an answer of
        // −1,090 tokens. gen-kit reconciles that at the source now, by asking
        // the service's own total which it means; this stays as the backstop,
        // because a figure that can't be true is worse than one that isn't
        // shown, and the next service to disagree will disagree in some way
        // nobody predicted either.
        if !breakdown.isEmpty, thinking <= output {
            breakdown.append("\(format(output - thinking)) answer")
            // The interrupted figure is apportioned however the rest came by,
            // so one estimate in the sum makes the whole of it one.
            let exact = counted != nil && interrupted == 0
            outputDetail += (exact ? " = " : " ≈ ") + breakdown.joined(separator: " + ")
        }

        if let input = message.metadata["inputTokens"]?.intValue {
            // How much of the input the service already had. Worth saying,
            // because it's the difference between a long conversation costing
            // what it looks like it costs and a tenth of that — and because
            // it's the only way to see whether the caching is working at all.
            // Part of the input rather than extra to it, so it's shown inside
            // that figure.
            var inputDetail = "\(format(input)) in"
            if let cached = message.metadata["cachedTokens"]?.intValue, cached > 0 {
                inputDetail += " (\(format(cached)) cached)"
            }
            parts.append("\(format(input + produced)) tokens (\(inputDetail), \(outputDetail))")
        } else {
            parts.append("\(outputDetail) tokens")
        }
        if let seconds = message.metadata["outputSeconds"]?.doubleValue, seconds > 0 {
            parts.append(String(format: "%.1f tok/s", Double(output) / seconds))
        }
        return parts.joined(separator: " · ")
    }

    /// The line for a reply with no totals against it.
    ///
    /// Usually because it was stopped with the button or failed part-way: the
    /// service reports what a generation cost on a final chunk, and a stream
    /// that ended early never receives one. Two things can still be said.
    /// The input count, where the service sends it up front rather than at
    /// the end — Anthropic does, on its first event, so a stopped Anthropic
    /// reply can still show what the turn cost to send. And the deltas that
    /// arrived, standing in for output tokens as they already do for the live
    /// rate and the reasoning split, marked ≈ because that is what they are.
    ///
    /// "before stopping" is said only where `stoppedOutputTokens` says it was
    /// stopped. This path is also reached by any message that simply has no
    /// usage against it — anything written before usage was recorded, or a
    /// service that reports none — and those were not interrupted.
    private func interrupted(_ parts: [String]) -> String {
        var parts = parts
        var counts: [String] = []

        if let input = message.metadata["inputTokens"]?.intValue {
            counts.append("\(format(input)) in")
        }
        let stopped = message.metadata["stoppedOutputTokens"]?.intValue ?? 0
        if stopped > 0 {
            counts.append("≈\(format(stopped)) out")
        }

        guard !counts.isEmpty else { return parts.joined(separator: " · ") }
        parts.append(counts.joined(separator: ", ") + (stopped > 0 ? " before stopping" : ""))
        return parts.joined(separator: " · ")
    }

    private func format(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }
}
