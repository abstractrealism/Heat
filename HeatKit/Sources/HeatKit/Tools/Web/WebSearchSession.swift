import Foundation
import QuartzCore
import Fuzi

public actor WebSearchSession {
    public static let shared = WebSearchSession()

    private init() {}

    /// When DuckDuckGo last answered a search with a bot challenge.
    ///
    /// A challenge is served to an address that has asked too often, and
    /// asking again straight away is what keeps it coming — a model working
    /// through a question searches twice a round, round after round, and one
    /// such turn was measured at twenty searches in ninety seconds. So after
    /// a challenge nothing is asked for a while, and the model is told so
    /// rather than sent another puzzle. The interval is a guess: long enough
    /// to break the burst, short enough not to lose the tool for the session.
    private var challengedAt: Date?
    private static let holdAfterChallenge: TimeInterval = 60

    public func search(query: String) async throws -> WebSearchResponse {
        if let challengedAt {
            let remaining = Self.holdAfterChallenge - Date.now.timeIntervalSince(challengedAt)
            if remaining > 0 {
                throw WebSearchError.holdingOff(remaining)
            }
            self.challengedAt = nil
        }

        let engine = DuckSearch()
        do {
            return try await engine.search(web: query)
        } catch WebSearchError.challenged {
            challengedAt = .now
            throw WebSearchError.challenged
        }
    }

    public func searchImages(query: String) async throws -> WebSearchResponse {
        // Was Google, which stopped working. Its image scrape asked for the
        // legacy no-JavaScript rendering (`gbv=1`) and read the results out of
        // the markup; that mode no longer carries any. The request still
        // succeeds — a 2KB page, titled as a search for the query, containing
        // none of the links the parser looks for — so the failure arrived as an
        // empty list rather than an error, and the assistant reported in good
        // faith that it had found no images.
        let engine = DuckSearch()
        return try await engine.search(images: query)
    }
}
