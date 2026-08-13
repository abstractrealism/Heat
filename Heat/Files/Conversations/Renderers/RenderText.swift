import SwiftUI
import MarkdownUI
import GenKit
import HeatKit

struct RenderText: View {
    @Environment(AppState.self) var state

    let text: String
    let tags: [String]

    init(_ text: String?, tags: [String] = []) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.text = LaTeXUnicode.convert(trimmed)
        self.tags = tags
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(toTaggedContents.indices, id: \.self) { index in
                switch toTaggedContents[index] {
                case let .text(text):
                    Markdown(text)
                        .markdownCodeSyntaxHighlighter(.app)
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

    func body(content: Content) -> some View {
        switch role {
        case .system:
            content
        case .assistant:
            content
                .markdownTheme(.assistant)
        case .user:
            content
                .markdownTheme(.user)
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
