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
        // What arrives is the whole fence info string, which may name a file as
        // well as a language. Highlightr answers nil for anything it doesn't
        // recognise, so passing `python:parse_logs.py` through would leave the
        // block unhighlighted. See `CodeFence`.
        let language = CodeFence(fenceInfo: language).language

        // Remembered by exact content, because this runs in view body: every
        // evaluation of a message list highlighted every visible block again,
        // through JavaScriptCore, on the main thread — measured at ~1ms per
        // block with a named language and ~90ms for a bare fence, where
        // Highlightr auto-detects by trying every grammar it knows. The first
        // display of a distinct block pays full price, detection included;
        // every later one is a lookup.
        let key = "\(language ?? "\u{0}auto")\u{0}\(code)"
        if let cached = HighlightMemo.shared.value(for: key) {
            return Text(cached)
        }

        let highlightedCode: NSAttributedString?
        if let language, !language.isEmpty {
            highlightedCode = highlightr.highlight(code, as: language)
        } else {
            highlightedCode = highlightr.highlight(code)
        }

        guard let highlightedCode else { return Text(code) }

        var attributedCode = AttributedString(highlightedCode)
        attributedCode.font = .system(size: 12, design: .monospaced)

        HighlightMemo.shared.set(attributedCode, for: key)
        return Text(attributedCode)
    }
}

/// Finished highlights, keyed by the code itself.
///
/// A block that is still streaming arrives here as a different string on every
/// update, each leaving a dead entry behind, which is what the cap is for —
/// oldest out first. At the cap this holds a few MB of attributed text for a
/// heavy session; a fraction of what one open thread's views weigh.
///
/// Locked rather than main-actor because `highlightCode` is a protocol
/// requirement with no isolation of its own.
final class HighlightMemo: @unchecked Sendable {
    static let shared = HighlightMemo()

    private let lock = NSLock()
    private var store: [String: AttributedString] = [:]
    private var order: [String] = []
    private let limit = 256

    func value(for key: String) -> AttributedString? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = store[key] else { return nil }
        // Freshly used moves to the back, so eviction takes the stalest.
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return value
    }

    func set(_ value: AttributedString, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if store[key] == nil {
            order.append(key)
        }
        store[key] = value
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            store.removeValue(forKey: oldest)
        }
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
