import Foundation

extension Defaults {

    /// What "Brief" adds to the system prompt.
    ///
    /// Kept as an editable instruction because the wording *is* the mechanism,
    /// and the differences between wordings are enormous.
    ///
    /// Four were measured across four models on six questions, against an
    /// unsteered baseline. What matters is not the average saving — they were
    /// all similar — but whether a wording ever **backfires**, making a model
    /// reason far more rather than less:
    ///
    /// | wording | median | worst | backfires |
    /// |---|---|---|---|
    /// | Do the minimum, don't double-check or explore alternatives | 49–87% | **498%** | 2, and one wrong answer |
    /// | Keep reasoning under ~100 words | 53–395% | **656%** | 5 |
    /// | **This one** | 52–76% | 131% | **1** |
    /// | Take the shortest sound route | 52–134% | 159% | 2 |
    ///
    /// The failure being avoided: told *not* to check its work on a question
    /// whose obvious answer is wrong, a model flails — 8327 characters against
    /// a baseline of 2141 on qwen3.5:4b. Permitting a single check and
    /// forbidding only the *looping* keeps the brevity without the flailing.
    /// A word budget was worst of all: told to count words, a small model
    /// reasons about counting words.
    ///
    /// Every answer was correct under this wording, 21 of 21.
    ///
    /// No wording was safe everywhere, so anything replacing this should be
    /// measured the same way — on a small model *and* a large one, since the
    /// shortest-route wording was best on three models and worst on the fourth.
    public static let thinkingBriefInstruction = Instruction(
        kind: .system,
        instructions: """
            Reasoning effort: low. Reason concisely and in a single pass. You may check a result once, but do not re-derive it or work through alternative approaches.
            """
    )
}
