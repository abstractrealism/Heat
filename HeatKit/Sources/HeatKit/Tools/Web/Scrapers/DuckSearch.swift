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

    /// A session of its own, so that it keeps cookies. The request used to
    /// refuse them, and a client that says it's Safari and then drops every
    /// cookie it's handed doesn't behave like Safari. Ephemeral, so nothing
    /// outlives the app or is shared with any other request Heat makes.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: configuration)
    }()

    public func search(web query: String) async throws -> WebSearchResponse {
        // The platform's own browser, since the TLS stack underneath really
        // is Apple's: a Mac presenting as macOS Safari is accurate, where a
        // Mac presenting as an iPhone is one more thing that doesn't add up.
        #if os(macOS)
        let userAgent = WebSearchUserAgent.safari
        #else
        let userAgent = WebSearchUserAgent.mobile
        #endif

        var urlComponents = URLComponents(string: host)!
        urlComponents.queryItems = [.init(name: "q", value: query)]

        var request = URLRequest(url: urlComponents.url!)
        request.setValue(userAgent.rawValue, forHTTPHeaderField: "User-Agent")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")

        let (data, response) = try await Self.session.data(for: request)
        let baseURL = response.url ?? urlComponents.url!
        let status = (response as? HTTPURLResponse)?.statusCode
        let resp = try extractResults(data, baseURL: baseURL, query: query, status: status)
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

    func extractResults(_ data: Data, baseURL: URL, query: String, status: Int? = nil) throws -> WebSearchResponse {

        // Do not use the code path `Fuzi.HTMLDocument(string:)` because it will lead to silent parsing failures
        // only on release builds. There be demons in this package.
        let doc = try parse(data: data)

        // Refused, not empty. Asked too often in too short a time, DuckDuckGo
        // answers with a puzzle — "select all squares containing a duck" —
        // on a page with no results on it and, as it happens, status 202. To
        // the selectors below that page is indistinguishable from a search
        // that found nothing, and it was being reported as exactly that: the
        // model was told the web had no answer, rephrased, and asked again,
        // which is the one thing that keeps the puzzle coming. Measured: one
        // search answered, the next four were all challenges. So it's an
        // error, worded for the model, rather than an empty success.
        //
        // Two markers, either will do: the form the puzzle posts to, and the
        // overlay it sits in. Checked against a captured challenge with the
        // same selector engine — the first attempt matched an id that turned
        // out to be a `data-testid`, which Fuzi's selectors can't see.
        if !doc.css("#challenge-form").isEmpty || !doc.css(".anomaly-modal__mask").isEmpty {
            logger.warning("DuckDuckGo served a bot challenge instead of results (status \(status ?? 0, privacy: .public))")
            throw WebSearchError.challenged
        }

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
            logger.warning("No results matched the page layout (status \(status ?? 0, privacy: .public)) — either the search found nothing, or the markup changed")
            keepForInspection(data, reason: "no-results", status: status)
        } else if results.count < elements.count {
            logger.warning("Skipped \(elements.count - results.count, privacy: .public) of \(elements.count, privacy: .public) results with no usable link (status \(status ?? 0, privacy: .public))")
            if results.isEmpty {
                keepForInspection(data, reason: "no-usable-link", status: status)
            }
        }
        return WebSearchResponse(query: query, results: results)
    }

    /// Saves a page the parser couldn't read anything from, so it can be
    /// looked at. Debug builds only — this is for finding out what a page
    /// that yields nothing actually is, which the log lines above can't say.
    /// Written under the app's own Documents, in `Debug/DuckSearch/`.
    private func keepForInspection(_ data: Data, reason: String, status: Int?) {
        #if DEBUG
        let directory = URL.documentsDirectory.appending(path: "Debug/DuckSearch", directoryHint: .isDirectory)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let file = directory.appending(path: "\(stamp)-\(reason)-\(status ?? 0).html")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file)
            logger.warning("kept the page for inspection: \(file.path, privacy: .public)")
        } catch {
            logger.warning("couldn't keep the page for inspection: \(error, privacy: .public)")
        }
        #endif
    }

    private func parse(data: Data) throws -> Fuzi.HTMLDocument {
        // Do not use the code path `Fuzi.HTMLDocument(string:)` because it will lead to silent parsing failures
        // only on release builds. There be demons in this package.
        try Fuzi.HTMLDocument(data: data)
    }
}
