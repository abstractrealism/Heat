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
        let textView = MessageNSTextView()
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
            // The run of edits ended with the text it applied to.
            context.coordinator.coalescing.reset()
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

        /// Keeps typing and rubbing out in separate undo actions.
        var coalescing = UndoCoalescing()

        init(parent: MessageTextView) {
            self.parent = parent
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            // Nothing going in and something being replaced is a deletion,
            // however it was asked for.
            let isDeletion = (replacementString?.isEmpty ?? true) && affectedCharRange.length > 0
            if coalescing.shouldBreak(isDeletion: isDeletion) {
                textView.breakUndoCoalescing()
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            // The block fill is drawn rather than an attribute, so it doesn't
            // follow the text on its own.
            textView.needsDisplay = true
            reportHeight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            MessageTextStyle.updateTypingAttributes(of: textView)
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

/// Whether a run of edits should stop merging into a single undo.
///
/// AppKit merges consecutive typing into one undo action, and merges
/// backspaces into that same action — so typing a sentence, rubbing out the
/// last word, and pressing ⌘Z removes the whole sentence instead of putting
/// the word back. Verified as AppKit's own behaviour, not something Heat
/// introduced: a bare NSTextView with nothing attached does it too, and only
/// for backspaces — selecting a word and deleting it, or ⌥⌫, already undo the
/// way you'd expect.
///
/// Rubbing out is a different intention from writing, so a change of direction
/// ends the run and starts a new one.
struct UndoCoalescing {
    private var lastWasDeletion: Bool?

    mutating func shouldBreak(isDeletion: Bool) -> Bool {
        defer { lastWasDeletion = isDeletion }
        guard let previous = lastWasDeletion else { return false }
        return previous != isDeletion
    }

    /// Forgets the run, for when the text is replaced wholesale rather than
    /// edited — sending, clearing, choosing a template.
    mutating func reset() {
        lastWasDeletion = nil
    }
}

/// How the message field draws its text.
enum MessageTextStyle {

    static let lineFragmentPadding: CGFloat = 5

    /// How far code sits in from the edge, so a block reads as one.
    static let blockIndent: CGFloat = 10

    /// Clear space above and below a block, separating it from the prose it
    /// sits between.
    static let blockSpacing: CGFloat = 6

    /// The tint behind code, inline and block alike.
    static let fill = NSColor.quaternaryLabelColor

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

        let string = textStorage.string as NSString

        for span in MessageSyntax.codeSpans(in: textStorage.string) {
            guard span.range.location >= 0,
                  span.range.location + span.range.length <= textStorage.length
            else { continue }

            textStorage.addAttribute(.font, value: code, range: span.range)

            if span.isBlock {
                // No background attribute: a block is filled line by line, to
                // the full width, by the text view — see blockBackgroundRects.
                // The attribute only paints behind glyphs, which is why a block
                // used to stop wherever the typing had got to.
                applyBlockLayout(to: textStorage, span: span, in: string)
            } else {
                // Inline code hugs its own text, so the attribute is right.
                textStorage.addAttribute(.backgroundColor, value: fill, range: span.range)
            }
        }
    }

    /// Indents a block and sets it apart from whatever is above and below.
    private static func applyBlockLayout(
        to textStorage: NSTextStorage,
        span: MessageSyntax.Span,
        in string: NSString
    ) {
        let indented = NSMutableParagraphStyle()
        indented.headIndent = blockIndent
        indented.firstLineHeadIndent = blockIndent
        textStorage.addAttribute(.paragraphStyle, value: indented, range: span.range)

        // Spacing goes on the outermost lines only, so it separates the block
        // from its surroundings rather than opening the block up internally.
        let firstLine = NSIntersectionRange(
            string.paragraphRange(for: NSRange(location: span.range.location, length: 0)),
            span.range
        )
        let lastIndex = max(span.range.location, span.range.location + span.range.length - 1)
        let lastLine = NSIntersectionRange(
            string.paragraphRange(for: NSRange(location: lastIndex, length: 0)),
            span.range
        )

        // An open block has nothing after it to be separated from, and the
        // empty line the caret sits on is still the block's own — trailing
        // spacing there would open a gap through the middle of it.
        let wantsClosingSpace = span.isClosed

        if firstLine == lastLine {
            let style = indented.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacingBefore = blockSpacing
            if wantsClosingSpace { style.paragraphSpacing = blockSpacing }
            if firstLine.length > 0 {
                textStorage.addAttribute(.paragraphStyle, value: style, range: firstLine)
            }
            return
        }

        if firstLine.length > 0 {
            let opening = indented.mutableCopy() as! NSMutableParagraphStyle
            opening.paragraphSpacingBefore = blockSpacing
            textStorage.addAttribute(.paragraphStyle, value: opening, range: firstLine)
        }
        if wantsClosingSpace, lastLine.length > 0 {
            let closing = indented.mutableCopy() as! NSMutableParagraphStyle
            closing.paragraphSpacing = blockSpacing
            textStorage.addAttribute(.paragraphStyle, value: closing, range: lastLine)
        }
    }

    /// Where a block's background belongs, one rect per line, in the text
    /// view's own coordinates.
    ///
    /// Separate from the drawing so the geometry can be checked without a
    /// window. Two things it has to get right, both measured rather than
    /// assumed:
    ///
    /// - **Width comes from the line fragment, height from the used rect.** A
    ///   fragment already spans the whole container, which is what makes the
    ///   fill full-width — but it also *includes* the paragraph spacing, so
    ///   taking its height would paint over the gap that sets the block apart.
    /// - **The empty line after a shift-return is not a line fragment.** It has
    ///   no glyphs, so it's the layout manager's extra fragment, and filling
    ///   only the fragments leaves the line you're about to type on unpainted.
    static func blockBackgroundRects(for textView: NSTextView) -> [NSRect] {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return [] }

        let length = (textView.string as NSString).length
        guard length > 0 else { return [] }

        layoutManager.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        var rects: [NSRect] = []

        for span in MessageSyntax.codeSpans(in: textView.string) where span.isBlock {
            let clamped = NSIntersectionRange(span.range, NSRange(location: 0, length: length))
            guard clamped.length > 0 else { continue }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, used, _, _, _ in
                let rect = NSRect(x: fragment.minX, y: used.minY, width: fragment.width, height: used.height)
                rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
            }

            // Only an *open* block owns the empty line below it. A closed one
            // that happens to end at the end of the text does not — that line
            // is the caret's, waiting for whatever comes after the block.
            let extra = layoutManager.extraLineFragmentRect
            if !span.isClosed, !extra.isEmpty {
                rects.append(extra.offsetBy(dx: origin.x, dy: origin.y))
            }
        }

        return rects
    }

    /// Keeps what's about to be typed in step with where the caret is.
    ///
    /// Without this the empty line after a shift-return is laid out in the
    /// prose font, so it's the wrong height and its background is a different
    /// size from the lines above it.
    static func updateTypingAttributes(of textView: NSTextView) {
        let caret = textView.selectedRange().location
        let insideBlock = MessageSyntax.codeSpans(in: textView.string).contains { span in
            // Inclusive at the far end: the caret sitting just past a block is
            // still on the block's own last line.
            span.isBlock
                && caret >= span.range.location
                && caret <= span.range.location + span.range.length
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: insideBlock ? code : body,
            .foregroundColor: NSColor.labelColor,
        ]
        if insideBlock {
            let indented = NSMutableParagraphStyle()
            indented.headIndent = blockIndent
            indented.firstLineHeadIndent = blockIndent
            attributes[.paragraphStyle] = indented
        }
        textView.typingAttributes = attributes
    }
}

/// The text view behind the message field, which fills code blocks itself.
///
/// A `.backgroundColor` attribute only paints behind glyphs, so a block's
/// highlight stopped wherever the typing had reached and the line being typed
/// on had none at all. Drawing it here covers the full width of every line the
/// block occupies, including the empty one waiting for the next word.
final class MessageNSTextView: NSTextView {

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        MessageTextStyle.fill.setFill()
        for block in MessageTextStyle.blockBackgroundRects(for: self) where block.intersects(rect) {
            block.fill()
        }
    }
}
#endif
