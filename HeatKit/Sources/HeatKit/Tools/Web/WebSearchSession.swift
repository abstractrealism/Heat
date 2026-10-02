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
    /// An engine to use instead of the configured one. Only tests pass it;
    /// everything else gets whatever Settings says, read per search so a
    /// changed address works on the next search rather than the next launch.
    private let engineOverride: (any WebSearch & WebImageSearch & Sendable)?

    /// The gap this session leaves between requests. A parameter so a test
    /// can exercise the queueing without sleeping through it — the shipped
    /// figure is `Self.spacing`, and one test holds that to what's intended.
    private let spacing: ClosedRange<TimeInterval>

    /// Where to go when the first provider won't answer.
    ///
    /// Looked up when it's needed rather than held, because a key typed into
    /// Settings should work on the next search and not the next launch. Nil
    /// where nothing is configured, which is the ordinary case.
    private let fallback: @Sendable () async -> (any WebSearch & Sendable)?

    init(
        engine: (any WebSearch & WebImageSearch & Sendable)? = nil,
        spacing: ClosedRange<TimeInterval> = WebSearchSession.spacing,
        // Named rather than passed: `UserDefaults` predates Sendable, and
        // a name crosses an actor boundary without argument.
        storeName: String? = nil,
        fallback: @escaping @Sendable () async -> (any WebSearch & Sendable)? = WebSearchSession.configuredFallback
    ) {
        self.engineOverride = engine
        self.spacing = spacing
        self.store = storeName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.fallback = fallback
    }

    /// The provider asked first, at whatever address Settings gives it.
    private func primaryEngine() async -> any WebSearch & WebImageSearch & Sendable {
        if let engineOverride { return engineOverride }
        let configured = await MainActor.run { API.shared.config.searchProvider(.duckDuckGo) }
        return DuckSearch(host: configured.host)
    }

    /// Whichever keyed provider is set up, or nothing.
    static let configuredFallback: @Sendable () async -> (any WebSearch & Sendable)? = {
        // The config lives on the main actor; this doesn't, and only needs
        // to read two strings out of it.
        let brave = await MainActor.run { API.shared.config.searchProvider(.brave) }
        guard brave.isReady else { return nil }
        return BraveSearch(brave)
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
    // nothing is asked for a while, the wait stepping up each time a retry is
    // challenged again, and the model told the truth meanwhile.
    //
    // How long that wait runs is argued at `holds`, and later measurement
    // complicated the picture above: a challenge does not always begin a long
    // block, and on 28 Sept two of them cleared within minutes.

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

    /// The same, for the fallback provider, which has limits of its own.
    private var nextFallbackSlot: Date?

    /// How long to wait after a challenge, and how that lengthens.
    ///
    /// Was thirty minutes, from the 24 Sept measurement where a block
    /// outlasted eighty-two minutes of silence. On 28 Sept the opposite was
    /// measured, twice in twelve minutes: a challenge at 13:09 was followed
    /// at 13:14 by seventeen requests descending to half-second gaps, every
    /// one answered, and another challenge at 13:21 likewise left the address
    /// working. So there are two regimes — a light challenge that clears in
    /// minutes, and an escalated block that outlasts hours — and a fixed
    /// thirty minutes treats every challenge as the second kind.
    ///
    /// So a short first rung assumes the first kind and lets the ladder
    /// discover the second, which is the right way round now that a hold
    /// costs money. Before Brave, an over-long hold merely meant answering
    /// without the web; now every search during one is billed at $5 per
    /// thousand. The errors are no longer symmetric:
    ///
    /// - Too short: one DuckDuckGo request is refused, the next rung
    ///   corrects it, and the model never sees either — Brave answers.
    /// - Too long: every search for up to four hours is bought from Brave
    ///   when DuckDuckGo would have answered for nothing.
    ///
    /// A ladder rather than a doubling, because each rung costs a request
    /// made into a live block, and those are the requests that lengthen it.
    /// Doubling from five reached an hour only after five refusals; this
    /// reaches it after one.
    ///
    /// The rungs come from what the day's first challenge does against what
    /// a day of them does. Every quick clear measured has been the first
    /// challenge of a session — 13:09 to 13:14 on 28 Sept, five minutes.
    /// Every long one has followed several: ten minutes failed five times
    /// running that evening, eleven and twelve failed twice on 29 Sept,
    /// twenty-one failed for curl, and on 24 Sept eighty-two minutes of
    /// silence was not enough after days of testing. So the first rung is
    /// aimed at somebody who trips it once and the rest at somebody who has
    /// tripped it repeatedly, with nothing in between: fifteen minutes is
    /// the outside of the quick case, and if it hasn't cleared by then the
    /// evidence says the answer is hours, not half an hour.
    ///
    /// Fifteen rather than five because the error is cheap in one direction
    /// only when Brave is configured — then a hold that is too long is
    /// bought at $5 per thousand, and one that is too short costs a single
    /// refused request the ladder corrects. Without Brave a hold that is too
    /// short costs a re-challenge, which lengthens the block itself. Fifteen
    /// sits on the safer side of that for the keyless case while still
    /// assuming the common one.
    private static let holds: [TimeInterval] = [
        15 * 60,
        60 * 60,
        2 * 60 * 60,
        4 * 60 * 60,
    ]

    private static var firstHold: TimeInterval { holds[0] }

    /// The next rung up from whatever is in force.
    ///
    /// Compares rather than indexes so that a figure stored by an earlier
    /// build — this has been thirty minutes, and five — lands on the next
    /// rung above it instead of being unrecognised.
    private static func lengthened(_ current: TimeInterval) -> TimeInterval {
        holds.first { $0 > current } ?? holds[holds.count - 1]
    }

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
        let wait: TimeInterval
        do {
            wait = try await pace(query: query)
        } catch let refusal as WebSearchError {
            // Held off, which is when the other provider is worth the most:
            // a hold runs for half an hour and up, and nothing the model does
            // shortens it. Asking elsewhere turns an hour of no search into a
            // search, and the model never learns there was a problem.
            return try await asking(elsewhere: query, because: refusal)
        }

        // Said at the moment the request actually goes, with how long it
        // queued: the tool-call log lines print when calls are dispatched,
        // all at once, and read as though the pacing weren't happening.
        logger.notice("→ search after \(Self.seconds(wait), privacy: .public)s in the queue: \(query, privacy: .public)")
        let sentAt = Date.now

        do {
            let response = try await primaryEngine().search(web: query)
            challengedAt = nil
            hold = Self.firstHold
            report(response, query: query, sentAt: sentAt)
            return response
        } catch WebSearchError.challenged {
            // Challenged again on the first try after a hold: the hold was
            // too short, so the next is longer.
            if challengedAt != nil {
                hold = Self.lengthened(hold)
            }
            challengedAt = .now
            logger.notice("← search refused after \(Self.seconds(Date.now.timeIntervalSince(sentAt)), privacy: .public)s; holding off \(Int(self.hold / 60), privacy: .public) min: \(query, privacy: .public)")
            return try await asking(elsewhere: query, because: WebSearchError.challenged)
        } catch {
            // Not only a refusal. A scrape has more ways to stop working
            // than an API does — the page can be restructured out from under
            // the parser, which is silent and total — and every one of them
            // is a reason to ask the other provider rather than to give the
            // model nothing. An outage of our own connection falls through
            // too and fails twice, which costs one request and is worth it
            // for not having to tell those cases apart.
            // One line. Interpolating the error itself printed the whole of
            // an `NSError`'s userInfo — about fifteen lines of dictionary per
            // failure — which buried the turn it happened in. The sentence is
            // the part worth reading.
            //
            // Said as "failed" rather than "refused", deliberately: this
            // branch is everything that *isn't* a bot challenge, and a
            // parser that has stopped matching or a connection that never
            // opened shouldn't be read as a rate limit. The refusal and the
            // hold have their own lines, and they say so.
            logger.notice(
                "← search failed (not refused) after \(Self.seconds(Date.now.timeIntervalSince(sentAt)), privacy: .public)s: \(error.localizedDescription, privacy: .public): \(query, privacy: .public)"
            )
            logger.debug("← the failure in full: \(error, privacy: .public)")
            return try await asking(elsewhere: query, because: error)
        }
    }

    /// The other provider, when the first one won't answer.
    ///
    /// A search is a tool result, and a tool result that says "the search
    /// engine is cross with us" is a turn the model has to abandon. If
    /// another provider is configured it simply answers instead, and nothing
    /// upstream is told which one did: the model asked for results and gets
    /// results, which is the whole of what it needs to know.
    ///
    /// Where nothing is configured, the original refusal is what comes back —
    /// the same error, worded the same way, as before there was a fallback.
    /// And if the fallback fails too, the original still wins: the first
    /// provider's refusal is the more useful of the two, because it says the
    /// thing that will still be true in ten minutes.
    private func asking(elsewhere query: String, because refusal: any Error) async throws -> WebSearchResponse {
        guard let other = await fallback() else { throw refusal }

        // A queue of its own. The gap above is aimed at what DuckDuckGo
        // tolerates, which has nothing to do with this provider, and the two
        // sharing a queue would mean a wait for one delaying the other. A
        // second between requests is what Brave's own plans describe.
        let slot = max(Date.now, nextFallbackSlot ?? .distantPast)
        nextFallbackSlot = slot.addingTimeInterval(1)
        let queued = slot.timeIntervalSinceNow
        if queued > 0 {
            try? await Task.sleep(for: .seconds(queued))
        }

        let sentAt = Date.now
        logger.notice("→ falling back for: \(query, privacy: .public)")
        do {
            let response = try await other.search(web: query)
            report(response, query: query, sentAt: sentAt, fallback: true)
            return response
        } catch {
            logger.notice("← the fallback failed too after \(Self.seconds(Date.now.timeIntervalSince(sentAt)), privacy: .public)s: \(error, privacy: .public)")
            throw refusal
        }
    }

    private func report(
        _ response: WebSearchResponse,
        query: String,
        sentAt: Date,
        fallback: Bool = false
    ) {
        let via = fallback ? " (fallback)" : ""
        logger.notice("← search answered\(via, privacy: .public) in \(Self.seconds(Date.now.timeIntervalSince(sentAt)), privacy: .public)s with \(response.results.count, privacy: .public) results: \(query, privacy: .public)")
        for (index, result) in response.results.enumerated() {
            logger.info("   \(index + 1, privacy: .public). \(result.title ?? "", privacy: .public) — \(result.url.absoluteString, privacy: .public)")
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
        return try await primaryEngine().search(images: query)
    }
}
