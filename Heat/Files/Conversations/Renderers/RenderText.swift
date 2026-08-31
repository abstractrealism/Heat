import SwiftUI
import Textual
import GenKit
import HeatKit

struct RenderText: View {
    @Environment(AppState.self) var state
    @Environment(\.findHighlightQuery) private var findQuery

    let text: String
    let tags: [String]

    init(_ text: String?, tags: [String] = []) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Marked before rendering rather than styled during it: a link cannot
        // be styled by where it points — see SuggestionLinks.
        self.text = SuggestionLinks.marked(LaTeXUnicode.convert(trimmed))
        self.tags = tags
    }

    var body: some View {
        // Held once: this is a computed property running a full regex pass
        // over the message, and reading it from inside the ForEach ran that
        // pass again for every segment — a message with S segments was parsed
        // S+1 times per evaluation.
        let contents = toTaggedContents
        VStack(alignment: .leading, spacing: 12) {
            ForEach(contents.indices, id: \.self) { index in
                switch contents[index] {
                case let .text(text):
                    StructuredText(text, parser: HeatMarkupParser(findQuery: findQuery))
                        // Recreated when the query changes. StructuredText
                        // re-parses only when its *markup* changes, so a new
                        // query over unchanged text would keep stale marks.
                        .id(findQuery)
                        .font(.system(size: chatFontSize))
                        .textual.textSelection(.enabled)
                        .textual.headingStyle(ChatHeadingStyle())
                        .textual.codeBlockStyle(ChatCodeBlockStyle())
                case let .tag(tag):
                    RenderTag(tag)
                }
            }
        }
        .textSelection(.enabled)
    }

    var toAttributedString: AttributedString {
        try! .init(markdown: text)
    }

    var toTaggedContents: [ContentParser.Result.Content] {
        guard let results = try? parser.parse(input: text, tags: tags) else { return [] }
        return results.contents
    }

    private let parser = ContentParser.shared
}

struct RenderModifier: ViewModifier {
    @Environment(AppState.self) var state

    let role: Message.Role

    /// Mirrors the MarkdownUI themes this replaces: primary links for the
    /// assistant, white text and links inside the user bubble.
    private static let assistantInline = InlineStyle()
        .link(.foregroundColor(.primary), .underlineStyle(.single))
    private static let userInline = InlineStyle()
        .link(.foregroundColor(.white), .underlineStyle(.single))

    func body(content: Content) -> some View {
        switch role {
        case .system:
            content
        case .assistant:
            content
                .textual.inlineStyle(Self.assistantInline)
        case .user:
            content
                .foregroundStyle(.white)
                .textual.inlineStyle(Self.userInline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.tint, in: .rect(cornerRadius: 10))
        case .tool:
            content
        }
    }
}

extension View {
    func render(role: Message.Role) -> some View {
        self.modifier(RenderModifier(role: role))
    }
}

// MARK: - Textual

/// SPIKE (`textual-spike`): everything from here to the LaTeX mark exists to
/// answer three questions about Textual before adopting it — whether
/// attributes set by a custom parser survive rendering, what a full re-parse
/// costs at streaming rate, and whether the code block chrome can be kept.

#if os(macOS)
private let chatFontSize: CGFloat = 14
#else
private let chatFontSize: CGFloat = 16
#endif

extension EnvironmentValues {
    /// What find is looking for, or nil when no find is active. Carried in the
    /// environment rather than read off a view model because RenderText also
    /// draws in places that have none.
    @Entry var findHighlightQuery: String? = nil
}

/// Textual's stock markdown parser plus the two passes MarkdownUI had no seam
/// for: marking suggestion links by their destination, and highlighting find
/// matches inside the text. Both work because the pipeline is markdown →
/// AttributedString → layout, and this sits in the middle of it.
struct HeatMarkupParser: MarkupParser {
    var findQuery: String?

    func attributedString(for input: String) throws -> AttributedString {
        let start = ContinuousClock.now
        var text = try AttributedStringMarkdownParser.markdown().attributedString(for: input)
        markSuggestionLinks(in: &text)
        if let findQuery, !findQuery.isEmpty {
            highlight(findQuery, in: &text)
        }
        // The whole message is re-parsed on every streamed publish, ten times
        // a second — this is the number that decides whether that's viable.
        let elapsed = ContinuousClock.now - start
        if elapsed > .milliseconds(8) {
            ChatDebug.log("⚠ textual parse \(elapsed) | \(input.count) chars")
        }
        return text
    }

    /// A link is finally styled by where it points: the run carries its URL.
    /// The ✦ the input already carries stays — belt and braces until this is
    /// confirmed rendering.
    private func markSuggestionLinks(in text: inout AttributedString) {
        // Ranges first, mutation second — attribute writes can coalesce runs,
        // and mutating what's being iterated is undefined.
        let ranges = text.runs.compactMap { run in
            run.link?.scheme == "heat" ? run.range : nil
        }
        for range in ranges {
            text[range].foregroundColor = .accentColor
            text[range].backgroundColor = Color.accentColor.opacity(0.12)
        }
    }

