import Foundation

/// A provider Heat can search the web with.
///
/// Deliberately not a `GenKit.Service`. Everything in that list answers a
/// question about models — which to chat with, which to draw with, which to
/// transcribe with — and its accessors are `chatService()`, `imageService()`
/// and their siblings. A search provider has no models at all, so adding it
/// there would mean a kind that refuses every one of those accessors, and a
/// Services pane whose six model pickers apply to nothing.
public struct SearchService: Identifiable, Codable, Hashable, Sendable {
    public var kind: Kind
    public var host: String
    public var token: String

    /// One entry per kind: two providers of the same kind would differ only
    /// by credentials, and nothing here has a use for that.
    public var id: String { kind.rawValue }

    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Scraped rather than asked, no key, no bill, and rate-limited by
        /// something nobody publishes. See `WebSearchSession`.
        case duckDuckGo

        /// A JSON API with a key and a price: $5 per thousand requests, with
        /// $5 of credit a month, so roughly a thousand searches before it
        /// costs anything. Free use asks for attribution.
        case brave

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .duckDuckGo: "DuckDuckGo"
            case .brave: "Brave Search"
            }
        }

        /// What it is for, in the pane.
        public var summary: String {
            switch self {
            case .duckDuckGo:
                "Free and needs no account. Heat reads the ordinary search page, which is rate-limited by something DuckDuckGo doesn't publish — a burst of searches in one answer can be refused for an hour or more."
            case .brave:
                "A search API with a key. Used when DuckDuckGo refuses a search, so an answer that needs the web still gets it. $5 of credit a month is about a thousand searches; after that it's $5 per thousand."
            }
        }

        public var needsToken: Bool {
            switch self {
            case .duckDuckGo: false
            case .brave: true
            }
        }

        /// Where to go for a key, for the kinds that need one.
        public var signUp: URL? {
            switch self {
            case .duckDuckGo: nil
            case .brave: URL(string: "https://api-dashboard.search.brave.com/app/keys")
            }
        }

        var defaultHost: String {
            switch self {
            case .duckDuckGo: "https://html.duckduckgo.com/html"
            case .brave: "https://api.search.brave.com/res/v1/web/search"
            }
        }
    }

    public init(kind: Kind, host: String? = nil, token: String = "") {
        self.kind = kind
        self.host = host ?? kind.defaultHost
        self.token = token
    }

    /// Whether this provider can actually be asked anything.
    public var isReady: Bool {
        guard !host.isEmpty else { return false }
        return !kind.needsToken || !token.isEmpty
    }
}

// MARK: - Storage

extension Config {

    /// The search providers, in the order they're tried.
    ///
    /// Seeded rather than stored on first run, and read through here so a
    /// config written before search providers existed answers with the
    /// defaults instead of nothing.
    public var searchProviders: [SearchService] {
        get {
            guard case .array(let stored)? = metadata["searchProviders"] else {
                return Self.defaultSearchProviders
            }
            let decoded = stored.compactMap { entry -> SearchService? in
                guard case .object(let fields) = entry,
                      let raw = fields["kind"]?.stringValue,
                      let kind = SearchService.Kind(rawValue: raw)
                else {
                    return nil
                }
                return SearchService(
                    kind: kind,
                    host: fields["host"]?.stringValue,
                    token: fields["token"]?.stringValue ?? ""
                )
            }
            // A kind added to Heat after this config was written still
            // appears, at its defaults, rather than being missing until
            // something happens to rewrite the list.
            let known = Set(decoded.map(\.kind))
            return decoded + Self.defaultSearchProviders.filter { !known.contains($0.kind) }
        }
        set {
            metadata["searchProviders"] = .array(
                newValue.map { provider in
                    .object([
                        "kind": .string(provider.kind.rawValue),
                        "host": .string(provider.host),
                        "token": .string(provider.token),
                    ])
                }
            )
        }
    }

    static let defaultSearchProviders: [SearchService] =
        SearchService.Kind.allCases.map { SearchService(kind: $0) }

    public func searchProvider(_ kind: SearchService.Kind) -> SearchService {
        searchProviders.first { $0.kind == kind } ?? SearchService(kind: kind)
    }

    public mutating func setSearchProvider(_ provider: SearchService) {
        var providers = searchProviders
        if let index = providers.firstIndex(where: { $0.kind == provider.kind }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        searchProviders = providers
    }
}
