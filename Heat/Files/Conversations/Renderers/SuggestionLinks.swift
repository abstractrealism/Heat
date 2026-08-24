import Foundation

/// Marks the links that *do* something, so they can be told from the ones that
/// merely go somewhere.
///
/// A `heat://` link isn't navigation: following one submits its text as a new
/// message and starts a generation. An ordinary markdown link is
/// indistinguishable from it on screen, so there was no way to know which
/// clicks would set a model running.
///
/// **Why the text and not the style.** MarkdownUI's `Theme.link` is a
/// `TextStyle` with no sight of the destination, so links cannot be styled by
/// where they point. Its renderer does apply the link style and *then* render
/// the link's children, which means anything nested inside the brackets is
/// rendered normally — so a marker put in the link text arrives on screen even
/// though a per-link style never could.
///
/// Only what's drawn changes. The stored message keeps the text the model
/// wrote, and the URL is untouched, so `onOpenURL` still receives exactly what
/// it did before.
enum SuggestionLinks {

    /// What precedes a link that asks something. One character, changed here
    /// and nowhere else.
    static let marker = "✦"

    private static let scheme = "heat://"

    static func marked(_ text: String) -> String {
        guard text.contains(scheme) else { return text }

        // Odd-numbered segments are inside ``` fences, where a link is
        // literal text somebody wants to read as written.
        return text
            .components(separatedBy: "```")
            .enumerated()
            .map { $0.offset % 2 == 1 ? $0.element : mark(in: $0.element) }
            .joined(separator: "```")
    }

    private static func mark(in segment: String) -> String {
        guard segment.contains(scheme) else { return segment }

        let pattern = #"\[([^\]\n]*)\]\((heat://[^)\s]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return segment }

        let string = segment as NSString
        var out = ""
        var cursor = 0

        for match in regex.matches(in: segment, range: NSRange(location: 0, length: string.length)) {
            out += string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))

            let label = string.substring(with: match.range(at: 1))
            let destination = string.substring(with: match.range(at: 2))
            let trimmed = label.trimmingCharacters(in: .whitespaces)

            // Left alone when it's already marked — the same message is
            // rendered many times, and a marker per render would stack up.
            // An empty label has nothing to mark and would leave a lone glyph
            // standing in for a link.
            if trimmed.isEmpty || trimmed.hasPrefix(marker) {
                out += string.substring(with: match.range)
            } else {
                out += "[\(marker) \(label)](\(destination))"
            }
            cursor = match.range.location + match.range.length
        }

        out += string.substring(from: cursor)
        return out
    }
}
