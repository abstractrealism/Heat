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
        description: "Return a search query used to search the web for website only or image only results.",
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
    
    public static func handle(_ toolCall: ToolCall) async -> [Message] {
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

                let results = Array(searchResponse.results.prefix(10)).map {
                    """
                        <result>
                            <title>\($0.title ?? "No title")</title>
                            <url>\($0.url)</url>
                            <description>\($0.description ?? "No description")</description>
                        </result>
                    """
                }

                // TODO: Use cached instructions
                // Probably need to pass in these instructions at the call site instead of referencing Defaults here.

                return [.init(
                    role: .tool,
                    content: PromptTemplate(Defaults.webSearchInstruction.instructions, with: [
                        "query": .string(args.query),
                        "results": .string(results.joined(separator: "\n")),
                    ]),
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
