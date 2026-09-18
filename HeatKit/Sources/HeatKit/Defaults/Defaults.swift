import Foundation
import GenKit

public struct Defaults {

    public static let services: [Service] = [
        anthropic,
        deepseek,
        elevenlabs,
        fal,
        grok,
        groq,
        mistral,
        ollama,
        openAI,
    ]

    public static let instructions: [(id: String, name: String, object: Instruction)] = [
        (instructionAssistantID, "Assistant", assistantInstruction),
        (instructionCompactionID, "Compaction", compactionInstruction),
        (instructionMemoryID, "Memory", memoryInstruction),
        (instructionSuggestionsID, "Suggestions", suggestionsInstruction),
        (instructionThinkingBriefID, "Thinking (Brief)", thinkingBriefInstruction),
        (instructionTitleID, "Title", titleInstruction),
        // "Web Search" is no longer seeded. It was never read from the file:
        // the tool used the default text directly, so editing it in Settings
        // changed nothing — and the text itself now lives in the tool's own
        // description, sent once rather than with every result. An install
        // that already has the file keeps it, unread; it can be deleted.
    ]

    public static let instructionAssistantID = "instruction-assistant"
    public static let instructionCompactionID = "instruction-compaction"
    public static let instructionMemoryID = "instruction-memory"
    public static let instructionSuggestionsID = "instruction-suggestions"
    public static let instructionThinkingBriefID = "instruction-thinking-brief"
    public static let instructionTitleID = "instruction-title"
    public static let instructionWebSearchID = "instruction-web-search"
}
