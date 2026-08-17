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
        (instructionTitleID, "Title", titleInstruction),
        (instructionWebSearchID, "Web Search", webSearchInstruction),
    ]

    public static let instructionAssistantID = "instruction-assistant"
    public static let instructionCompactionID = "instruction-compaction"
    public static let instructionMemoryID = "instruction-memory"
    public static let instructionSuggestionsID = "instruction-suggestions"
    public static let instructionTitleID = "instruction-title"
    public static let instructionWebSearchID = "instruction-web-search"
}
