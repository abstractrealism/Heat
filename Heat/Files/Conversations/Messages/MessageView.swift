import SwiftUI
import AVKit
import QuickLook
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
               MessageUsageView(message)
            case .tool:
               ToolContentsView(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        // Where find has got to. The current match is marked plainly and the
        // rest faintly — knowing there are others, and roughly where they sit,
        // is most of what a find bar is for.
        .background(findHighlight, in: .rect(cornerRadius: 6))
        .animation(.easeOut(duration: 0.15), value: conversationViewModel.currentFindMessageID)
    }

    private var findHighlight: Color {
        if conversationViewModel.currentFindMessageID == message.id {
            return .accentColor.opacity(0.28)
        }
        if conversationViewModel.findMatchIDs.contains(message.id) {
            return .accentColor.opacity(0.10)
        }
        return .clear
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
                ToolResponseName(message.name ?? "Unknown Tool")
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
            .fixedSize(horizontal: false, vertical: true) // HACK: Prevents occasional word truncation
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

struct ToolResponseName: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        if let tool = Toolbox(name: name) {
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

/// What a response cost, shown quietly beneath it once the service reports it.
///
/// The counts cover the whole generation. Reasoning isn't broken out because
/// no separate figure is reported for it — the service counts every token it
/// produced together, so splitting them would mean inventing a number.
struct MessageUsageView: View {
    let message: Message

    init(_ message: Message) {
        self.message = message
    }

    var body: some View {
        if let summary {
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var summary: String? {
        guard let output = message.metadata["outputTokens"]?.intValue else { return nil }

        var parts: [String] = []

        // First, because it's the thing that makes the rest mean something:
        // a conversation can change model between messages, so tokens and
        // tok/s can't be compared without knowing what produced them.
        if let model = message.metadata["model"]?.stringValue, !model.isEmpty {
            parts.append(model)
        }

        // Reasoning the model was doing when Skip Thinking cut it off. Counted
        // from the abandoned request, so it's shown apart from anything this
        // reply reasoned: pressing Skip usually means wanting to know how long
        // it had been going round in circles, and folding the two together
        // would answer a different question.
        let interrupted = message.metadata["interruptedThinkingTokens"]?.intValue ?? 0
        let thinking = message.metadata["thinkingTokens"]?.intValue ?? 0

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
        if !breakdown.isEmpty {
            breakdown.append("\(format(output - thinking)) answer")
            outputDetail += " ≈ " + breakdown.joined(separator: " + ")
        }

        if let input = message.metadata["inputTokens"]?.intValue {
            parts.append("\(format(input + produced)) tokens (\(format(input)) in, \(outputDetail))")
        } else {
            parts.append("\(outputDetail) tokens")
        }
        if let seconds = message.metadata["outputSeconds"]?.doubleValue, seconds > 0 {
            parts.append(String(format: "%.1f tok/s", Double(output) / seconds))
        }
        return parts.joined(separator: " · ")
    }

    private func format(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }
}
