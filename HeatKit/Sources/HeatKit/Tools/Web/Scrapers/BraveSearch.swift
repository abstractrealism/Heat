import Foundation
import OSLog

private let logger = Logger(subsystem: "WebSearch", category: "HeatKit")

/// Brave's Web Search API: JSON, a key, and a published price.
///
/// The other provider here is a scrape of a search page, which is free and
/// answers to nobody — including us, when it decides a burst of searches was
/// too many. This one is asked rather than scraped, so a refusal says which
/// rule was broken and a quota is a number rather than a guess.
///
/// Only web search. Brave answers image, news and video queries at endpoints
/// of their own, and has a Local and an LLM Context API besides; none of
/// those is what a fallback needs, and the last of them returns passages of
/// page content rather than a list of results, which is a different feature
/// rather than a substitute for this one.
public struct BraveSearch: WebSearch, Sendable {

    private let host: String
    private let token: String

    public init(host: String, token: String) {
        self.host = host
        self.token = token
    }

    public init(_ service: SearchService) {
        self.init(host: service.host, token: service.token)
    }

    public func search(web query: String) async throws -> WebSearchResponse {
        guard !token.isEmpty else { throw BraveSearchError.noKey }
        guard var components = URLComponents(string: host) else {
            throw BraveSearchError.badHost(host)
        }
        components.queryItems = [
            .init(name: "q", value: query),
            // Ten, to match what the other provider's page carries, so an
            // answer doesn't get twice as much context from one provider as
            // from the other.
            .init(name: "count", value: "10"),
        ]
        guard let url = components.url else { throw BraveSearchError.badHost(host) }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            throw Self.failure(status: status, body: data)
        }
        return try decode(data, query: query)
    }

    /// What a refusal means, read from the body rather than the status.
    ///
    /// The status alone won't do it. A wrong key answers **422** with
    /// `SUBSCRIPTION_TOKEN_INVALID`, which is the status this once took for a
    /// malformed query — measured against the live API, having first been
    /// guessed at as 401 from the shape of every other service. Brave says
    /// which of the two it means in `error.code` and
    /// `error.meta.component`, so those are what's read.
    ///
    /// Its own sentence is passed along. "The provided subscription token is
    /// invalid" is better than anything this could infer, and a code nobody
    /// here has seen still arrives with an explanation attached.
    static func failure(status: Int, body: Data) -> BraveSearchError {
        let payload = try? JSONDecoder().decode(ErrorPayload.self, from: body)
        let code = payload?.error?.code?.uppercased() ?? ""
        let component = payload?.error?.meta?.component?.lowercased() ?? ""
        let detail = payload?.error?.detail ?? String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(400)
            .description

        // Quota before key, deliberately. A spent subscription may well
        // report a code with SUBSCRIPTION in it too, and being told the key
        // is wrong when the key is fine would send somebody to check the one
        // thing that isn't the problem.
        let spent = ["RATE", "QUOTA", "LIMIT", "EXCEEDED"]
        if status == 429 || spent.contains(where: code.contains) {
            return .rateLimited(detail)
        }
        if component == "authentication" || code.contains("TOKEN") {
            return .keyRefused(detail)
        }
        if status == 422 {
            return .badRequest(detail)
        }
        return .refused(status: status, detail: detail)
    }

    /// What a refusal looks like. Verbatim from the live API:
    ///
    ///     {"error":{"code":"SUBSCRIPTION_TOKEN_INVALID",
    ///               "detail":"The provided subscription token is invalid.",
    ///               "meta":{"component":"authentication"},"status":422},
    ///      "type":"ErrorResponse"}
    struct ErrorPayload: Decodable {
        let error: Detail?

        struct Detail: Decodable {
            let code: String?
            let detail: String?
            let status: Int?
            let meta: Meta?

            struct Meta: Decodable {
                let component: String?
            }
        }
    }

    func decode(_ data: Data, query: String) throws -> WebSearchResponse {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw BraveSearchError.unreadable("\(error)")
        }

        let results = (payload.web?.results ?? []).compactMap { result -> WebSearchResult? in
            guard let url = URL(string: result.url) else { return nil }
            return WebSearchResult(
                url: url,
                title: result.title,
                // Brave marks the words it matched with <strong>. Stripped,
                // because the description goes into a tool result as text and
                // markup there is noise a model has to read past.
                description: result.description.map(Self.withoutMarkup)
            )
        }
        return WebSearchResponse(query: query, results: results)
    }

    /// Tags out, entities in. Only the handful Brave actually emits — this is
    /// tidying a snippet, not parsing HTML, and a snippet that arrives with
    /// something unexpected in it is better shown as written than mangled by
    /// a guess.
    static func withoutMarkup(_ text: String) -> String {
        var out = ""
        var depth = 0
        for character in text {
            switch character {
            case "<": depth += 1
            case ">": depth = max(0, depth - 1)
            default: if depth == 0 { out.append(character) }
            }
        }
        return out
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            // Last, or it would undo the escaping in the ones above.
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only what's read. The response also carries `query`, `mixed`, `news`,
    /// `videos`, `infobox` and more; everything optional, so a response that
    /// omits a section — which it does, depending on the query — decodes
    /// rather than failing.
    struct Payload: Decodable {
        let web: Web?

        struct Web: Decodable {
            let results: [Result]?
        }

        struct Result: Decodable {
            let title: String?
            let url: String
            let description: String?
        }
    }
}

/// Said in words, because a search failure goes back to the model as the
/// result of its tool call.
enum BraveSearchError: LocalizedError {
    case noKey
    case badHost(String)
    case keyRefused(String?)
    case badRequest(String?)
    case rateLimited(String?)
    case refused(status: Int, detail: String?)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            "Brave Search has no API key set, so it can't be asked. Add one in Settings ▸ Tools."
        case .badHost(let host):
            "Brave Search's address isn't a usable URL: \(host)"
        case .keyRefused(let detail):
            "Brave Search refused the API key\(Self.because(detail)) Check it in Settings ▸ Tools."
        case .badRequest(let detail):
            "Brave Search wouldn't accept the search\(Self.because(detail))"
        case .rateLimited(let detail):
            "Brave Search is rate-limiting or out of credit\(Self.because(detail)) Work with what you already have and tell the user search is temporarily unavailable."
        case .refused(let status, let detail):
            "Brave Search answered \(status)\(Self.because(detail))"
        case .unreadable(let detail):
            "Brave Search's answer couldn't be read: \(detail)"
        }
    }

    private static func because(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "." }
        return ": \(detail)"
    }
}