    /// Yellow rather than accent so the marks read against the accent-tinted
    /// row the matched message already gets.
    private func highlight(_ query: String, in text: inout AttributedString) {
        var start = text.startIndex
        while start < text.endIndex,
              let range = text[start..<text.endIndex].range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive]
              ) {
            text[range].backgroundColor = Color.yellow.opacity(0.45)
            start = range.upperBound
        }
    }
}

/// Headings at body size, distinguished by weight — a chat message is not a
/// document, and the old MarkdownUI theme made the same choice.
private struct ChatHeadingStyle: StructuredText.HeadingStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: chatFontSize, weight: weight(configuration.headingLevel)))
    }

    private func weight(_ level: Int) -> Font.Weight {
        switch level {
        case 1: .bold
        case 2: .semibold
        default: .medium
        }
    }
}

/// CodeBlockView's chrome, rebuilt on Textual's style protocol.
private struct ChatCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        // A nested view rather than state on the style: the one style value
        // serves every block, so state here would be shared between them.
        ChatCodeBlock(configuration: configuration)
    }
}

private struct ChatCodeBlock: View {
    let configuration: StructuredText.CodeBlockStyleConfiguration

    @State private var isCopied = false

    /// Same parse CodeBlockView does — the language and, if the model named
    /// one, the file.
    private var fence: CodeFence {
        CodeFence(fenceInfo: configuration.languageHint)
    }

    /// See CodeBlockView for why these are absolute colours.
    private static let background = Color(red: 0.157, green: 0.173, blue: 0.204)
    private static let chrome = Color.white.opacity(0.6)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(fence.displayLabel)
                    .font(.subheadline)
                Spacer()

                // No save-to-Downloads, unlike CodeBlockView: CodeBlockProxy
                // keeps the code text private and offers only
                // copyToPasteboard(), so there is nothing to hand
                // CodeDownload. An upstream accessor is the route if the
                // spike graduates.
                Button(action: copyCodeAction) {
                    Image(systemName: isCopied ? "checkmark" : "square.on.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Copy this code")
            }
            .foregroundStyle(Self.chrome)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)

            configuration.label
                // The block is fixed dark whatever the app's appearance, so
                // the highlighter theme has to resolve dark too — in light
                // mode it would otherwise pick colours for a white page.
                .environment(\.colorScheme, .dark)
                .padding(12)
        }
        .background(Self.background)
        .clipShape(.rect(cornerRadius: 5))
        .padding(.horizontal, -12)
    }

    private func copyCodeAction() {
        configuration.codeBlock.copyToPasteboard()
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
}

// MARK: - LaTeX

/// Rewrites LaTeX math symbols in model output as Unicode.
///
/// Models regularly answer with LaTeX — `$\rightarrow$` rather than "→" — and
/// the markdown renderer has no notion of math, so it prints the source
/// verbatim. Translating the symbol macros covers what actually shows up in
/// chat: arrows, comparisons, set and logic notation, and Greek letters.
///
/// This is symbol substitution, not typesetting, so it is deliberately
/// conservative:
///
/// - Fenced code blocks are left alone.
/// - A span is only considered when it contains a backslash, so ordinary text
///   like "it costs $5 to $10" is never treated as math.
/// - A span is only rewritten when *every* macro in it is understood, and when
///   nothing is left that needs real typesetting — a leftover brace means
///   grouped subscripts, fractions or matrix cells, and those spans are left
///   exactly as written rather than half-converted into nonsense. Plain
///   subscripts survive as they were (`x_i → y_i`), which reads better than
///   the LaTeX source.
enum LaTeXUnicode {

    static func convert(_ text: String) -> String {
        // Almost all messages contain no LaTeX at all; skip them outright
        // rather than running the scan on every re-render while streaming.
        guard text.contains("\\") else { return text }

        // Odd-numbered segments are inside ``` fences.
        return text
            .components(separatedBy: "```")
            .enumerated()
            .map { $0.offset % 2 == 1 ? $0.element : convertSpans(in: $0.element) }
            .joined(separator: "```")
    }

    private static func convertSpans(in text: String) -> String {
        var out = text
        for pattern in delimiters {
            out = rewrite(pattern: pattern, in: out)
        }
        return out
    }

    /// Display math first, so `$$…$$` isn't chewed up by the `$…$` pattern.
    private static let delimiters = [
        #"\$\$(.+?)\$\$"#,
        #"\\\[(.+?)\\\]"#,
        #"\$(.+?)\$"#,
        #"\\\((.+?)\\\)"#,
    ]

    private static func rewrite(pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let source = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let inner = source.substring(with: match.range(at: 1))
            out += translate(inner) ?? source.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        out += source.substring(from: cursor)
        return out
    }

