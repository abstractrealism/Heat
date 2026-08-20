#if os(macOS)
import SwiftUI
import AppKit

/// The message field's editor: an `NSTextView` that marks up code as it's
/// typed.
///
/// SwiftUI's `TextEditor` binds to a plain `String` and can't show attributed
/// text at all. The `AttributedString` editor that would do this properly —
/// `TextEditor(text: Binding<AttributedString>)` with an
/// `AttributedTextFormattingDefinition` — arrived in macOS 26, and Heat
/// deploys to 15. So this reaches for AppKit instead, which is where
/// `TextEditor` was going anyway.
///
/// **The text stays a `String`.** Styling is derived from it on every edit and
/// never stored, so everything that reads the field — sending, clearing,
/// templates, slash commands — is unchanged, and no attribute can survive into
/// what gets sent to a model.
struct MessageTextView: NSViewRepresentable {

    @Binding var text: String

    /// Set to ask for the keyboard; cleared once taken, so it's a request
    /// rather than a state to keep in step.
    @Binding var focusRequest: Bool

    let onSubmit: () -> Void

    /// The height the text actually needs, excluding padding — the field adds
    /// its own. Replaces the invisible mirror `Text` that used to measure this:
    /// a mirror can only be right while both engines lay out identically, and
    /// code spans in a different font is exactly when they stop.
    let onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator

        textView.isRichText = false
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false

        // Belt and braces with the app-wide defaults set in MainApp.init: this
        // field is the reason those exist, and it shouldn't quietly depend on
        // something set somewhere else.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // Matches the placeholder's horizontal padding, so the two sit on the
        // same left edge.
        textView.textContainer?.lineFragmentPadding = MessageTextStyle.lineFragmentPadding

        textView.font = MessageTextStyle.body
        textView.string = text
        if let storage = textView.textStorage {
            MessageTextStyle.apply(to: storage)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        // Only when something outside changed it — sending, clearing, choosing
        // a template. Assigning what's already there would collapse the
        // selection out from under whoever is typing.
        if textView.string != text {
            textView.string = text
            if let storage = textView.textStorage {
                MessageTextStyle.apply(to: storage)
            }
        }

        if focusRequest, let window = textView.window, window.firstResponder !== textView {
            window.makeFirstResponder(textView)
            DispatchQueue.main.async { focusRequest = false }
        }

        // Deferred: this runs inside a view update, and reporting a height
        // writes state that causes another one.
        DispatchQueue.main.async { context.coordinator.reportHeight() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MessageTextView
        weak var textView: NSTextView?

        /// Guards the attribute pass against re-entering itself. Attribute-only
        /// changes don't report as character edits, but the flag makes that a
        /// property of this code rather than of AppKit's.
        private var isStyling = false

        private var lastReportedHeight: CGFloat = -1

        init(parent: MessageTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }

            // Shift+Return makes a new line; Return sends. Both arrive as
            // insertNewline:, so the modifier has to come from the event.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }

            // Swallowed either way: an empty field shouldn't send, and it
            // shouldn't gain a stray line either.
            if !textView.string.isEmpty {
                parent.onSubmit()
            }
            return true
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !isStyling else { return }
            isStyling = true
            MessageTextStyle.apply(to: textStorage)
            isStyling = false
        }

        /// Measures what the text needs and passes it up, when it changes.
        func reportHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: container)
            let height = layoutManager.usedRect(for: container).height

            // A hair of tolerance: layout settles at fractionally different
            // heights, and reporting each one is a redraw for nothing.
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            parent.onHeightChange(height)
        }
    }
}

/// How the message field draws its text.
enum MessageTextStyle {

    static let lineFragmentPadding: CGFloat = 5

    static var body: NSFont {
        .preferredFont(forTextStyle: .body)
    }

    static var code: NSFont {
        .monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
    }

    /// Restyles the whole field from scratch.
    ///
    /// Everything is reset first and code marked afterwards, rather than the
    /// edited range being patched: a single keystroke can change what a span
    /// means far from the caret — typing the second backtick of a pair, or a
    /// fence that swallows the rest of the message — and a field holds a few
    /// lines, so there's nothing to gain by being clever about it.
    static func apply(to textStorage: NSTextStorage) {
        let everything = NSRange(location: 0, length: textStorage.length)
        guard everything.length > 0 else { return }

        textStorage.setAttributes(
            [.font: body, .foregroundColor: NSColor.labelColor],
            range: everything
        )

        for span in MessageSyntax.codeSpans(in: textStorage.string) {
            guard span.range.location >= 0,
                  span.range.location + span.range.length <= textStorage.length
            else { continue }

            textStorage.addAttributes(
                [.font: code, .backgroundColor: NSColor.quaternaryLabelColor],
                range: span.range
            )
        }
    }
}
#endif
