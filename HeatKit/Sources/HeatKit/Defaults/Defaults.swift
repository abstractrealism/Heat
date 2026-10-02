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
        openRouter,
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

    /// Prompts that are seeded and listed but that nothing reads yet.
    ///
    /// Memory is a feature that was begun and not finished: the prompt is
    /// here, it appears in Settings with its own editor, its own tabs and a
    /// working Restore Default, and no code anywhere sends it. Marked rather
    /// than retired, because the text is worth keeping for when the feature
    /// is picked up — and marked rather than left alone, because an editor
    /// that takes your changes and ignores them is the same fault as an
    /// address field that goes nowhere or a slider that reads 16k when it
    /// means something else.
    public static let unimplementedInstructionIDs: Set<String> = [
        instructionMemoryID,
    ]

    public static let instructionAssistantID = "instruction-assistant"
    public static let instructionCompactionID = "instruction-compaction"
    public static let instructionMemoryID = "instruction-memory"
    public static let instructionSuggestionsID = "instruction-suggestions"
    public static let instructionThinkingBriefID = "instruction-thinking-brief"
    public static let instructionTitleID = "instruction-title"
    public static let instructionWebSearchID = "instruction-web-search"
}
