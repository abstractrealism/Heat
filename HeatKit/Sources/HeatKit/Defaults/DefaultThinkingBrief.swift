import Foundation

extension Defaults {

    /// What "Brief" adds to the system prompt.
    ///
    /// Kept as an editable instruction because the wording is the mechanism.
    /// Measured against local models: a polite request — "Think briefly. Keep
    /// your reasoning to a couple of short sentences" — produced *103%* of an
    /// unsteered control, which is to say nothing at all. This wording cut
    /// reasoning to 14% on qwen3.6:27b, 25% on muse-glimmer:30b-mlx, 38% on
    /// qwen3.5:4b and 56% on gemma4:26b, with every answer still correct.
    ///
    /// Naming a level and then forbidding the specific habits — double-checking,
    /// exploring alternatives — is what separates it from the version that did
    /// nothing. Anything softer is likely to stop working.
    public static let thinkingBriefInstruction = Instruction(
        kind: .system,
        instructions: """
            Reasoning effort: low. Do the minimum thinking needed, then answer immediately. Do not double-check or explore alternatives.
            """
    )
}
