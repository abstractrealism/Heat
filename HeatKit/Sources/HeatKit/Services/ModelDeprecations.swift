import Foundation
import OSLog
import GenKit

private let logger = Logger(subsystem: "ModelDeprecations", category: "HeatKit")

/// What a service has published as withdrawn.
///
/// A model endpoint keeps offering models it will no longer serve: OpenAI went
/// on listing `gpt-4o-search-preview` long after requests for it started
/// failing with "has been deprecated". Nothing in the API says which of 130
/// models are dead, so the only published answer is the documentation, and
/// reading it is the difference between finding out here and finding out one
/// failed message at a time.
///
/// Read from the Markdown version of the page rather than the HTML, which is
/// both easier to parse and less likely to be restructured by a redesign.
///
/// **Only exact matches.** The page names dated snapshots
/// (`gpt-4o-search-preview-2025-03-11`) as well as bare aliases
/// (`gpt-5.1-chat-latest`), and matching those exactly is safe. Deriving one
/// from the other is not: strip the date off `gpt-4o-2024-05-13` and you get
/// `gpt-4o`, which is alive and current. An alias points at whichever
/// snapshot the service has promoted, so a dead snapshot says nothing about
/// the alias — and only the service knows. Anything that slips past this is
/// caught the other way, by `Config.markModelUnavailable` when a request for
/// it is refused.
public struct ModelDeprecations {

    public enum Error: Swift.Error, CustomStringConvertible {
        case unreadable
        case unexpectedResponse(Int)

        public var description: String {
            switch self {
            case .unreadable:
                "The deprecations page wasn't readable as text."
            case .unexpectedResponse(let status):
                "The deprecations page answered \(status)."
            }
        }
    }

    /// Models known to be withdrawn that the page doesn't name outright.
    ///
    /// The page lists dated snapshots — `gpt-4o-search-preview-2025-03-11`
    /// — while the model list offers the bare alias, and exact matching is
    /// the only sound kind (see above). So an alias whose every snapshot is
    /// gone slips through, is offered, is marked suggested on a fresh
    /// install, and fails the first message sent to it with "has been
    /// deprecated". That refusal hides it, but only on the install that
    /// sent it. These are the ones already met that way; a list, not a
    /// rule, and it will fall behind — which the refusal still covers.
    public static func alreadyKnown(for kind: Service.Kind) -> Set<String> {
        switch kind {
        case .openAI:
            ["gpt-4o-search-preview", "gpt-4o-mini-search-preview"]
        default:
            []
        }
    }

    /// Where a service publishes this, where it publishes it at all.
    public static func documentURL(for kind: Service.Kind) -> URL? {
        switch kind {
        case .openAI:
            URL(string: "https://developers.openai.com/api/docs/deprecations.md")
        default:
            nil
        }
    }

