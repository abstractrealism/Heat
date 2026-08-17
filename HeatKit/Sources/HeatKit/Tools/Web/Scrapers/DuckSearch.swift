import Foundation
import OSLog
import Fuzi

private let logger = Logger(subsystem: "DuckSearch", category: "HeatKit")

public struct DuckSearch: WebSearch {

    let host = "https://html.duckduckgo.com/html"

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
