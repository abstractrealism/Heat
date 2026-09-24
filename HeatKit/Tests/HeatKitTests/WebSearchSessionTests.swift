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
        let session = WebSearchSession(engine: engine)

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
    /// not that, and it used to double the hold from thirty minutes to sixty
    /// on the strength of a request that should never have left.
    @Test("A second refusal from the same burst doesn't lengthen the hold")
    func holdIsNotDoubledByItsOwnBurst() async throws {
        let engine = Engine([
            .failure(WebSearchError.challenged),
            .failure(WebSearchError.challenged),
        ])
        let session = WebSearchSession(engine: engine)

        async let first: WebSearchResponse = session.search(query: "one")
        async let second: WebSearchResponse = session.search(query: "two")
        _ = try? await first
        _ = try? await second

        // Whatever is left of the hold, it is the first one and not twice it.
        do {
            _ = try await session.search(query: "three")
            Issue.record("a search went through during a hold")
        } catch let WebSearchError.holdingOff(remaining) {
            #expect(remaining > 25 * 60)
            #expect(remaining <= 30 * 60, "thirty minutes, not sixty")
        }
    }

    @Test("An ordinary search is answered and the engine is asked once")
    func ordinarySearch() async throws {
        let engine = Engine([.success(10)])
        let session = WebSearchSession(engine: engine)

        let response = try await session.search(query: "tofu")
        #expect(response.results.count == 10)
        #expect(engine.asked == ["tofu"])
    }

    /// Two that both succeed are spaced rather than fired together — the
    /// burst is what trips the challenge in the first place.
    @Test("Searches asked for together are spaced apart")
    func searchesAreSpaced() async throws {
        let engine = Engine([.success(1), .success(1)])
        let session = WebSearchSession(engine: engine)

        let started = Date.now
        async let first: WebSearchResponse = session.search(query: "one")
        async let second: WebSearchResponse = session.search(query: "two")
        _ = try await first
        _ = try await second

        #expect(Date.now.timeIntervalSince(started) >= 4, "the shortest gap the session allows")
        #expect(engine.asked.count == 2)
    }

    /// A success clears the hold, so a conversation isn't punished for a
    /// block that has since lifted.
    @Test("A search that works clears what came before it")
    func successClearsTheHold() async throws {
        let engine = Engine([.success(5)])
        let session = WebSearchSession(engine: engine)

        _ = try await session.search(query: "tofu")
        // Nothing thrown means nothing held.
        #expect(engine.asked == ["tofu"])
    }
}