    /// The models a service says it has already stopped serving.
    ///
    /// Empty for a service that publishes nothing, which is every service but
    /// OpenAI so far.
    public static func withdrawnModelIDs(
        for kind: Service.Kind,
        session: URLSession = .shared,
        asOf now: Date = .now
    ) async throws -> Set<String> {
        guard let url = documentURL(for: kind) else { return [] }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Error.unexpectedResponse(http.statusCode)
        }
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw Error.unreadable
        }

        let withdrawn = withdrawnModelIDs(in: markdown, asOf: now)

        // A restructured page fails quietly: no error, just an empty answer,
        // which is indistinguishable from a service having withdrawn nothing.
        // Nobody using the app can act on that, so it goes to the log rather
        // than the screen — but it has to go somewhere, or the first sign of
        // it is a model that should have been hidden and wasn't.
        if let concern = concern(about: withdrawn, in: markdown) {
            logger.warning("\(url.absoluteString, privacy: .public) may have changed: \(concern, privacy: .public)")
        } else {
            logger.info("read \(withdrawn.count, privacy: .public) withdrawn models from \(url.host() ?? "", privacy: .public)")
        }

        return withdrawn
    }

    /// What looks wrong about a parse, if anything.
    ///
    /// Separate and pure so it can be checked, and so the judgement lives
    /// next to the parsing it is judging.
    ///
    /// The thresholds are deliberately loose. The count drifts as shutdown
    /// dates pass, and being approximately right is enough for something
    /// whose only job is to say "go and look".
    public static func concern(about withdrawn: Set<String>, in markdown: String) -> String? {
        let rows = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }

        // Nothing to parse at all: moved, rewritten, or answered with
        // something that isn't the page.
        if rows == 0 {
            return markdown.count < 500
                ? "no tables, and only \(markdown.count) characters — this doesn't look like the page"
                : "no table rows found in \(markdown.count) characters"
        }

        // Tables, but nothing recognised in them: the columns or the way
        // model names are written have most likely changed.
        if withdrawn.isEmpty {
            return "\(rows) table rows but no models recognised in them"
        }

        // Something recognised, but far less than this page has ever held —
        // it named around 70 when this was written. A floor rather than a
        // range, since the figure only grows as models are retired.
        if withdrawn.count < 10 {
            let models = withdrawn.count == 1 ? "1 model" : "\(withdrawn.count) models"
            return "only \(models) recognised across \(rows) table rows, which is fewer than expected"
        }

        return nil
    }

    /// The parse, separated so it can be checked against a saved page.
    ///
    /// Driven by the shutdown dates in the tables rather than by which heading
    /// a table sits under. The same announcement can appear under both
    /// "Upcoming" and "Past" with different rows, and a date answers the
    /// question directly — as well as correcting itself as time passes.
    public static func withdrawnModelIDs(in markdown: String, asOf now: Date = .now) -> Set<String> {
        var shutDown: Set<String> = []
        var scheduled: Set<String> = []

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { continue }

            // A cell can contain an escaped pipe separating two names for the
            // same thing — `computer-use-preview-2025-03-11 \| computer-use-preview`
            // — which must not be read as a column break.
            let guarded = line.replacingOccurrences(of: "\\|", with: "\u{1}")
            let cells = guarded
                .split(separator: "|", omittingEmptySubsequences: false)
                .map {
                    $0.replacingOccurrences(of: "\u{1}", with: "|")
                        .trimmingCharacters(in: .whitespaces)
                }

            // A leading and trailing pipe give empty end cells, so a row of
            // three columns arrives as five. Header and rule rows fail the
            // date below rather than needing to be recognised.
            guard cells.count >= 4, let shutdown = date(from: cells[1]) else { continue }

            let names = quotedNames(in: cells[2])
            if shutdown <= now {
                shutDown.formUnion(names)
            } else {
                scheduled.formUnion(names)
            }
        }

        // A model named with a shutdown still to come is running, whatever an
        // older table says — the later announcement is the operative one.
        // `babbage-002` and `davinci-002` are each listed both ways.
        //
        // Endpoint paths share these tables and are not models.
        return shutDown
            .subtracting(scheduled)
            .filter { !$0.contains("/") && !$0.isEmpty }
    }

    /// The backticked names in a cell.
    ///
    /// Split without dropping the empty pieces, or a cell holding exactly one
    /// name puts it at an even index and the alternation below skips it — a
    /// mistake that reads as the page having listed nothing.
    private static func quotedNames(in cell: String) -> [String] {
        cell.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, part in
                index.isMultiple(of: 2) ? nil : String(part).trimmingCharacters(in: .whitespaces)
            }
    }

    /// The three shapes the tables use, tried in turn. An unparseable date
    /// means the row is skipped, which errs towards leaving a model alone.
    private static let dateFormats = ["yyyy-MM-dd", "MMM d, yyyy", "MMMM d, yyyy"]

    private static func date(from text: String) -> Date? {
        // "Sept" is four letters and matches neither abbreviated nor full.
        let cleaned = text.replacingOccurrences(of: "Sept ", with: "Sep ")
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                return date
            }
        }
        return nil
    }
}
