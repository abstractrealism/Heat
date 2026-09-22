import Foundation
import Testing

@testable import HeatKit

/// What a provider allows a reply that asks for no ceiling of its own.
///
/// Nothing publishes it. Groq cut a `gpt-oss-120b` answer off at 3,072
/// tokens with no error and nothing anywhere saying why, while Settings
/// showed a slider resting at 16,384 — which was an invented starting
/// position, not a figure in force. The only thing that can say what a
/// provider allows is a reply that ran into it, and then the count is the
/// answer, because the ceiling is what stopped it.
struct ReplyCeilingTests {

    private static let service = "groq"
    private static let model = "openai/gpt-oss-120b"

    @Test("Nothing is claimed until a reply has run into it")
    func unknownAtFirst() {
        let config = Config()
        #expect(config.replyCeilingSeen(serviceID: Self.service, modelID: Self.model) == nil)
    }

    @Test("What stopped a reply is remembered")
    func remembered() {
        var config = Config()
        config.noteReplyCeiling(3072, serviceID: Self.service, modelID: Self.model)
        #expect(config.replyCeilingSeen(serviceID: Self.service, modelID: Self.model) == 3072)
    }

    /// A provider that raises its default shouldn't be remembered at the old
    /// figure, so the largest seen wins.
    @Test("The largest seen wins, whichever order they arrive in")
    func largestWins() {
        var config = Config()
        config.noteReplyCeiling(3072, serviceID: Self.service, modelID: Self.model)
        config.noteReplyCeiling(8192, serviceID: Self.service, modelID: Self.model)
        config.noteReplyCeiling(1024, serviceID: Self.service, modelID: Self.model)
        #expect(config.replyCeilingSeen(serviceID: Self.service, modelID: Self.model) == 8192)
    }

    /// A provider serving several models needn't allow them the same, and two
    /// services can offer a model of the same name without being the same
    /// endpoint.
    @Test("Kept per model and per service")
    func keyedByBoth() {
        var config = Config()
        config.noteReplyCeiling(3072, serviceID: Self.service, modelID: Self.model)
        #expect(config.replyCeilingSeen(serviceID: Self.service, modelID: "qwen/qwen3.8-27b") == nil)
        #expect(config.replyCeilingSeen(serviceID: "openrouter", modelID: Self.model) == nil)
    }

    @Test("It survives being written out and read back")
    func roundTrips() throws {
        var config = Config()
        config.noteReplyCeiling(3072, serviceID: Self.service, modelID: Self.model)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded.replyCeilingSeen(serviceID: Self.service, modelID: Self.model) == 3072)
    }

    /// The setting itself is untouched by any of this: what a provider was
    /// seen to allow is an observation, not a choice, and a request carries
    /// no ceiling until somebody sets one.
    @Test("Observing a ceiling doesn't set one")
    func observationIsNotAChoice() {
        var config = Config()
        config.noteReplyCeiling(3072, serviceID: Self.service, modelID: Self.model)
        #expect(config.maxTokens(serviceID: Self.service) == nil)
    }
}
