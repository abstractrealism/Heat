import Foundation
import OSLog
import Fuzi

private let logger = Logger(subsystem: "DuckSearch", category: "HeatKit")

public struct DuckSearch: WebSearch, WebImageSearch {

    let host = "https://html.duckduckgo.com/html"

    /// Images don't come from the no-JavaScript endpoint above — it ignores the
    /// image parameters and answers with ordinary text results. They come from
    /// the endpoint the image tab itself calls, which answers in JSON.
    let imageSearchHost = "https://duckduckgo.com"

    public func search(web query: String) async throws -> WebSearchResponse {
        let userAgent = WebSearchUserAgent.mobile

        var urlComponents = URLComponents(string: host)!
        urlComponents.queryItems = [.init(name: "q", value: query)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpShouldHandleCookies = false
        request.setValue(userAgent.rawValue, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let baseURL = response.url ?? urlComponents.url!
        let resp = try extractResults(data, baseURL: baseURL, query: query)
        return resp
    }

    /// Image results, in two steps.
    ///
    /// The endpoint won't answer without a `vqd` token, which is only handed
    /// out on the search page — so the token is fetched first and spent
    /// immediately. Two round trips instead of one, in exchange for JSON:
    /// results arrive as a described shape rather than as markup to be picked
    /// apart, so a change on their end fails loudly here instead of quietly
    /// matching nothing.
    public func search(images query: String) async throws -> WebSearchResponse {
        let token = try await imageSearchToken(for: query)

        var components = URLComponents(string: "\(imageSearchHost)/i.js")!
        components.queryItems = [
            .init(name: "l", value: "us-en"),
            .init(name: "o", value: "json"),
            .init(name: "q", value: query),
            .init(name: "vqd", value: token),
            .init(name: "f", value: ",,,"),
            .init(name: "p", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpShouldHandleCookies = false
        request.setValue(WebSearchUserAgent.desktop.rawValue, forHTTPHeaderField: "User-Agent")
        // Refused without it: the endpoint is meant to be called from the
        // search page, and says so by ignoring anything that didn't come from
        // there.
        request.setValue("\(imageSearchHost)/", forHTTPHeaderField: "Referer")

        let (data, _) = try await URLSession.shared.data(for: request)
        let payload = try JSONDecoder().decode(ImageSearchPayload.self, from: data)

        let results = payload.results.compactMap { result -> WebSearchResult? in
            guard let image = URL(string: result.image), let source = URL(string: result.url) else {
                return nil
            }
            return WebSearchResult(url: source, title: result.title, image: image)
        }

        if results.isEmpty {
            logger.warning("Image search returned nothing for a query that reached the endpoint")
        }
        return WebSearchResponse(query: query, results: results)
    }
}

extension DuckSearch {

    /// The one-time token the image endpoint requires, lifted from the search
    /// page that would normally be holding it.
    private func imageSearchToken(for query: String) async throws -> String {
        var components = URLComponents(string: "\(imageSearchHost)/")!
        components.queryItems = [
            .init(name: "q", value: query),
            .init(name: "iax", value: "images"),
            .init(name: "ia", value: "images"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpShouldHandleCookies = false
        request.setValue(WebSearchUserAgent.desktop.rawValue, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.invalidHTML
        }

        // Written as `vqd="4-123…"` or `vqd=4-123…&`, depending on where on the
        // page it lands.
        let pattern = /vqd=["']?([0-9-]+)/
        guard let match = html.firstMatch(of: pattern) else {
            logger.warning("No image search token on the page — the search page layout has probably changed")
            throw WebSearchError.missingElement("vqd")
        }
        return String(match.1)
    }

    /// Only the fields worth carrying. The endpoint returns rather more —
    /// dimensions, a thumbnail, a discovery date — none of which anything here
    /// asks for yet.
    private struct ImageSearchPayload: Decodable {
        let results: [Result]

        struct Result: Decodable {
            let image: String
            let url: String
            let title: String
        }
    }
}

extension DuckSearch {

    private func extractResults(_ data: Data, baseURL: URL, query: String) throws -> WebSearchResponse {

        // Do not use the code path `Fuzi.HTMLDocument(string:)` because it will lead to silent parsing failures
        // only on release builds. There be demons in this package.
        let doc = try parse(data: data)
        let elements = doc.css("#links .result")

        // A result with no usable link is skipped rather than crashed on. These
        // selectors describe somebody else's markup, which changes without
        // notice and carries rows that were never search results to begin with;
        // one of those should cost a result, not the app. The previous
        // force-unwrap fell back to an empty string, and URL("") is nil.
        let results = elements.compactMap { element -> WebSearchResult? in
            guard let link = element.firstChild(css: "h2 a"),
                  let href = link.attr("href"),
                  let url = URL(string: href)
            else { return nil }

            return WebSearchResult(
                url: url,
                title: link.stringValue,
                description: element.firstChild(css: ".result__snippet")?.stringValue ?? ""
            )
        }

        // Said out loud, because the alternative is indistinguishable from the
        // web having no answer: a scraper that has stopped matching returns
        // nothing and reports success, and the assistant faithfully relays that
        // it found nothing.
        if elements.isEmpty {
            logger.warning("No results matched the page layout — either the search found nothing, or the markup changed")
        } else if results.count < elements.count {
            logger.warning("Skipped \(elements.count - results.count, privacy: .public) of \(elements.count, privacy: .public) results with no usable link")
        }
        return WebSearchResponse(query: query, results: results)
    }

    private func parse(data: Data) throws -> Fuzi.HTMLDocument {
        // Do not use the code path `Fuzi.HTMLDocument(string:)` because it will lead to silent parsing failures
        // only on release builds. There be demons in this package.
        try Fuzi.HTMLDocument(data: data)
    }
}
