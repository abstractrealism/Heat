import Foundation
import Testing

@testable import HeatKit

/// Brave's Web Search API, read the way the other provider's HTML is: from
/// the shape the service actually answers with, reduced to the three things
/// a result is — a link, a title and a snippet.
///
/// The payload below is built from Brave's documented response rather than
/// captured from a live one, there being no key to capture with yet. It is
/// the one thing here not taken from the wire, and worth replacing with a
/// real response once there is one.
struct BraveSearchTests {

    private let brave = BraveSearch(host: "https://api.search.brave.com/res/v1/web/search", token: "test")

    private static let payload = Data(#"""
    {
      "type": "search",
      "query": { "original": "nashville tofu hudson valley", "more_results_available": true },
      "web": {
        "type": "search",
        "results": [
          {
            "title": "The Beacon Daily",
            "url": "https://thebeacondaily.com/",
            "description": "Gourmet sandwiches in <strong>Beacon</strong>, NY &mdash; including a <strong>Nashville</strong> hot tots.",
            "profile": { "name": "thebeacondaily", "long_name": "thebeacondaily.com" },
            "meta_url": { "hostname": "thebeacondaily.com" }
          },
          {
            "title": "veg+ &mdash; Menu",
            "url": "https://www.yelp.com/menu/veg-hudson",
            "description": "Tofu tacos &amp; bowls at veg+ in Hudson &quot;all day&quot;."
          }
        ]
      },
      "mixed": { "type": "mixed", "main": [{ "type": "web", "index": 0, "all": false }] }
    }
    """#.utf8)

    @Test("Results come back as a link, a title and a snippet")
    func results() throws {
        let response = try brave.decode(Self.payload, query: "nashville tofu hudson valley")

        #expect(response.query == "nashville tofu hudson valley")
        #expect(response.results.count == 2)
        #expect(response.results.first?.url.absoluteString == "https://thebeacondaily.com/")
        #expect(response.results.first?.title == "The Beacon Daily")
    }

    /// Brave marks the words it matched with `<strong>`. A snippet goes into
    /// a tool result as text, where markup is noise a model reads past.
    @Test("The markup Brave puts in a snippet is taken out")
    func snippets() throws {
        let response = try brave.decode(Self.payload, query: "q")

        #expect(
            response.results.first?.description
                == "Gourmet sandwiches in Beacon, NY &mdash; including a Nashville hot tots."
        )
        // The entities it does emit are turned back into characters; the ones
        // it doesn't are left alone rather than guessed at.
        #expect(response.results.last?.description == #"Tofu tacos & bowls at veg+ in Hudson "all day"."#)
    }

    /// The response omits whole sections depending on the query, so nothing
    /// is required.
    @Test("A response with no web section is empty rather than an error")
    func noWebSection() throws {
        let response = try brave.decode(Data(#"{"type":"search","query":{"original":"x"}}"#.utf8), query: "x")
        #expect(response.results.isEmpty)
    }

    @Test("A result with an unusable link is left out, not fatal")
    func badLink() throws {
        let payload = Data(#"""
        {"web":{"results":[{"title":"fine","url":"https://example.invalid/a"},{"title":"broken","url":""}]}}
        """#.utf8)
        let response = try brave.decode(payload, query: "x")
        #expect(response.results.count == 1)
        #expect(response.results.first?.title == "fine")
    }

    @Test("Something that isn't the expected shape says so")
    func unreadable() {
        #expect(throws: BraveSearchError.self) {
            try brave.decode(Data("<html>nope</html>".utf8), query: "x")
        }
    }

    /// Brave's documentation doesn't say what it answers when a quota runs
    /// out, so the status is read and the body carried through either way.
    @Test("A refusal is told apart as far as it can be")
    func failures() {
        let body = Data(#"{"error":{"detail":"RATE_LIMITED"}}"#.utf8)

        if case .rateLimited = BraveSearch.failure(status: 429, body: body) {} else {
            Issue.record("429 is a rate limit")
        }
        if case .keyRefused = BraveSearch.failure(status: 401, body: body) {} else {
            Issue.record("401 is the key")
        }
        if case .refused(let status, _) = BraveSearch.failure(status: 503, body: Data()) {
            #expect(status == 503)
        } else {
            Issue.record("anything else keeps its status")
        }
    }

    /// What the model reads. A bare error describes itself as "The operation
    /// couldn't be completed", which says nothing about whether to try again.
    @Test("The refusals are worded for the model")
    func wording() {
        #expect(BraveSearchError.noKey.localizedDescription.contains("Settings ▸ Tools"))
        #expect(
            BraveSearchError.rateLimited("quota").localizedDescription
                .contains("temporarily unavailable")
        )
        #expect(BraveSearchError.refused(status: 503, detail: nil).localizedDescription.contains("503"))
    }

    @Test("Asking without a key doesn't make a request")
    func noKey() async {
        let brave = BraveSearch(host: "https://api.search.brave.com/res/v1/web/search", token: "")
        await #expect(throws: BraveSearchError.self) {
            try await brave.search(web: "anything")
        }
    }
}

/// Where the providers and their keys live.
struct SearchProviderTests {

    @Test("Both providers are there before anything is configured")
    func defaults() {
        let config = Config()
        #expect(config.searchProviders.map(\.kind) == [.duckDuckGo, .brave])
        #expect(config.searchProvider(.brave).host == "https://api.search.brave.com/res/v1/web/search")
        #expect(config.searchProvider(.duckDuckGo).token.isEmpty)
    }

    /// One needs a key and one doesn't, which is the whole of what "ready"
    /// means here.
    @Test("Readiness is about whether it can be asked at all")
    func readiness() {
        var config = Config()
        #expect(config.searchProvider(.duckDuckGo).isReady)
        #expect(config.searchProvider(.brave).isReady == false)

        var brave = config.searchProvider(.brave)
        brave.token = "a-key"
        config.setSearchProvider(brave)
        #expect(config.searchProvider(.brave).isReady)
    }

    @Test("A key survives being written out and read back")
    func roundTrips() throws {
        var config = Config()
        var brave = config.searchProvider(.brave)
        brave.token = "a-key"
        config.setSearchProvider(brave)

        let decoded = try JSONDecoder().decode(Config.self, from: try JSONEncoder().encode(config))
        #expect(decoded.searchProvider(.brave).token == "a-key")
        #expect(decoded.searchProviders.count == 2)
    }

    /// A config written before a provider existed answers with it at its
    /// defaults, rather than leaving it out until something rewrites the list.
    @Test("A provider added later still appears")
    func laterAddition() {
        var config = Config()
        config.metadata["searchProviders"] = .array([
            .object([
                "kind": .string("duckDuckGo"),
                "host": .string("https://html.duckduckgo.com/html"),
                "token": .string(""),
            ])
        ])
        #expect(config.searchProviders.count == 2)
        #expect(config.searchProviders.map(\.kind).contains(.brave))
    }

    @Test("An address can be overridden, as a service's can")
    func hostOverride() {
        var config = Config()
        var brave = config.searchProvider(.brave)
        brave.host = "https://example.invalid/search"
        config.setSearchProvider(brave)
        #expect(config.searchProvider(.brave).host == "https://example.invalid/search")
    }
}
