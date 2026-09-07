import Foundation
import GenKit

/// Finding text in a conversation.
///
/// Shared by the find bar in a thread and the search across all of them, so
/// the two agree about what counts as a match and what a conversation is
/// searchable *as*.
enum ConversationSearch {

    /// Case and accents ignored, the way find works everywhere else. Someone
    /// looking for "cafe" means the one with the accent too.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// A message's text as it reads on screen.
    ///
    /// **Reasoning is left out.** It's the model's scratch work rather than
    /// what it said, and it runs many times the length of the reply — a common
    /// word would match the reasoning in most conversations and bury the
    /// answers underneath it.
    ///
    /// Tool messages are left out for the same reason: their content is the
    /// machinery of an answer, not the answer.
    static func searchableText(of message: Message) -> String {
        guard message.role == .user || message.role == .assistant else { return "" }
        return withoutReasoning(message.content ?? "")
    }

    /// The whole conversation as one searchable string, for deciding whether a
    /// conversation is worth showing at all.
    static func searchableText(of messages: [Message]) -> String {
        messages.map(searchableText(of:)).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Strips reasoning blocks, closed or still open.
    ///
    /// An unclosed block runs to the end of the text — that's a reply that was
    /// interrupted or is still arriving, and none of what follows the opening
    /// tag is an answer yet.
    static func withoutReasoning(_ text: String) -> String {
        var result = text
        for tag in ["think", "thinking"] {
            while let open = result.range(of: "<\(tag)>") {
                guard let close = result.range(
                    of: "</\(tag)>",
                    range: open.upperBound..<result.endIndex
                ) else {
                    result = String(result[..<open.lowerBound])
                    break
                }
                result.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func contains(_ query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return false }
        return text.range(of: query, options: options) != nil
    }

    static func matchCount(of query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while let found = text.range(of: query, options: options, range: searchStart..<text.endIndex) {
            count += 1
            // Advances past the match rather than by one character, so
            // "aa" finds two in "aaaa" and not three.
            searchStart = found.upperBound
            if searchStart >= text.endIndex { break }
        }
        return count
    }

    /// One occurrence of the query, in the order they appear.
    ///
    /// An occurrence rather than a message. It used to be a message and a
    /// count, because a match couldn't be marked in the text — so the arrows
    /// moved between messages and the count had to say "messages" or promise
    /// something it couldn't keep. Now that a match can be marked where it
    /// sits, the count is the number of matches and the arrows go to each one.
    struct Match: Equatable, Identifiable {
        let messageID: String

        /// Which occurrence within its own message this is, counting from
        /// zero. What the renderer needs to know to mark this one differently
        /// from its neighbours.
        let ordinal: Int

        var id: String { "\(messageID)#\(ordinal)" }
    }

    static func matches(for query: String, in messages: [Message]) -> [Match] {
        guard !query.isEmpty else { return [] }
        return messages.flatMap { message in
            (0..<matchCount(of: query, in: searchableText(of: message))).map {
                Match(messageID: message.id, ordinal: $0)
            }
        }
    }

    /// Enough text around the first match to recognise it, for a list of
    /// results.
    ///
    /// Starts a little before the match rather than at it, so the term has the
    /// words that introduce it — a snippet beginning mid-match reads as a
    /// fragment of nothing.
    static func snippet(for query: String, in text: String, limit: Int = 120) -> String? {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }

        guard let found = flattened.range(of: query, options: options) else {
            return String(flattened.prefix(limit))
        }

        let lead = 24
        var start = flattened.index(found.lowerBound, offsetBy: -lead, limitedBy: flattened.startIndex)
            ?? flattened.startIndex
        // Backs up to a word boundary so the snippet doesn't open mid-word.
        if start != flattened.startIndex,
           let space = flattened[start...].firstIndex(of: " ") {
            start = flattened.index(after: space)
        }

        let end = flattened.index(start, offsetBy: limit, limitedBy: flattened.endIndex)
            ?? flattened.endIndex
        var snippet = String(flattened[start..<end])
        if start != flattened.startIndex { snippet = "…" + snippet }
        if end != flattened.endIndex { snippet += "…" }
        return snippet
    }
}
