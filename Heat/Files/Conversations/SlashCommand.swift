import Foundation

/// A typed instruction to the app rather than a message to the model.
///
/// Only exact known commands are recognised. Anything else beginning with a
/// slash is sent as an ordinary message, because plenty of real messages start
/// with one — a path, a regex, a fraction — and swallowing those to catch a
/// mistyped command would be the worse trade.
enum SlashCommand: Equatable {

    /// Fold the conversation so far into notes, optionally with a steer about
    /// what to keep.
    case compact(guidance: String?)

    /// Drop the conversation from the model's view without keeping notes.
    case clear

    /// Every command, for anything offering them as suggestions.
    static let all: [(name: String, summary: String)] = [
        ("/compact", "Summarize the conversation so far to free up context"),
        ("/clear", "Start fresh in this conversation, keeping the transcript"),
    ]

    init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        // Split once: the command is the first word, and everything after it is
        // the argument, kept verbatim so guidance can be an ordinary sentence
        // rather than something needing quoting.
        let withoutSlash = trimmed.dropFirst()
        let parts = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map(String.init)?.lowercased() ?? ""
        let argument = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        switch name {
        case "compact":
            self = .compact(guidance: argument.isEmpty ? nil : argument)
        case "clear":
            // No argument to take, and a stray one likely means the command was
            // misremembered — better sent as a message than acted on.
            guard argument.isEmpty else { return nil }
            self = .clear
        default:
            return nil
        }
    }
}
