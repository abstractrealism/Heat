import SwiftUI
import Highlightr
import MarkdownUI

struct CodeHighlighter: CodeSyntaxHighlighter {
    private let highlightr: Highlightr

    init() {
        guard let highlightrInstance = Highlightr() else {
            fatalError("Failed to initialize Highlightr")
        }
        self.highlightr = highlightrInstance
        self.highlightr.setTheme(to: "atom-one-dark")
    }

    func highlightCode(_ code: String, language: String?) -> Text {
        let highlightedCode: NSAttributedString?

        // What arrives is the whole fence info string, which may name a file as
        // well as a language. Highlightr answers nil for anything it doesn't
        // recognise, so passing `python:parse_logs.py` through would leave the
        // block unhighlighted. See `CodeFence`.
        let language = CodeFence(fenceInfo: language).language

        if let language, !language.isEmpty {
            highlightedCode = highlightr.highlight(code, as: language)
        } else {
            highlightedCode = highlightr.highlight(code)
        }

        guard let highlightedCode else { return Text(code) }

        var attributedCode = AttributedString(highlightedCode)
        attributedCode.font = .system(size: 12, design: .monospaced)

        return Text(attributedCode)
    }
}

class CodeHighlighterCache {
    static let shared = CodeHighlighterCache()

    private var highlighter: CodeHighlighter?

    private init() {}

    func getHighlighter() -> CodeHighlighter {
        if let existingHighlighter = highlighter {
            return existingHighlighter
        } else {
            let newHighlighter = CodeHighlighter()
            highlighter = newHighlighter

            return newHighlighter
        }
    }
}

extension CodeSyntaxHighlighter where Self == CodeHighlighter {

    static var app: Self {
        CodeHighlighterCache.shared.getHighlighter()
    }
}
