import Foundation
import SharedKit
import GenKit

public struct WebSearchTool {

    public struct Arguments: Codable {
        public var query: String
        public var kind: Kind
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
        description: "Search the web (kind: web) for pages, or (kind: image) for pictures to show the user. Web results are up to ten titles, links and snippets; a link already returned earlier in this turn comes back by title only, marked as seen. Plain words find more than exact phrases in quotes.",
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
            throw ToolboxError.failedDecoding
        }
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}

extension WebSearchTool {
    
    public static func handle(_ toolCall: ToolCall, seen: SeenLinks? = nil) async -> [Message] {
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
                    return [.init(
                        role: .tool,
                        content: """
                            No results found for "\(args.query)". Try different or fewer words, and drop quotation marks and OR — an exact phrase rarely matches.
                            """,
                        toolCallID: toolCall.id,
                        name: toolCall.function?.name,
                        metadata: ["label": .string("Searched web for '\(args.query)' — nothing found")]
                    )]
                }

                let found = Array(searchResponse.results.prefix(10))
                let alreadySeen = await seen?.mark(found.map(\.url)) ?? []

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
                        </search_results>
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
