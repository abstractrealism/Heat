import Foundation
import Testing

@testable import HeatKit

/// Brave's Web Search API, read the way the other provider's HTML is: from
/// the shape the service actually answers with, reduced to the three things
/// a result is — a link, a title and a snippet.
///
/// From a live response, 25 Sept 2026. Worth saying what that changed from
/// the documented shape it replaced: the response carries `discussions`,
/// `mixed`, `query`, `type`, `videos` and `web` at the top, and a result
/// carries eighteen fields where the documentation names four. Everything
/// but `title`, `url` and `description` is ignored here, and has to be — a
/// decoder that required any of it would fail on the next query that omits
/// a section, which they do.
///
/// The descriptions are as returned, truncated where the capture truncated
/// them. `<strong>` and `&#x27;` are both real and both from this response,
/// which is what the stripping below exists for.
struct BraveSearchTests {

    private let brave = BraveSearch(host: "https://api.search.brave.com/res/v1/web/search", token: "test")

    private static let payload = Data(#"""
    {
      "type": "search",
      "query": { "original": "nashville hot tofu sandwich beacon ny", "more_results_available": true },
      "discussions": { "type": "search", "results": [] },
      "videos": { "type": "videos", "results": [] },
      "mixed": { "type": "mixed", "main": [{ "type": "web", "index": 0, "all": false }] },
      "web": {
        "type": "search",
        "family_friendly": true,
        "results": [
          {
            "type": "search_result",
            "subtype": "generic",
            "title": "Nashville-Style Hot Tofu Sliders Recipe - NYT Cooking",
            "url": "https://cooking.nytimes.com/recipes/1022584-nashville-style-hot-tofu-sliders",
            "description": "Tofu has a high water content, but a quick dredge in rice flour and a dip in batter creates a barrier that prevents excess splattering durin",
            "age": "2 years ago",
            "page_age": "2024-04-18T00:00:00",
            "language": "en",
            "family_friendly": true,
            "is_live": false,
            "is_source_both": false,
            "is_source_local": false,
            "profile": { "name": "NYT Cooking", "long_name": "cooking.nytimes.com" },
            "meta_url": { "hostname": "cooking.nytimes.com" },
            "thumbnail": { "src": "https://imgs.search.brave.com/thumb" },
            "organization": null,
            "recipe": null,
            "extra_snippets": ["Serve with pickles."]
          },
          {
            "type": "search_result",
            "title": "Nashville hot tofu sandwich - Strongr Fastr",
            "url": "https://www.strongrfastr.com/recipes/198408-nashville_hot_tofu_sandwich",
            "description": "<strong>Heat oil in a non-stick skillet over medium-high heat.</strong> Add the tofu and cook until crispy, about 2-4 minutes per side."
          },
          {
            "type": "search_result",
            "title": "Crispy Nashville Hot Tofu Sandwich - Evergreen Kitchen",
            "url": "https://evergreenkitchen.ca/hot-tofu-sandwich/",
            "description": "Vegans and meat-lovers can&#x27;t resist this Nashville Hot Tofu Sandwich! <strong>Crispy baked tofu gets drizzled with Hot Oil</strong>"
          }
        ]
      }
    }
    """#.utf8)

    @Test("Results come back as a link, a title and a snippet")
    func results() throws {
        let response = try brave.decode(Self.payload, query: "nashville tofu hudson valley")

        #expect(response.query == "nashville tofu hudson valley")
        #expect(response.results.count == 3)
        #expect(
            response.results.first?.url.absoluteString
                == "https://cooking.nytimes.com/recipes/1022584-nashville-style-hot-tofu-sliders"
        )
        #expect(response.results.first?.title == "Nashville-Style Hot Tofu Sliders Recipe - NYT Cooking")
    }

    /// Brave marks the words it matched with `<strong>`. A snippet goes into
    /// a tool result as text, where markup is noise a model reads past.
    @Test("The markup Brave puts in a snippet is taken out")
    func snippets() throws {
        let response = try brave.decode(Self.payload, query: "q")

        #expect(
            response.results[1].description
                == "Heat oil in a non-stick skillet over medium-high heat. Add the tofu and cook until crispy, about 2-4 minutes per side."
        )
        // The entities it emits are turned back into characters. `&#x27;` is
        // from this very response.
        #expect(
            response.results[2].description
                == "Vegans and meat-lovers can't resist this Nashville Hot Tofu Sandwich! Crispy baked tofu gets drizzled with Hot Oil"
        )
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

    /// A wrong key answers **422**, not 401 — which this originally assumed,
    /// from the shape of every other service. Verbatim from the live API.
    @Test("A wrong key is told apart from a bad query, both being 422")
    func wrongKey() {
        let body = Data(#"""
        {"error":{"code":"SUBSCRIPTION_TOKEN_INVALID","detail":"The provided subscription token is invalid.","meta":{"component":"authentication"},"status":422},"type":"ErrorResponse"}
        """#.utf8)

        if case .keyRefused(let detail) = BraveSearch.failure(status: 422, body: body) {
            // Brave's own sentence, which beats anything this could infer.
            #expect(detail == "The provided subscription token is invalid.")
        } else {
            Issue.record("422 with an authentication component is the key")
        }
    }

    /// A 422 that isn't about the key is about the query.
    @Test("A malformed query is still a bad request")
    func badRequest() {
        let body = Data(#"""
        {"error":{"code":"VALIDATION","detail":"q is required","meta":{"component":"validation"},"status":422}}
        """#.utf8)
        if case .badRequest = BraveSearch.failure(status: 422, body: body) {} else {
            Issue.record("422 from validation is the request")
        }
    }

    /// Quota is checked before the key, deliberately: a spent subscription
    /// may well report a code with SUBSCRIPTION in it, and being told the key
    /// is wrong when the key is fine sends somebody to check the one thing
    /// that isn't the problem.
    @Test("Running out is told apart from a wrong key", arguments: [
        #"{"error":{"code":"SUBSCRIPTION_QUOTA_EXCEEDED","detail":"out of credit","status":422}}"#,
        #"{"error":{"code":"RATE_LIMITED","detail":"too many","status":429}}"#,
    ])
    func spent(body: String) {
        if case .rateLimited = BraveSearch.failure(status: 422, body: Data(body.utf8)) {} else {
            Issue.record("a spent quota is not a wrong key")
        }
    }

    @Test("A status nobody here has seen keeps its number and its words")
    func unknownStatus() {
        if case .refused(let status, let detail) =
            BraveSearch.failure(status: 503, body: Data("upstream is down".utf8)) {
            #expect(status == 503)
            #expect(detail == "upstream is down")
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
