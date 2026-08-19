import SwiftUI
import MarkdownUI

struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration

    @State private var isCopied = false
    @State private var saveOutcome: SaveOutcome = .none

    /// What the save button last did, so the button can say so without an
    /// alert. There's no save panel to confirm the write — the file goes
    /// straight to Downloads — so the only report is this.
    private enum SaveOutcome {
        case none, saved, failed
    }

    /// The language and, if the model named one, the file. Parsed rather than
    /// read straight off `configuration.language`, which is the entire fence
    /// info string. See `CodeFence`.
    private var fence: CodeFence {
        CodeFence(fenceInfo: configuration.language)
    }

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
                Text(headerLabel)
                    .font(.subheadline)
                Spacer()

                // macOS only. On iOS the same path would write into the app's
                // own container, where nobody would ever find the file — that
                // wants a share sheet instead, and iOS is untouched for now.
                #if os(macOS)
                Button(action: saveCodeAction) {
                    Image(systemName: saveSymbol)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(saveHelp)
                #endif

                Button(action: copyCodeAction) {
                    Image(systemName: isCopied ? "checkmark" : "square.on.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Copy this code")
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

    /// Normally what the block is; briefly what just happened to it.
    ///
    /// The Dock bounce is undocumented and can only fail silently, so the
    /// confirmation that a file was written has to be legible here too — a
    /// checkmark alone reads the same as nothing happening if you're expecting
    /// the Dock to move and it doesn't.
    private var headerLabel: String {
        #if os(macOS)
        switch saveOutcome {
        case .none: fence.displayLabel
        case .saved: "Saved to Downloads"
        case .failed: "Couldn't save"
        }
        #else
        fence.displayLabel
        #endif
    }

    #if os(macOS)
    private var saveSymbol: String {
        switch saveOutcome {
        case .none: "square.and.arrow.down"
        case .saved: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var saveHelp: String {
        switch saveOutcome {
        case .none: "Save \(fence.suggestedFilename) to Downloads"
        case .saved: "Saved to Downloads"
        case .failed: "Couldn't save — see Settings ▸ Logs"
        }
    }

    @MainActor
    private func saveCodeAction() {
        do {
            try CodeDownload.save(configuration.content, as: fence.suggestedFilename)
            saveOutcome = .saved
        } catch {
            // The app has no working error alert, so a failure that only
            // changed the symbol would be lost the moment it reset. Logged too.
            AppState.shared.log(error: error)
            saveOutcome = .failed
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saveOutcome = .none
        }
    }
    #endif

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
