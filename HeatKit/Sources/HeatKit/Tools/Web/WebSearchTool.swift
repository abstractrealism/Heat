import Foundation
import SharedKit
import GenKit

public struct WebSearchTool {

    public struct Arguments: Codable {
        public var query: String
        /// Web unless said otherwise. Models leave it out, and a search
        /// with no kind is plainly a web search — it used to fail decoding
        /// and come back as "The operation couldn't be completed".
        public var kind: Kind

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            query = try container.decode(String.self, forKey: .query)
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .web
        }
    }
    
    public struct Response: Codable {
        public var kind: Kind
        public var instructions: String
        public var results: [WebSearchResult]
    }
    
    public enum Kind: String, Codable, CaseIterable {
        case web
        case image
    }
    
    public static let function = Tool.Function(
        name: "web_search",
        description: "Search the web (kind: web) for pages, or (kind: image) for pictures to show the user. Web results are up to ten titles, links and snippets; a link already returned earlier in this turn comes back by title only, marked as seen. Search with a few plain words naming the thing and the place. Exact phrases in quotes rarely match anything, and OR makes each term match on its own, so the results are about one of them rather than all.",
        parameters: .object(
            properties: [
                "query": .string(description: "A web search query"),
                "kind": .string(description: "A kind of search", enum: Kind.allCases.map { .string($0.rawValue) }),
            ],
            required: ["query", "kind"]
        )
    )
}

extension WebSearchTool.Arguments {
    
    public init(_ arguments: String?) throws {
        guard let arguments, let data = arguments.data(using: .utf8) else {
            throw ToolboxError.badArguments(tool: "web_search", expected: #"{"query": "…", "kind": "web" or "image"}"#, got: arguments ?? "nothing")
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ToolboxError.badArguments(tool: "web_search", expected: #"{"query": "…", "kind": "web" or "image"}"#, got: arguments)
        }
    }
}

extension WebSearchTool {
    
    public static func handle(_ toolCall: ToolCall, turn: SearchTurn? = nil) async -> [Message] {
        do {
            let args = try Arguments(toolCall.function?.arguments)
            
            switch args.kind {
            case .web:
                let searchResponse = try await WebSearchSession.shared.search(query: args.query)

                // Said outright, because the template below asks the model to
                // pick at least three of the results — an instruction that,
                // given none, reads as a reason to search again the same way.
                // What the engine itself suggests is what a model that has
                // over-quoted needs to hear.
                if searchResponse.results.isEmpty {
                    // Said more firmly the third time. A model that gets
                    // nothing back tends to try again more precisely — more
                    // quotes, more ORs — when the precision is the problem.
                    let empties = await turn?.noteEmpty() ?? 1
                    let advice = empties >= 3
                        ? "That's \(empties) searches this turn that found nothing, and the shape of the query is why: an exact phrase in quotes rarely appears anywhere, and OR makes each term match on its own. Search more broadly, the way a person would — a few plain words naming the thing and the place, no quotes, no OR — and read what comes back."
                        : "Try different or fewer words, and drop quotation marks and OR — an exact phrase rarely matches."
                    return [.init(
                        role: .tool,
                        content: """
                            No results found for "\(args.query)". \(advice)
                            """,
                        toolCallID: toolCall.id,
                        name: toolCall.function?.name,
                        metadata: ["label": .string("Searched web for '\(args.query)' — nothing found")]
                    )]
                }

                let found = Array(searchResponse.results.prefix(10))
                let alreadySeen = await turn?.mark(found.map(\.url)) ?? []

                // OR doesn't narrow, it widens: DuckDuckGo matches any one of
                // the terms on its own, and "… Rhinebeck OR Hudson OR Beacon"
                // came back as ten pages about the word Beacon. Said with the
                // results, so the model reads them knowing that.
                let usedOr = args.query.range(of: #"\bOR\b"#, options: .regularExpression) != nil
                let caveat = usedOr
                    ? "\nNote: OR makes each term match on its own, so some of these are about just one of the terms. Plain words without OR match all of them together.\n"
                    : ""

                // Results and nothing else. A page of instructions used to
                // ride along with every one of these — the same two hundred
                // and fifty tokens, fifteen times in one turn — and the model
                // re-read every copy on every round. What it needs to know
                // about the tool is in the tool's own description, sent once.
                let results = found.map { result in
                    if alreadySeen.contains(result.url) {
                        return """
                            <result>
                                <title>\(result.title ?? "No title")</title>
                                <url>\(result.url)</url>
                                <description>Returned earlier in this turn; see above.</description>
                            </result>
                        """
                    }
                    return """
                        <result>
                            <title>\(result.title ?? "No title")</title>
                            <url>\(result.url)</url>
                            <description>\(result.description ?? "No description")</description>
                        </result>
                    """
                }

                return [.init(
                    role: .tool,
                    content: """
                        <search_results query="\(args.query)">
                        \(results.joined(separator: "\n"))
                        </search_results>\(caveat)
                        """,
                    toolCallID: toolCall.id,
                    name: toolCall.function?.name,
                    metadata: ["label": .string("Searched web for '\(args.query)'")]
                )]
            case .image:
                let searchResponse = try await WebSearchSession.shared.searchImages(query: args.query)
                let found = Array(searchResponse.results.prefix(10))
                let response = Response(
                    kind: .image,
                    instructions: """
                        Search complete. \(found.count) images are being shown to the user beneath your reply. \
                        DO NOT repeat any of the image URLs — the user can already see the pictures. Simply say \
                        what you found. Do not respond with any more URLs.
                        """,
                    results: found
                )
                let data = try JSONEncoder().encode(response)
                let content = String(data: data, encoding: .utf8)
                return [.init(
                    role: .tool,
                    content: content,
                    toolCallID: toolCall.id,
                    name: toolCall.function?.name,
                    metadata: [
                        "label": .string("Searched web images for '\(args.query)'"),

                        // Carried in metadata rather than as image content on
                        // the message. Content goes back to the model on every
                        // later turn, and the Ollama encoder downloads each
                        // image to send it — so a search for pictures would
                        // re-fetch all ten of them before every subsequent
                        // message, and hand them to a model that may not read
                        // images at all. Metadata is stored and displayed but
                        // never sent.
                        "images": .array(found.compactMap { result in
                            guard let image = result.image else { return nil }
                            return .object([
                                "image": .string(image.absoluteString),
                                "source": .string(result.url.absoluteString),
                                "title": .string(result.title ?? ""),
                            ])
                        }),
                    ]
                )]
            }
            
        } catch {
            return [.init(
                role: .tool,
                content: """
                    <error>
                        \(error.localizedDescription)
                    </error>
                    """,
                toolCallID: toolCall.id,
                name: toolCall.function?.name
            )]
        }
    }
}
