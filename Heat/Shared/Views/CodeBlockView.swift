import SwiftUI
import MarkdownUI

struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration

    @State private var isCopied = false

    /// The background atom-one-dark is drawn against — the theme the syntax
    /// highlighter is fixed to, whatever appearance the app is in.
    ///
    /// Deliberately an absolute colour. This used to fill with `.primary`,
    /// which is a hierarchical style: it resolves against whatever foreground
    /// it inherits rather than naming a colour. Inside a user message, where
    /// the text is white, it resolved to white — leaving the highlighter's
    /// light grey code on a white block.
    private static let background = Color(red: 0.157, green: 0.173, blue: 0.204)

    /// Fixed against that background for the same reason, rather than
    /// `.secondary` corrected with `.colorInvert()`.
    private static let chrome = Color.white.opacity(0.6)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.language?.capitalized ?? "")
                    .font(.subheadline)
                Spacer()
                Button(action: copyCodeAction) {
                    Image(systemName: isCopied ? "checkmark" : "square.on.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Self.chrome)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)

            configuration.label
                .relativeLineSpacing(.em(0.25))
                .padding(12)
        }
        .background(Self.background)
        .clipShape(.rect(cornerRadius: 5))
        .padding(.horizontal, -12)
    }

    private func copyCodeAction() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(configuration.content, forType: .string)
        #else
        let pasteboard = UIPasteboard.general
        pasteboard.string = configuration.content
        #endif

        isCopied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
}

extension CodeBlockConfiguration: @retroactive Hashable {

    public func hash(into hasher: inout Hasher) {
        hasher.combine(language)
        hasher.combine(content)
    }

    public static func == (lhs: CodeBlockConfiguration, rhs: CodeBlockConfiguration) -> Bool {
        return lhs.language == rhs.language && lhs.content == rhs.content
    }
}
