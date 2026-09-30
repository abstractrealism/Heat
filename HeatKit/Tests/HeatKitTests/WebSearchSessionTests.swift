import Foundation
import Testing

@testable import HeatKit

/// The pacing and the holding, driven without going near the network.
///
/// A model asks for two or three searches at once, so they arrive together
/// and are spaced out by the session. What the spacing did not account for
/// is the world changing while a search waited its turn: measured in a real
/// conversation, a challenge landed at 11:43:39 and another request went out
/// 6.7 seconds later, straight into the block we had just been told about.
struct WebSearchSessionTests {

    /// A defaults store of its own per test, so a hold recorded by one
    /// doesn't reach another — and so none of them touches the real one.
    private static func freshStoreName() -> String {
        "webSearchTests.\(UUID().uuidString)"
    }

    /// Long enough to queue, short enough not to sleep through the suite.
    /// What the shipped gap actually is has a test of its own.
    private static let brisk: ClosedRange<TimeInterval> = 0.05...0.1

    /// Answers however it is told to, and counts what it was asked.
    private final class Engine: WebSearch, WebImageSearch, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Result<Int, any Error>]
        private(set) var asked: [String] = []

        init(_ answers: [Result<Int, any Error>]) {
            self.answers = answers
        }

        func search(web query: String) async throws -> WebSearchResponse {
            let answer: Result<Int, any Error> = lock.withLock {
                asked.append(query)
                return answers.isEmpty ? .success(0) : answers.removeFirst()
            }
            switch answer {
            case .success(let count):
                return WebSearchResponse(
                    query: query,
                    results: (0..<count).map {
                        WebSearchResult(url: URL(string: "https://example.invalid/\($0)")!, title: "\($0)")
                    }
                )
            case .failure(let error):
                throw error
            }
        }

        func search(images query: String) async throws -> WebSearchResponse {
            try await search(web: query)
        }
    }

    /// The bug, reproduced: two searches asked for at once, the first
    /// refused. The second was already asleep in the queue and knew nothing
    /// about it.
    @Test("A search waiting its turn doesn't go once a challenge has landed")
    func queuedSearchStandsDown() async throws {
        let engine = Engine([.failure(WebSearchError.challenged)])
        let session = WebSearchSession(engine: engine, spacing: Self.brisk, storeName: Self.freshStoreName())

        async let first: WebSearchResponse = session.search(query: "one")
        async let second: WebSearchResponse = session.search(query: "two")

        var firstError: (any Error)?
        var secondError: (any Error)?
        do { _ = try await first } catch { firstError = error }
        do { _ = try await second } catch { secondError = error }

        #expect(engine.asked == ["one"], "only the first ever reached the engine")

        guard case .challenged? = firstError as? WebSearchError else {
            Issue.record("the first was the one refused: \(String(describing: firstError))")
            return
        }
        guard case .holdingOff? = secondError as? WebSearchError else {
            Issue.record("the second should stand down, not be challenged itself: \(String(describing: secondError))")
            return
        }
    }

    /// And the hold stays where it was.
    ///
    /// The doubling means "the hold was too short — a request made after it
    /// expired was refused again". A second request from the same burst is
    /// not that, and it used to double the hold on the strength of a request
    /// that should never have left.
    @Test("A second refusal from the same burst doesn't lengthen the hold")
    func holdIsNotDoubledByItsOwnBurst() async throws {
        let engine = Engine([
            .failure(WebSearchError.challenged),
            .failure(WebSearchError.challenged),
        ])
        let session = WebSearchSession(engine: engine, spacing: Self.brisk, storeName: Self.freshStoreName())

        async let first: WebSearchResponse = session.search(query: "one")
        async let second: WebSearchResponse = session.search(query: "two")
        _ = try? await first
        _ = try? await second

        // Whatever is left of the hold, it is the first one and not twice it.
        do {
            _ = try await session.search(query: "three")
            Issue.record("a search went through during a hold")
        } catch let WebSearchError.holdingOff(remaining) {
            #expect(remaining > 14 * 60)
            #expect(remaining <= 15 * 60, "the first rung, not the one above it")
        }
    }

    @Test("An ordinary search is answered and the engine is asked once")
    func ordinarySearch() async throws {
        let engine = Engine([.success(10)])
        let session = WebSearchSession(engine: engine, spacing: Self.brisk, storeName: Self.freshStoreName())

        let response = try await session.search(query: "tofu")
        #expect(response.results.count == 10)
        #expect(engine.asked == ["tofu"])
    }

    /// Two that both succeed are spaced rather than fired together — the
    /// burst is what trips the challenge in the first place.
    @Test("Searches asked for together are spaced apart")
    func searchesAreSpaced() async throws {
        let engine = Engine([.success(1), .success(1)])
        let session = WebSearchSession(engine: engine, spacing: Self.brisk, storeName: Self.freshStoreName())

        let started = Date.now
        async let first: WebSearchResponse = session.search(query: "one")
        async let second: WebSearchResponse = session.search(query: "two")
        _ = try await first
        _ = try await second

        #expect(Date.now.timeIntervalSince(started) >= Self.brisk.lowerBound, "the second waited for the first")
        #expect(engine.asked.count == 2)
    }

    /// The figure that actually ships, which the tests above deliberately
    /// don't use. Widened from 4–10 once a hosted model made the gap the
    /// only thing pacing a searching turn: twelve requests in seventy-two
    /// seconds, and the twelfth was refused.
    @Test("The shipped gap is the one intended")
    func shippedSpacing() {
        #expect(WebSearchSession.spacing == 7...15)
    }

    /// A success clears the hold, so a conversation isn't punished for a
    /// block that has since lifted.
    @Test("A search that works clears what came before it")
    func successClearsTheHold() async throws {
        let engine = Engine([.success(5)])
        let session = WebSearchSession(engine: engine, spacing: Self.brisk, storeName: Self.freshStoreName())

        _ = try await session.search(query: "tofu")
        // Nothing thrown means nothing held.
        #expect(engine.asked == ["tofu"])
    }
}

