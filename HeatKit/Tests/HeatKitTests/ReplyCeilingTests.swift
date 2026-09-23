import Foundation
import Testing
import GenKit

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

/// Models a service serves that don't answer chat.
///
/// A service's model list is everything it serves, whatever each one does:
/// Groq's holds Whisper and Orpheus beside the models that converse, and no
/// field in the list reports a modality. So the attempt is the only thing
/// that can say — asking Whisper to chat answers "The model
/// `whisper-large-v3` does not support chat completions".
struct ModelsWithoutChatTests {

    private static func groq(_ models: [String]) -> Service {
        Service(kind: .groq, name: "Groq", models: models.map { Model(id: $0, owner: "groq") })
    }

    private static let whisper = Model(id: "whisper-large-v3", owner: "groq")

    @Test("Nothing is assumed until a model has refused")
    func nothingAssumed() {
        let service = Self.groq(["whisper-large-v3", "openai/gpt-oss-120b"])
        let config = Config()
        #expect(config.isModelWithoutChat(Self.whisper, in: service) == false)
        #expect(config.enabledModels(in: service).count == 2)
    }

    @Test("A model that refused chat leaves the conversation's picker")
    func leavesThePicker() {
        let service = Self.groq(["whisper-large-v3", "openai/gpt-oss-120b"])
        var config = Config()
        config.markModelWithoutChat(Self.whisper, in: service)

        #expect(config.enabledModels(in: service).map(\.id) == ["openai/gpt-oss-120b"])
        #expect(config.modelsWithoutChatCount(in: service) == 1)
    }

    /// The point of keeping this apart from `unavailableModels`: the model
    /// works, so it stays listed and stays choosable for what it does do.
    @Test("It is not marked unavailable, and the choice about it is untouched")
    func stillThereForOtherJobs() {
        let service = Self.groq(["whisper-large-v3"])
        var config = Config()
        config.setModelEnabled(true, for: Self.whisper, in: service)
        config.markModelWithoutChat(Self.whisper, in: service)

        #expect(config.isModelUnavailable(Self.whisper, in: service) == false)
        #expect(config.isModelEnabled(Self.whisper, in: service) == true)
        #expect(service.models.count == 1, "still listed by the service")
    }

    @Test("Offer Again forgets it, for the service alone")
    func cleared() {
        let groq = Self.groq(["whisper-large-v3"])
        var openRouter = Self.groq(["whisper-large-v3"])
        openRouter.kind = .openRouter
        var config = Config()
        config.markModelWithoutChat(Self.whisper, in: groq)
        config.markModelWithoutChat(Self.whisper, in: openRouter)

        config.clearModelsWithoutChat(in: groq)
        #expect(config.isModelWithoutChat(Self.whisper, in: groq) == false)
        #expect(config.isModelWithoutChat(Self.whisper, in: openRouter) == true)
    }

    @Test("It survives being written out and read back")
    func roundTrips() throws {
        let service = Self.groq(["whisper-large-v3"])
        var config = Config()
        config.markModelWithoutChat(Self.whisper, in: service)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded.isModelWithoutChat(Self.whisper, in: service) == true)
    }
}

/// Models a service has dated and gone on listing past the date.
///
/// OpenAI dates 58 of the 136 models it lists, and on 23 Sept 2026
/// seventeen of those dates had already passed — `gpt-5-codex`,
/// `gpt-5.1-codex`, `gpt-5.2-codex`, `gpt-5-chat-latest` and three more,
/// every one of which a guess from the name takes for a good chat model.
struct RetiredModelTests {

    private static func openAI(_ models: [Model]) -> Service {
        Service(kind: .openAI, name: "OpenAI", models: models)
    }

    private static func model(_ id: String, retiresOn: Date?) -> Model {
        Model(id: id, owner: "openai", retiresOn: retiresOn)
    }

    private static let twoDays: TimeInterval = 86_400 * 2

    @Test("A model past its date is not offered")
    func pastDate() {
        let service = Self.openAI([
            Self.model("gpt-5-codex", retiresOn: .now.addingTimeInterval(-Self.twoDays)),
            Self.model("gpt-5.6-sol", retiresOn: nil),
        ])
        #expect(Config().enabledModels(in: service).map(\.id) == ["gpt-5.6-sol"])
    }

    /// A date still to come is a warning, not a reason to withhold it.
    @Test("A model with a date still to come is offered")
    func futureDate() {
        let service = Self.openAI([Self.model("gpt-4o", retiresOn: .now.addingTimeInterval(Self.twoDays))])
        #expect(Config().enabledModels(in: service).count == 1)
    }

    /// No announced end is not the same as no end — `gpt-4o-search-preview`
    /// refused requests for months carrying no date at all, which is what
    /// the learned refusals and the blacklist are still for.
    @Test("A model with no date is offered")
    func noDate() {
        let service = Self.openAI([Self.model("gpt-5.6-sol", retiresOn: nil)])
        #expect(Config().enabledModels(in: service).count == 1)
    }

    /// It is a day, not an instant. A model retiring today has today.
    ///
    /// Named like a chat model on purpose: OpenAI's guess from the name
    /// drops anything with `sora` or `image` in it, so a fixture called
    /// `sora-2` would be absent for a reason that has nothing to do with
    /// the date.
    @Test("The day itself is not past")
    func today() {
        let service = Self.openAI([Self.model("gpt-5.6-sol", retiresOn: .now)])
        #expect(Config().enabledModels(in: service).count == 1)
    }

    /// Nothing is recorded against the model: the service says this every
    /// time it is asked, so there is no decision of anyone's to overrule
    /// and none to forget when a date moves.
    @Test("It is read from the model, not remembered against it")
    func notRecorded() {
        let retired = Self.model("gpt-5-codex", retiresOn: .now.addingTimeInterval(-Self.twoDays))
        let service = Self.openAI([retired])
        var config = Config()
        config.setModelEnabled(true, for: retired, in: service)

        #expect(config.enabledModels(in: service).isEmpty)
        #expect(config.isModelUnavailable(retired, in: service) == false)
        #expect(config.isModelEnabled(retired, in: service) == true)
    }
}
