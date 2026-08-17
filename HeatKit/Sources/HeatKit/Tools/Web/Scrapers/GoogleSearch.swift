import Foundation
import Fuzi

/// Google search by scraping. **Nothing calls this.**
///
/// `WebSearchSession` uses `DuckSearch` for both text and images. The web path
/// here has been unreferenced for some time; the image path was in use until
/// Google stopped serving results to it.
///
/// Both request Google's legacy no-JavaScript rendering (`gbv=1`) and read
/// results out of the markup, which is the part that broke: the request still
/// succeeds and returns a page correctly titled for the query, containing none
/// of the `/imgres` links `extractImageResults` looks for. So it fails as an
/// empty result list rather than as an error, which is the worst way for a
/// search to fail — indistinguishable from the web having no answer.
///
/// Kept rather than deleted, as somewhere to start from if Google is worth
/// another attempt, or if DuckDuckGo ever needs a fallback. Anything reviving
/// it should expect to replace the `gbv=1` approach entirely, not repair the
/// selectors.
public struct GoogleSearch: WebSearch, WebImageSearch {

    let host = "https://www.google.com/search"

    public func search(web query: String) async throws -> WebSearchResponse {
        let userAgent = WebSearchUserAgent.desktop

        var urlComponents = URLComponents(string: host)!
        urlComponents.queryItems = [
            .init(name: "q", value: query),
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.httpShouldHandleCookies = false
        request.setValue(userAgent.rawValue, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .returnCacheDataElseLoad

        let (data, response) = try await URLSession.shared.data(for: request)
        let baseURL = response.url ?? urlComponents.url!
        let resp = try extractResults(data, baseURL: baseURL, query: query)
        return resp
    }

    public func search(images query: String) async throws -> WebSearchResponse {
        let userAgent = WebSearchUserAgent.mobile

        var urlComponents = URLComponents(string: host)!
        urlComponents.queryItems = [
            .init(name: "q", value: query),
            .init(name: "tbm", value: "isch"), // to be matched = image search
            .init(name: "gbv", value: "1"), // google basic version = 1 (no js)
        ]

        var request = URLRequest(url: urlComponents.url!)
        request.httpShouldHandleCookies = false
        request.setValue(userAgent.rawValue, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let baseURL = response.url ?? urlComponents.url!
        let resp = try extractImageResults(data, baseURL: baseURL, query: query)
        return resp
    }
}

extension GoogleSearch {

    private func extractResults(_ data: Data, baseURL: URL, query: String) throws -> WebSearchResponse {
        let doc = try parse(data: data)
        guard let main = doc.css("#main").first else {
            throw WebSearchError.missingElement("#main")
        }
        var results = [WebSearchResult]()
        let anchors = main.css("a").filter { el in
            let h3s = el.css("h3")
                .filter { $0.attr("role") != "header" && $0.attr("aria-hidden") != "true" }
            return h3s.count > 0
        }
        for anchor in anchors {
            if let result = try anchor.extractSearchResultFromAnchor(baseURL: baseURL) {
                results.append(result)
            }
        }

        // Try fetching youtube results and insert at position 1
        if let youtubeResults = try main.extractYouTubeResults() {
            results.insert(contentsOf: youtubeResults, at: min(1, results.count))
        }
        return .init(query: query, results: results)
    }

    private func extractImageResults(_ data: Data, baseURL: URL, query: String) throws -> WebSearchResponse {
        let doc = try parse(data: data)
        let results = doc.css("a[href]")
            .filter { $0.attr("href")?.starts(with: "/imgres") ?? false }
            .compactMap { el -> WebSearchResult? in
                guard let href = el.attr("href"),
                      let comps = URLComponents(string: href),
                      let imgUrlStr = comps.queryItems?.first(where: { $0.name == "imgurl" })?.value,
                      let imgUrl = URL(string: imgUrlStr),
                      let siteUrlStr = comps.queryItems?.first(where: { $0.name == "imgrefurl" })?.value,
                      let siteUrl = URL(string: siteUrlStr)
                else {
                    return nil
                }
                return .init(url: siteUrl, image: imgUrl)
        }
        return WebSearchResponse(query: query, results: results)
    }

    private func parse(data: Data) throws -> Fuzi.HTMLDocument {
        // Do not use the code path `Fuzi.HTMLDocument(string:)` because it will lead to silent
        // parsing failures only on release builds. There be demons in this package.
        try Fuzi.HTMLDocument(data: data)
    }
}