/// A challenge hold outlives the app, because a block does.
///
/// These used to be in memory alone, so quitting Heat — or rebuilding it,
/// which over a day's work is the same thing many times over — forgot the
/// block and sent the next question's searches straight into it. Measured on
/// 24 Sept 2026: a block outlasted eighty-two minutes of silence, so a
/// restart cannot be assumed to have outlived one.
struct WebSearchHoldPersistenceTests {

    private final class Refusing: WebSearch, WebImageSearch, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var asked = 0

        func search(web query: String) async throws -> WebSearchResponse {
            lock.withLock { asked += 1 }
            throw WebSearchError.challenged
        }

        func search(images query: String) async throws -> WebSearchResponse {
            try await search(web: query)
        }
    }

    private static let brisk: ClosedRange<TimeInterval> = 0.05...0.1

    /// A hold that expired and was challenged again goes to the next rung,
    /// which is an hour — not half of one, and not twice fifteen minutes.
    ///
    /// The ladder exists because every rung costs a request made into a live
    /// block, and those are the requests that lengthen it. Doubling from five
    /// minutes reached an hour only after five refusals; this reaches it
    /// after one. Every quick clear measured has been a session's first
    /// challenge, and every long one has followed several, so there is
    /// nothing worth trying between fifteen minutes and an hour.
    @Test("A hold that was too short steps up to an hour")
    func holdStepsToTheNextRung() async throws {
        let name = "webSearchHold.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))

        // As though a fifteen-minute hold had been set and had since run out.
        store.set(Date.now.addingTimeInterval(-20 * 60).timeIntervalSince1970, forKey: "webSearchChallengedAt")
        store.set(15 * 60, forKey: "webSearchHold")

        let engine = Refusing()
        let session = WebSearchSession(engine: engine, spacing: Self.brisk, storeName: name)

        // Goes out, because the hold expired — and is challenged again, which
        // is what "the hold was too short" means.
        _ = try? await session.search(query: "one")
        #expect(engine.asked == 1, "the expired hold let it through")

        do {
            _ = try await session.search(query: "two")
            Issue.record("a search went out during the new hold")
        } catch let WebSearchError.holdingOff(remaining) {
            #expect(remaining > 59 * 60, "an hour, not thirty minutes")
            #expect(remaining <= 60 * 60)
        }
    }

    @Test("A hold survives the session being rebuilt")
    func holdSurvives() async throws {
        let store = "webSearchHold.\(UUID().uuidString)"
        let engine = Refusing()

        let first = WebSearchSession(engine: engine, spacing: Self.brisk, storeName: store)
        _ = try? await first.search(query: "one")
        #expect(engine.asked == 1)

        // As though the app had been quit and opened again.
        let second = WebSearchSession(engine: engine, spacing: Self.brisk, storeName: store)
        do {
            _ = try await second.search(query: "two")
            Issue.record("a search went out during a hold that a restart forgot")
        } catch let WebSearchError.holdingOff(remaining) {
            // Most of the first hold is left; the figure tracks `holds[0]`.
            #expect(remaining > 14 * 60)
        }
        #expect(engine.asked == 1, "the second never reached the engine")
    }

    /// An image search is the same address and the same bucket, and costs two
    /// requests rather than one — the token page, then the JSON.
    @Test("An image search is held off too")
    func imagesAreHeld() async throws {
        let store = "webSearchHold.\(UUID().uuidString)"
        let engine = Refusing()

        let session = WebSearchSession(engine: engine, spacing: Self.brisk, storeName: store)
        _ = try? await session.search(query: "one")

        do {
            _ = try await session.searchImages(query: "a picture")
            Issue.record("an image search went out during a hold")
        } catch let WebSearchError.holdingOff(remaining) {
            // Most of the first hold is left; the figure tracks `holds[0]`.
            #expect(remaining > 14 * 60)
        }
        #expect(engine.asked == 1)
    }
}

