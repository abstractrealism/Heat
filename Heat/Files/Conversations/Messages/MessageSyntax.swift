import Foundation

/// Which parts of a message being typed should read as code.
///
/// Deliberately a pure function of the text, computed fresh on every edit
/// rather than tracked incrementally: what's in the field is a few lines, the
/// scan is a single pass, and state that has to be kept in step with an editor
/// is where this kind of thing goes wrong.
///
/// The rules are markdown's, narrowed to what can be recognised while it's
/// still being typed:
///
/// - A fence line opens a block, and the block runs to the next fence line or,
///   if there isn't one, to the end of the text. **Unclosed blocks format
///   immediately**, which is the behaviour you want — you see the block the
///   moment you start one, rather than when you finish it.
/// - An inline span needs both its backticks, so it formats only once closed.
///   There's nothing else it could mean: a lone backtick is as likely to be
///   the start of a word as the start of code.
enum MessageSyntax {

    struct Span: Equatable {
        let range: NSRange
        let isBlock: Bool

        /// Whether a fence closed this block, as opposed to it running off the
        /// end of the text still open.
        ///
        /// The difference is what's *after* it. An open block owns the empty
        /// line the caret is sitting on, waiting for the next word; a closed
        /// one ends at its fence, and the line after belongs to whatever comes
        /// next. Inline spans are closed by definition — an unclosed one isn't
        /// a span at all.
        let isClosed: Bool
    }

    static func codeSpans(in text: String) -> [Span] {
        let string = text as NSString
        guard string.length > 0 else { return [] }

        var lines: [(content: String, range: NSRange, enclosing: NSRange)] = []
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byLines]
        ) { substring, range, enclosing, _ in
            lines.append((substring ?? "", range, enclosing))
        }

        var spans: [Span] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            guard isFence(line.content) else {
                spans.append(contentsOf: inlineSpans(in: line.content, offset: line.range.location))
                index += 1
                continue
            }

            // A block, from the opening fence to the closing one inclusive.
            var end = line.enclosing.location + line.enclosing.length
            var closingLine: Int?

            var candidate = index + 1
            while candidate < lines.count {
                let next = lines[candidate]
                end = next.enclosing.location + next.enclosing.length
                if isFence(next.content) {
                    closingLine = candidate
                    break
                }
                candidate += 1
            }

            // Nothing closed it, so the block owns the rest of the text —
            // including a trailing newline the line enumeration doesn't report.
            if closingLine == nil {
                end = string.length
            }

            spans.append(
                Span(
                    range: NSRange(location: line.enclosing.location, length: end - line.enclosing.location),
                    isBlock: true,
                    isClosed: closingLine != nil
                )
            )
            index = (closingLine ?? lines.count - 1) + 1
        }

        return spans
    }

    private static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    /// Backtick pairs within a single line, the backticks included so what's
    /// marked matches what was typed.
    private static func inlineSpans(in line: String, offset: Int) -> [Span] {
        let string = line as NSString
        var spans: [Span] = []
        var cursor = 0

        while cursor < string.length {
            let opening = string.range(
                of: "`",
                range: NSRange(location: cursor, length: string.length - cursor)
            )
            guard opening.location != NSNotFound else { break }

            let afterOpening = opening.location + opening.length
            guard afterOpening < string.length else { break }

            let closing = string.range(
                of: "`",
                range: NSRange(location: afterOpening, length: string.length - afterOpening)
            )
            guard closing.location != NSNotFound else { break }

            // Empty backticks mark nothing, but still consume both.
            if closing.location > afterOpening {
                spans.append(
                    Span(
                        range: NSRange(
                            location: offset + opening.location,
                            length: (closing.location + closing.length) - opening.location
                        ),
                        isBlock: false,
                        isClosed: true
                    )
                )
            }
            cursor = closing.location + closing.length
        }

        return spans
    }
}
