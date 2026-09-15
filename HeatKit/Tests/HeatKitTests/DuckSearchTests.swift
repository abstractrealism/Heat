import Foundation
import Testing

@testable import HeatKit

/// The parser against two pages DuckDuckGo actually served, minutes apart,
/// to the same address with the same user agent: a page of results, and the
/// bot challenge that answered the next four searches.
///
/// The challenge is the one that matters. It carries no results, so to the
/// selectors it looked like a search that found nothing — and was reported
/// as one, which sent the model off to rephrase and ask again, which is what
/// keeps the challenge coming.
struct DuckSearchTests {

    private static func page(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private static let base = URL(string: "https://html.duckduckgo.com/html")!

    @Test("A page of results is read")
    func results() throws {
        let response = try DuckSearch().extractResults(
            try Self.page("duckduckgo-results"), baseURL: Self.base, query: "test", status: 200
        )
        #expect(response.results.count == 10)
        #expect(response.results.first?.url.host() == "www.hudsonvalleybbqco.com")
        #expect(response.results.allSatisfy { !($0.title ?? "").isEmpty })
    }

    @Test("A bot challenge is refused rather than reported as nothing found")
    func challenge() throws {
        #expect(throws: WebSearchError.self) {
            try DuckSearch().extractResults(
                try Self.page("duckduckgo-challenge"), baseURL: Self.base, query: "test", status: 202
            )
        }
    }

    @Test("The challenge is told from an empty page by its markup, not its status")
    func challengeByMarkup() throws {
        // The same page with a 200 is still a challenge.
        #expect(throws: WebSearchError.self) {
            try DuckSearch().extractResults(
                try Self.page("duckduckgo-challenge"), baseURL: Self.base, query: "test", status: 200
            )
        }
    }

    @Test("A page with no results and no challenge is empty, not an error")
    func genuinelyEmpty() throws {
        let empty = Data("<html><body><div id=\"links\"></div></body></html>".utf8)
        let response = try DuckSearch().extractResults(empty, baseURL: Self.base, query: "test", status: 200)
        #expect(response.results.isEmpty)
    }

    /// What the model reads. A bare error describes itself as "The operation
    /// couldn't be completed", which says nothing about whether to try again.
    @Test("The refusal is worded for the model")
    func wording() {
        let text = WebSearchError.challenged.localizedDescription
        #expect(text.hasPrefix("Web search isn't available right now"))
        #expect(text.contains("too many"))
        #expect(WebSearchError.holdingOff(42).localizedDescription.contains("42 seconds"))
        #expect(WebSearchError.holdingOff(1800).localizedDescription.contains("30 minutes"))
        #expect(WebSearchError.holdingOff(61).localizedDescription.contains("a minute"))
    }
}
