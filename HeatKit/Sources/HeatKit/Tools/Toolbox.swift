import Foundation
import SharedKit
import GenKit

public enum Toolbox: CaseIterable, Sendable {
    case generateImages
    case searchCalendar
    case searchWeb
    case browseWeb
    
    // Because the name is influential in the prompting it may change so this is
    // a good place to put legacy names so they return the correct tool.
    public init?(name: String?) {
        switch name {
        case ImageGeneratorTool.function.name:
            self = .generateImages
        case CalendarSearchTool.function.name:
            self = .searchCalendar
        case WebSearchTool.function.name:
            self = .searchWeb
        case WebBrowseTool.function.name:
            self = .browseWeb
        default:
            return nil
        }
    }
    
    public var tool: Tool {
        switch self {
        case .generateImages:
            Tool(function: ImageGeneratorTool.function)
        case .searchCalendar:
            Tool(function: CalendarSearchTool.function)
        case .searchWeb:
            Tool(function: WebSearchTool.function)
        case .browseWeb:
            Tool(function: WebBrowseTool.function)
        }
    }
    
    public var name: String {
        tool.function?.name ?? ""
    }

    /// What to call this when offering it to somebody.
    ///
    /// Separate from `name`, which is written for the model and may change with
    /// the prompting — a menu shouldn't read `browse_web`, and shouldn't shift
    /// wording because a function was renamed.
    public var label: String {
        switch self {
        case .generateImages: "Generate Images"
        case .searchCalendar: "Search Calendar"
        case .searchWeb: "Search the Web"
        case .browseWeb: "Browse Web Pages"
        }
    }
    
    public static func get(names: Set<String>) -> [Tool] {
        return Toolbox.allCases
            .filter { names.contains($0.tool.function?.name ?? "") }
            .map { $0.tool }
    }
}

/// Described in words, because a tool's failure goes back to the model as
/// the tool's result, and "The operation couldn't be completed" gives it
/// nothing to correct.
public enum ToolboxError: LocalizedError {
    case failedDecoding
    case badArguments(tool: String, expected: String, got: String)

    public var errorDescription: String? {
        switch self {
        case .failedDecoding:
            "The tool's arguments couldn't be read."
        case .badArguments(let tool, let expected, let got):
            "\(tool) couldn't read its arguments. Expected \(expected); got \(got)."
        }
    }
}