/// The other provider, when the first one won't answer.
///
/// A search is a tool result, and one that says "the search engine is cross
/// with us" is a turn the model has to abandon. Where another provider is
/// configured it answers instead, and nothing upstream is told which one
/// did — the model asked for results and gets results.
struct WebSearchFallbackTests {

    private static let brisk: ClosedRange<TimeInterval> = 0.05...0.1

    private final class Refusing: WebSearch, WebImageSearch, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var asked = 0

        func search(web query: String) async throws -> WebSearchResponse {
            lock.withLock { asked += 1 }
            throw WebSearchError.challenged
        }

        func search(images query: String) async throws -> WebSearchResponse {
            try await search(web: query)
        }
    }

    private final class Answering: WebSearch, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var asked: [String] = []
        private let failing: Bool

        init(failing: Bool = false) { self.failing = failing }

        func search(web query: String) async throws -> WebSearchResponse {
            lock.withLock { asked.append(query) }
            if failing { throw BraveSearchError.rateLimited("out of credit") }
            return WebSearchResponse(
                query: query,
                results: [WebSearchResult(url: URL(string: "https://example.invalid/1")!, title: "from the fallback")]
            )
        }
    }

    private func session(
        _ first: Refusing,
        fallback: (any WebSearch & Sendable)?
    ) -> WebSearchSession {
        WebSearchSession(
            engine: first,
            spacing: Self.brisk,
            storeName: "webSearchFallback.\(UUID().uuidString)",
            fallback: { fallback }
        )
    }

    @Test("A refused search is answered by the other provider")
    func refusedIsAnsweredElsewhere() async throws {
        let first = Refusing()
        let second = Answering()

        let response = try await session(first, fallback: second).search(query: "tofu")

        #expect(first.asked == 1, "the first was tried")
        #expect(second.asked == ["tofu"], "and the second answered the same query")
        #expect(response.results.first?.title == "from the fallback")
    }

    /// Which is the whole point: a hold runs for half an hour and up, and
    /// nothing the model does shortens it.
    @Test("A search held off is answered by the other provider too")
    func heldOffIsAnsweredElsewhere() async throws {
        let first = Refusing()
        let second = Answering()
        let session = session(first, fallback: second)

        _ = try? await session.search(query: "one")   // trips the hold
        let response = try await session.search(query: "two")

        #expect(first.asked == 1, "the first wasn't asked again during its own hold")
        #expect(second.asked == ["one", "two"])
        #expect(response.results.isEmpty == false)
    }

    /// With nothing configured, the refusal is what comes back — the same
    /// error, worded the same way, as before there was a fallback at all.
    @Test("With no fallback the refusal stands")
    func noFallback() async {
        let first = Refusing()
        do {
            _ = try await session(first, fallback: nil).search(query: "tofu")
            Issue.record("expected the refusal")
        } catch let error as WebSearchError {
            if case .challenged = error {} else {
                Issue.record("the original refusal, not \(error)")
            }
        } catch {
            Issue.record("a WebSearchError, not \(error)")
        }
    }

    /// The first provider's refusal is the more useful of the two: it says
    /// the thing that will still be true in ten minutes.
    @Test("If the fallback fails too, the first refusal is what's reported")
    func bothFail() async {
        let first = Refusing()
        let second = Answering(failing: true)
        do {
            _ = try await session(first, fallback: second).search(query: "tofu")
            Issue.record("expected a refusal")
        } catch let error as WebSearchError {
            if case .challenged = error {} else {
                Issue.record("the first provider's refusal, not \(error)")
            }
        } catch {
            Issue.record("the first provider's refusal, not \(error)")
        }
        #expect(second.asked == ["tofu"], "it was tried before giving up")
    }

    /// Nothing in the response says which provider answered. A result is a
    /// link, a title and a snippet whoever found it.
    @Test("The model can't tell which provider answered")
    func indistinguishable() async throws {
        let first = Refusing()
        let second = Answering()

        let fallen = try await session(first, fallback: second).search(query: "tofu")
        let direct = try await Answering().search(web: "tofu")

        #expect(fallen.query == direct.query)
        #expect(fallen.results.map(\.url) == direct.results.map(\.url))
        #expect(fallen.results.map(\.title) == direct.results.map(\.title))
    }
}

