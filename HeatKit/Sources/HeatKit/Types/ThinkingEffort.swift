import Foundation

/// How much reasoning to ask a model for before it answers.
///
/// **Brief is a prompt, not a setting on the request**, and that's a measured
/// choice rather than a shortcut. Ollama does accept a graded `think` —
/// `"low"`, `"medium"`, `"high"`, `"max"` — but of four local models tested,
/// only one honoured it; the other three returned byte-identical output at
/// every level. Steering through the prompt worked on all four, and on the one
/// model that supports both, the prompt alone beat the native level and adding
/// the native level on top changed the result by about four percent, well
/// inside the run-to-run spread. Threading a new type through two packages to
/// buy that wasn't worth it.
///
/// The wording matters more than the mechanism. "Think briefly" achieved
/// nothing at all — 103% of an unsteered control. What worked was blunt and
/// specific, which is why the text lives in an instruction anyone can edit
/// rather than in the code.
///
/// There's no level above `full` because there's nothing to ask for: told to
/// reason thoroughly, the models tested produced 98% of what they already did
/// unprompted. Full effort is what they do when left alone.
public enum ThinkingEffort: String, Codable, Sendable, CaseIterable, Identifiable {

    /// No reasoning at all — `think: false`.
    case off

    /// Reasoning, kept short by instruction.
    case brief

    /// Whatever the model does unprompted.
    case full

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .brief: "Brief"
        case .full: "Full"
        }
    }

    public var detail: String {
        switch self {
        case .off: "Answer without reasoning first"
        case .brief: "Reason, but don't labour it"
        case .full: "Reason as much as the model wants"
        }
    }

    /// Whether the model reasons at all, which is the only part the request
    /// itself carries.
    public var isThinking: Bool {
        self != .off
    }
}
