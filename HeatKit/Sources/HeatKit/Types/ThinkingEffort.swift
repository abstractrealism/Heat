import Foundation
import GenKit

/// How much reasoning to ask a model for before it answers.
///
/// One vocabulary covering every provider, because a conversation keeps its
/// setting and can be moved to another model. Each service offers the levels
/// that mean something to it — see `offered(by:)` — and maps anything else to
/// its nearest equivalent, so a conversation carried from one provider to
/// another still asks for roughly what it asked for before.
///
/// **`brief` is a prompt, not a setting on the request**, and that's a measured
/// choice rather than a shortcut. Ollama does accept a graded `think` —
/// `"low"`, `"medium"`, `"high"`, `"max"` — but of four local models tested,
/// only one honoured it; the other three returned byte-identical output at
/// every level. Steering through the prompt worked on all four, and on the one
/// model that supports both, the prompt alone beat the native level and adding
/// the native level on top changed the result by about four percent, well
/// inside the run-to-run spread.
///
/// The graded levels below are a different matter: Anthropic's `effort` is a
/// real request parameter that the model is trained against, and the API
/// rejects what it doesn't support rather than quietly ignoring it. So local
/// models get `brief`/`full` steered by instruction, and services with a
/// genuine effort control get the levels they actually implement.
///
/// The wording matters more than the mechanism. "Think briefly" achieved
/// nothing at all — 103% of an unsteered control. What worked was blunt and
/// specific, which is why the text lives in an instruction anyone can edit
/// rather than in the code.
public enum ThinkingEffort: String, Codable, Sendable, CaseIterable, Identifiable {

    /// No reasoning at all.
    case off

    /// Reasoning, kept short by instruction. Local models.
    case brief

    /// Whatever the model does unprompted. Local models.
    ///
    /// There's no level above this for them because there's nothing to ask
    /// for: told to reason thoroughly, the models tested produced 98% of what
    /// they already did unprompted.
    case full

    /// Graded levels, for services whose API takes one.
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .brief: "Brief"
        case .full: "Full"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Maximum"
        }
    }

    public var detail: String {
        switch self {
        case .off: "Answer without reasoning first"
        case .brief: "Reason, but don't labour it"
        case .full: "Reason as much as the model wants"
        case .low: "Least reasoning, for speed and cost"
        case .medium: "A balance of speed and depth"
        case .high: "Thorough. What the model does left alone"
        case .xhigh: "More again, for long or difficult work"
        case .max: "As much as it takes, whatever the cost"
        }
    }

    /// Whether the model reasons at all, which is the only part of this that
    /// every provider can express.
    public var isThinking: Bool {
        self != .off
    }

    /// The levels a *default* can be expressed in — the ones that mean
    /// something whichever service a new conversation turns out to use.
    ///
    /// A default is set once and applies to every service, so it can't be
    /// stated in one service's private vocabulary. Each service maps these
    /// onto its own levels.
    public static let universal: [ThinkingEffort] = [.off, .brief, .full]

    /// The levels worth showing for a service, in the order to show them.
    ///
    /// A service that has no real effort control gets the steered pair, since
    /// offering five levels that three of four models ignore would be a menu
    /// of things that don't happen. One that does gets the levels its API
    /// actually implements.
    public static func offered(by kind: Service.Kind) -> [ThinkingEffort] {
        switch kind {
        case .anthropic:
            [.off, .low, .medium, .high, .xhigh, .max]
        case .openAI:
            // The union of what its models take. The newest take none through
            // xhigh; gpt-5 stops at high and can't be told none, and asking
            // it for either gets the nearest it has — gen-kit's table decides
            // per model, and says so in the log.
            [.off, .low, .medium, .high, .xhigh]
        case .deepseek:
            // Three levels, from its own guide: the endpoint accepts every
            // name but documents medium and xhigh as high, so offering them
            // would be two more names for one thing. High is what it does
            // left alone. Off is a switch of its own, which gen-kit throws.
            [.off, .low, .high, .max]
        case .groq:
            // The union of what its reasoning models take, from its API
            // reference: gpt-oss low/medium/high with no off (struck
            // through, and Off asks for low), qwen3.8 off through high.
            // Llama doesn't reason and is sent nothing whatever is chosen.
            [.off, .low, .medium, .high]
        default:
            [.off, .brief, .full]
        }
    }

    /// This level expressed in the levels a service offers, for a conversation
    /// that has moved between providers.
    ///
    /// Exact where the level is offered; otherwise the nearest by depth, which
    /// is what the declaration order below describes. `off` never becomes
    /// anything else — asking for no reasoning and getting some is the one
    /// substitution nobody would want.
    public func offered(by kind: Service.Kind) -> ThinkingEffort {
        let available = Self.offered(by: kind)
        if available.contains(self) { return self }
        if self == .off { return .off }

        let depth: [ThinkingEffort] = [.off, .low, .brief, .medium, .high, .full, .xhigh, .max]
        guard let position = depth.firstIndex(of: self) else { return available.last ?? .off }

        // The offered level whose depth is closest to this one's.
        return available
            .filter { $0 != .off }
            .min { a, b in
                let da = depth.firstIndex(of: a) ?? 0
                let db = depth.firstIndex(of: b) ?? 0
                return abs(da - position) < abs(db - position)
            } ?? .off
    }
}
