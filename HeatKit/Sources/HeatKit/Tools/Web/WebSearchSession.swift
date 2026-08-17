import Foundation
import QuartzCore
import Fuzi

public actor WebSearchSession {
    public static let shared = WebSearchSession()

    private init() {}

    public func search(query: String) async throws -> WebSearchResponse {
        let engine = DuckSearch()
        return try await engine.search(web: query)
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