    /// The Unicode form of a math span, or nil when it shouldn't be rewritten.
    private static func translate(_ span: String) -> String? {
        guard span.contains("\\") else { return nil }
        var out = span

        // Text wrappers: keep the contents, drop the macro.
        for macro in ["text", "mathrm", "mathbf", "mathit", "textbf", "textit"] {
            out = out.replacingOccurrences(
                of: #"\\\#(macro)\{([^{}]*)\}"#,
                with: "$1",
                options: .regularExpression
            )
        }

        // Symbols. The lookahead stops `\to` matching inside `\top`.
        for (macro, symbol) in symbols {
            out = out.replacingOccurrences(
                of: #"\\\#(macro)(?![A-Za-z])"#,
                with: symbol,
                options: .regularExpression
            )
        }

        // Spacing and sizing macros carry no meaning here.
        for (macro, replacement) in [("quad", " "), ("qquad", "  "), ("left", ""), ("right", "")] {
            out = out.replacingOccurrences(
                of: #"\\\#(macro)(?![A-Za-z])"#,
                with: replacement,
                options: .regularExpression
            )
        }
        // Thin spaces are still spaces; only the negative one disappears.
        for macro in [#"\\,"#, #"\\;"#, #"\\:"#] {
            out = out.replacingOccurrences(of: macro, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\\!"#, with: "", options: .regularExpression)

        // A macro we don't know is left for the reader rather than mangled.
        guard out.range(of: #"\\[A-Za-z]"#, options: .regularExpression) == nil else { return nil }

        // Leftover braces mean structure Unicode can't express — grouped
        // subscripts, limits, matrix cells. Converting only the symbols would
        // expose that syntax (`∑_{i} x_i`), so leave the span as written.
        guard !out.contains("{"), !out.contains("}") else { return nil }

        return out.trimmingCharacters(in: .whitespaces)
    }

    private static let symbols: [(String, String)] = [
        // Arrows
        ("longrightarrow", "⟶"), ("longleftarrow", "⟵"), ("leftrightarrow", "↔"),
        ("Leftrightarrow", "⇔"), ("rightarrow", "→"), ("leftarrow", "←"),
        ("Rightarrow", "⇒"), ("Leftarrow", "⇐"), ("uparrow", "↑"), ("downarrow", "↓"),
        ("mapsto", "↦"), ("implies", "⇒"), ("iff", "⇔"), ("to", "→"), ("gets", "←"),
        // Comparison
        ("leq", "≤"), ("geq", "≥"), ("neq", "≠"), ("approx", "≈"), ("equiv", "≡"),
        ("propto", "∝"), ("sim", "∼"), ("ll", "≪"), ("gg", "≫"), ("le", "≤"),
        ("ge", "≥"), ("ne", "≠"),
        // Operators
        ("times", "×"), ("div", "÷"), ("pm", "±"), ("mp", "∓"), ("cdot", "·"),
        ("ast", "∗"), ("star", "⋆"), ("bullet", "•"), ("oplus", "⊕"), ("otimes", "⊗"),
        // Sets and logic
        ("notin", "∉"), ("subseteq", "⊆"), ("supseteq", "⊇"), ("subset", "⊂"),
        ("supset", "⊃"), ("cup", "∪"), ("cap", "∩"), ("emptyset", "∅"),
        ("forall", "∀"), ("exists", "∃"), ("neg", "¬"), ("land", "∧"), ("lor", "∨"),
        ("therefore", "∴"), ("because", "∵"), ("in", "∈"),
        // Misc
        ("infty", "∞"), ("partial", "∂"), ("nabla", "∇"), ("sum", "∑"), ("prod", "∏"),
        ("int", "∫"), ("sqrt", "√"), ("angle", "∠"), ("degree", "°"), ("circ", "∘"),
        ("ldots", "…"), ("cdots", "⋯"), ("dots", "…"), ("prime", "′"), ("hbar", "ℏ"),
        ("ell", "ℓ"), ("aleph", "ℵ"), ("checkmark", "✓"),
        // Greek, lowercase
        ("varepsilon", "ε"), ("vartheta", "ϑ"), ("varphi", "φ"), ("alpha", "α"),
        ("beta", "β"), ("gamma", "γ"), ("delta", "δ"), ("epsilon", "ε"), ("zeta", "ζ"),
        ("eta", "η"), ("theta", "θ"), ("iota", "ι"), ("kappa", "κ"), ("lambda", "λ"),
        ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"), ("rho", "ρ"), ("sigma", "σ"),
        ("tau", "τ"), ("upsilon", "υ"), ("phi", "φ"), ("chi", "χ"), ("psi", "ψ"),
        ("omega", "ω"), ("pi", "π"),
        // Greek, uppercase
        ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"), ("Xi", "Ξ"),
        ("Pi", "Π"), ("Sigma", "Σ"), ("Upsilon", "Υ"), ("Phi", "Φ"), ("Psi", "Ψ"),
        ("Omega", "Ω"),
    ]
}
