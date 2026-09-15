import Foundation
import QuartzCore
import Fuzi

public actor WebSearchSession {
    public static let shared = WebSearchSession()

    private init() {}

    // MARK: - Pacing
    //
    // DuckDuckGo's HTML endpoint is rate-limited per address, and it says so
    // with a bot challenge rather than a status. Measured, from this machine:
    // four requests in thirteen seconds tripped it, and the block that
    // followed was still in force seventy-six minutes later — twenty of them
    // with no request at all — where the first block of the day had cleared
    // inside an hour. So the block appears to lengthen with repeated trips,
    // and quite possibly with every request made during it.
    //
    // Two consequences. Requests are spaced, one at a time, because a model
    // working through a question asks for two at once, round after round,
    // and that is precisely the burst that trips it. And after a challenge
    // nothing is asked for a long while — long enough that the retry itself
    // isn't what keeps the door shut — with the wait doubling each time a
    // retry is challenged again, and the model told the truth meanwhile.

    /// The gap between two requests, drawn afresh each time. Four in
    /// thirteen seconds was refused; this range is a guess at the other side
    /// of that line, and varied so the pattern isn't a metronome.
    private static let spacing: ClosedRange<TimeInterval> = 4...10

    /// When the next request may go, or nil if now. Reserved *before* the
    /// wait rather than recorded after it, so two callers arriving together
    /// take successive slots instead of sleeping the same interval and firing
    /// as one.
    private var nextSlot: Date?

    private static let firstHold: TimeInterval = 30 * 60
    private static let longestHold: TimeInterval = 4 * 60 * 60

    private var challengedAt: Date?
    private var hold: TimeInterval = WebSearchSession.firstHold

    public func search(query: String) async throws -> WebSearchResponse {
        if let challengedAt {
            let remaining = hold - Date.now.timeIntervalSince(challengedAt)
            if remaining > 0 {
                throw WebSearchError.holdingOff(remaining)
            }
        }

        let slot = max(Date.now, nextSlot ?? .distantPast)
        nextSlot = slot.addingTimeInterval(.random(in: Self.spacing))
        let wait = slot.timeIntervalSinceNow
        if wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        }

        let engine = DuckSearch()
        do {
            let response = try await engine.search(web: query)
            challengedAt = nil
            hold = Self.firstHold
            return response
        } catch WebSearchError.challenged {
            // Challenged again on the first try after a hold: the hold was
            // too short, so the next is longer.
            if challengedAt != nil {
                hold = min(hold * 2, Self.longestHold)
            }
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
