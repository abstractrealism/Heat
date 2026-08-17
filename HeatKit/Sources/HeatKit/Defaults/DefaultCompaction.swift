import Foundation

extension Defaults {

    /// Turns a conversation so far into notes the assistant can carry on from.
    ///
    /// Deliberately short and direct. The Title and Suggestions prompts weigh
    /// conditions and branch, which large models handle and small ones drop —
    /// and this runs on the summarization model, which is where somebody puts
    /// the small fast one.
    public static let compactionInstruction = Instruction(
        kind: .task,
        instructions: """
            You are compacting a conversation so it can continue in less space. Here is the conversation:

            <conversation>
            {{history}}
            </conversation>

            Write notes that let the assistant carry on as though it had read all of it. Include:

            1. What the user is trying to do, and what has already been decided.
            2. Specifics that may be needed again: names, numbers, file paths, identifiers, code or commands that came up.
            3. Anything still unresolved or agreed to happen next.

            Leave out greetings, restatements, and anything since superseded. Prefer the later version of a fact over an earlier one. Write for the assistant's own use, not as a message to the user, and do not address the user directly.
            {{guidance}}
            Output the notes inside <summary> tags.
            """
    )
}
