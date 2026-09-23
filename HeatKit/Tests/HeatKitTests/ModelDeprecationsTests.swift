import Foundation
import Testing
import GenKit

@testable import HeatKit

/// What's left of reading OpenAI's deprecations page: a short list of
/// aliases whose whole family has gone.
///
/// The page-reading itself is gone, and with it the tests that drove its
/// Markdown table parser over a captured copy. It was compared against the
/// API first: every model now carries a `shutdown_date`, and of the ids the
/// page names that carry none, not one is still in `/v1/models` — so the
/// page found nothing the dates don't, at the cost of an HTTP request and a
/// parser that a redesign could silently break.
struct ModelDeprecationsTests {

    /// The two met the hard way, by a request being refused. Neither has a
    /// shutdown date of its own, which is exactly why a list is needed:
    /// `gpt-4o-search-preview-2025-03-11` is dated and the alias isn't, and
    /// the date can't be moved from one to the other.
    @Test("The withdrawn aliases are named")
    func openAIAliases() {
        let known = ModelDeprecations.alreadyKnown(for: .openAI)
        #expect(known.contains("gpt-4o-search-preview"))
        #expect(known.contains("gpt-4o-mini-search-preview"))
    }

    /// Nothing is claimed about a model that still works. `gpt-5-search-api`
    /// succeeded the pair above and is not withdrawn; nor are the dated
    /// snapshots, which carry dates and are handled by them.
    @Test("Nothing else is claimed", arguments: [
        "gpt-5-search-api", "gpt-4o", "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-pro", "o3",
        "gpt-4o-search-preview-2025-03-11",
    ])
    func livingModels(id: String) {
        #expect(!ModelDeprecations.alreadyKnown(for: .openAI).contains(id))
    }

    /// It is OpenAI's aliases and nobody else's — the other services either
    /// date their models or don't outlive them.
    @Test("Other services have none", arguments: [
        Service.Kind.anthropic, .deepseek, .groq, .grok, .mistral, .ollama, .openRouter,
    ])
    func otherServices(kind: Service.Kind) {
        #expect(ModelDeprecations.alreadyKnown(for: kind).isEmpty)
    }
}
