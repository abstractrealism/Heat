import Foundation
import OSLog
import QuartzCore
import Fuzi

private let logger = Logger(subsystem: "WebSearch", category: "HeatKit")

public actor WebSearchSession {
    public static let shared = WebSearchSession()

    /// What actually does the searching. A parameter so the pacing and the
    /// holding can be driven without going near the network — they are the
    /// parts with the interesting behaviour, and the parts that were wrong.
    private let engine: any WebSearch & WebImageSearch & Sendable

    /// The gap this session leaves between requests. A parameter so a test
    /// can exercise the queueing without sleeping through it — the shipped
    /// figure is `Self.spacing`, and one test holds that to what's intended.
    private let spacing: ClosedRange<TimeInterval>

    init(
        engine: any WebSearch & WebImageSearch & Sendable = DuckSearch(),
        spacing: ClosedRange<TimeInterval> = WebSearchSession.spacing,
        // Named rather than passed: `UserDefaults` predates Sendable, and
        // a name crosses an actor boundary without argument.
        storeName: String? = nil
    ) {
        self.engine = engine
        self.spacing = spacing
        self.store = storeName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

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

    /// The gap between two requests, drawn afresh each time, varied so the
    /// pattern isn't a metronome.
    ///
    /// Widened from 4–10 on 24 Sept 2026, and the reason is worth recording
    /// because it wasn't the pacing that changed — it was the model. Every
    /// run that went unchallenged was answered by a local 27B that took
    /// minutes to think between rounds, so searches were spread out by the
    /// model and this gap almost never bound: 25 searches over 15 minutes,
    /// then 40 over 45. A hosted model answers a round in a second or two,
    /// which leaves this the only thing pacing anything, and a searching
    /// turn then runs flat out at whatever the minimum allows. Measured that
    /// day against Claude: twelve requests in seventy-two seconds, about ten
    /// a minute, and the twelfth was refused.
    ///
    /// So the figure is aimed at sustained volume rather than at bursts.
    /// 7–15 averages eleven seconds, which is a little over five requests a
    /// minute — between the 1.7 a minute that was never challenged and the
    /// ten that was. Wider would be safer and was rejected deliberately: a
    /// round of three searches at 10–20 can take forty seconds before the
    /// model says a word, and a turn that feels broken is its own kind of
    /// failure.
    ///
    /// All of which is a guess at an undocumented limit, from four data
    /// points. The published advice — under thirty a minute — matches none
    /// of them, and a keyed provider remains the only real answer.
    static let spacing: ClosedRange<TimeInterval> = 7...15

    /// When the next request may go, or nil if now. Reserved *before* the
    /// wait rather than recorded after it, so two callers arriving together
    /// take successive slots instead of sleeping the same interval and firing
    /// as one.
    private var nextSlot: Date?

    private static let firstHold: TimeInterval = 30 * 60
    private static let longestHold: TimeInterval = 4 * 60 * 60

    /// Remembered across launches, because a block is.
    ///
    /// These used to live only in memory, so quitting Heat — or rebuilding
    /// it, which during a day's work is the same thing many times over —
    /// forgot that we were in the middle of a block and sent the next
    /// question's searches straight into it. Measured on 24 Sept: a block
    /// outlasted eighty-two minutes of complete silence, so it is not a
    /// timer that a restart can be assumed to have outlived.
    ///
    /// In defaults rather than in the config file: this is an operational
    /// fact about the last few minutes, not a preference anyone chose, and
    /// nothing should be restored from a backup or carried to another
    /// machine.
    private var challengedAt: Date? {
        get {
            let stored = store.double(forKey: Self.challengedAtKey)
            return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        }
        set { store.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.challengedAtKey) }
    }

    private var hold: TimeInterval {
        get {
            let stored = store.double(forKey: Self.holdKey)
            return stored > 0 ? stored : Self.firstHold
        }
        set { store.set(newValue, forKey: Self.holdKey) }
    }

    /// `nonisolated(unsafe)` because `UserDefaults` is documented as
    /// thread-safe and predates Sendable; only this actor touches these keys.
    private nonisolated(unsafe) let store: UserDefaults
    private static let challengedAtKey = "webSearchChallengedAt"
    private static let holdKey = "webSearchHold"

    public func search(query: String) async throws -> WebSearchResponse {
        let wait = try await pace(query: query)

        // Said at the moment the request actually goes, with how long it
        // queued: the tool-call log lines print when calls are dispatched,
        // all at once, and read as though the pacing weren't happening.
        logger.notice("→ search after \(Self.seconds(wait), privacy: .public)s in the queue: \(query, privacy: .public)")
        let sentAt = Date.now

        do {
            let response = try await engine.search(web: query)
            challengedAt = nil
            hold = Self.firstHold
            logger.notice("← search answered in \(Self.seconds(Date.now.timeIntervalSince(sentAt)), privacy: .public)s with \(response.results.count, privacy: .public) results: \(query, privacy: .public)")
            for (index, result) in response.results.enumerated() {
                logger.info("   \(index + 1, privacy: .public). \(result.title ?? "", privacy: .public) — \(result.url.absoluteString, privacy: .public)")
            }
            return response
        } catch WebSearchError.challenged {
            // Challenged again on the first try after a hold: the hold was
            // too short, so the next is longer.
            if challengedAt != nil {
                hold = min(hold * 2, Self.longestHold)
            }
            challengedAt = .now
            logger.notice("← search refused after \(Self.seconds(Date.now.timeIntervalSince(sentAt)), privacy: .public)s; holding off \(Int(self.hold / 60), privacy: .public) min: \(query, privacy: .public)")
            throw WebSearchError.challenged
        } catch {
            logger.notice("← search failed after \(Self.seconds(Date.now.timeIntervalSince(sentAt)), privacy: .public)s: \(error, privacy: .public): \(query, privacy: .public)")
            throw error
        }
    }

    /// Waits for this request's turn, and refuses it outright if a hold is
    /// in force — before the wait and again after it.
    @discardableResult
    private func pace(query: String) async throws -> TimeInterval {
        try holdRemaining(for: query)

        let slot = max(Date.now, nextSlot ?? .distantPast)
        nextSlot = slot.addingTimeInterval(.random(in: spacing))
        let wait = slot.timeIntervalSinceNow
        if wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        }

        // Again, because the world moved while this one waited its turn.
        //
        // A model asks for two or three searches at once, so they arrive
        // together, all pass the check above, and all reserve a slot. If the
        // first is then challenged, the ones asleep behind it knew nothing of
        // it and went anyway — measured: a challenge at 11:43:39 and another
        // request 6.7 seconds later, straight into a block we had just been
        // told about.
        //
        // Which cost twice. A request made during a block is the thing most
        // likely to lengthen it, and it also read as a *re-challenge* — the
        // hold doubled from thirty minutes to sixty on the strength of a
        // request that should never have left. With this check, a challenge
        // reaching the doubling below has by definition outlived a hold,
        // which is what that doubling is supposed to mean.
        try holdRemaining(for: query)
        return max(0, wait)
    }

    /// Throws if a challenge hold is still in force.
    private func holdRemaining(for query: String) throws {
        guard let challengedAt else { return }
        let remaining = hold - Date.now.timeIntervalSince(challengedAt)
        guard remaining > 0 else { return }
        logger.notice("search held off, \(Int(remaining), privacy: .public)s of a challenge hold left: \(query, privacy: .public)")
        throw WebSearchError.holdingOff(remaining)
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f", interval)
    }

    public func searchImages(query: String) async throws -> WebSearchResponse {
        // Through the same gate as a web search, because it is the same
        // address and the same bucket: `html`, `lite` and the JSON endpoint
        // were measured being challenged together. It used to go straight
        // out — no hold, no spacing — and it costs *two* requests, the token
        // page and then the JSON, so a single image search during a block
        // was two more reasons for that block to last longer.
        try await pace(query: query)
        // Was Google, which stopped working. Its image scrape asked for the
        // legacy no-JavaScript rendering (`gbv=1`) and read the results out of
        // the markup; that mode no longer carries any. The request still
        // succeeds — a 2KB page, titled as a search for the query, containing
        // none of the links the parser looks for — so the failure arrived as an
        // empty list rather than an error, and the assistant reported in good
        // faith that it had found no images.
        return try await engine.search(images: query)
    }
}