/// Any way the first provider fails to produce results is a reason to ask
/// the other one — not only a refusal.
///
/// A scrape has more ways to stop working than an API does. The page can be
/// restructured out from under the parser, which is silent and total, and
/// that is exactly when a second provider is worth having.
struct WebSearchFallbackBreadthTests {

    private static let brisk: ClosedRange<TimeInterval> = 0.05...0.1

    private final class Failing: WebSearch, WebImageSearch, @unchecked Sendable {
        let error: any Error
        init(_ error: any Error) { self.error = error }
        func search(web query: String) async throws -> WebSearchResponse { throw error }
        func search(images query: String) async throws -> WebSearchResponse { throw error }
    }

    private final class Answering: WebSearch, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var asked: [String] = []
        func search(web query: String) async throws -> WebSearchResponse {
            lock.withLock { asked.append(query) }
            return WebSearchResponse(query: query, results: [
                WebSearchResult(url: URL(string: "https://example.invalid/1")!, title: "elsewhere")
            ])
        }
    }

    private func answered(after error: any Error) async throws -> (WebSearchResponse, Answering) {
        let second = Answering()
        let session = WebSearchSession(
            engine: Failing(error),
            spacing: Self.brisk,
            storeName: "fallbackBreadth.\(UUID().uuidString)",
            fallback: { second }
        )
        return (try await session.search(query: "tofu"), second)
    }

    /// The silent one: DuckDuckGo restructures its page and the parser finds
    /// nothing it recognises.
    @Test("A page the parser can't read falls through")
    func unreadablePage() async throws {
        let (response, second) = try await answered(after: WebSearchError.missingElement("#links .result"))
        #expect(response.results.first?.title == "elsewhere")
        #expect(second.asked == ["tofu"])
    }

    @Test("Markup that isn't HTML falls through")
    func invalidHTML() async throws {
        let (response, second) = try await answered(after: WebSearchError.invalidHTML)
        #expect(response.results.isEmpty == false)
        #expect(second.asked == ["tofu"])
    }

    /// Including an address pointed somewhere that doesn't answer, which is
    /// how the fallback can be tried without waiting to be rate-limited.
    @Test("An address that doesn't answer falls through")
    func networkFailure() async throws {
        let offline = URLError(.cannotFindHost)
        let (response, second) = try await answered(after: offline)
        #expect(response.results.isEmpty == false)
        #expect(second.asked == ["tofu"])
    }

    /// A search that genuinely found nothing is an answer, not a failure.
    @Test("Finding nothing is not a reason to ask again")
    func emptyIsNotFailure() async throws {
        final class Empty: WebSearch, WebImageSearch, @unchecked Sendable {
            func search(web query: String) async throws -> WebSearchResponse {
                WebSearchResponse(query: query, results: [])
            }
            func search(images query: String) async throws -> WebSearchResponse {
                try await search(web: query)
            }
        }
        let second = Answering()
        let session = WebSearchSession(
            engine: Empty(),
            spacing: Self.brisk,
            storeName: "fallbackBreadth.\(UUID().uuidString)",
            fallback: { second }
        )

        let response = try await session.search(query: "a phrase that is nowhere")
        #expect(response.results.isEmpty)
        #expect(second.asked.isEmpty, "the other provider was never asked")
    }
}
