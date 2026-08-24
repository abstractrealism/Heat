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
        textView.layoutManager?.delegate = context.coordinator

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

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, NSLayoutManagerDelegate {
        var parent: MessageTextView
        weak var textView: NSTextView?

        /// Guards the attribute pass against re-entering itself. Attribute-only
        /// changes don't report as character edits, but the flag makes that a
        /// property of this code rather than of AppKit's.
        private var isStyling = false

        private var lastReportedHeight: CGFloat = -1

        /// Keeps typing and rubbing out in separate undo actions.
        var coalescing = UndoCoalescing()

        /// Backtick ranges currently drawn as nothing.
        private var hiddenDelimiters: [NSRange] = []

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
            refreshHiddenDelimiters()
            reportHeight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            MessageTextStyle.updateTypingAttributes(of: textView)
            refreshHiddenDelimiters()
        }

        /// Suppresses or restores inline backticks as the caret comes and goes.
        ///
        /// Glyphs have to be invalidated for the change to be picked up —
        /// they're generated once and cached, so an attribute pass alone would
        /// leave the old ones on screen.
        func refreshHiddenDelimiters() {
            guard let textView, let layoutManager = textView.layoutManager else { return }

            let updated = MessageTextStyle.hiddenDelimiterRanges(
                in: textView.string,
                caret: textView.selectedRange().location
            )
            guard updated != hiddenDelimiters else { return }
            hiddenDelimiters = updated

            let everything = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.invalidateGlyphs(forCharacterRange: everything, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: everything, actualCharacterRange: nil)
            textView.needsDisplay = true
            reportHeight()
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font aFont: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard !hiddenDelimiters.isEmpty else { return 0 }

            let adjusted = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: glyphRange.length)
            defer { adjusted.deallocate() }

            var changed = false
            for offset in 0..<glyphRange.length {
                let character = charIndexes[offset]
                if hiddenDelimiters.contains(where: { NSLocationInRange(character, $0) }) {
                    // Null glyphs take no space at all, which is the difference
                    // between a hidden backtick and a transparent one.
                    adjusted[offset] = .null
                    changed = true
                } else {
                    adjusted[offset] = props[offset]
                }
            }

            // Returning zero leaves the default generation alone.
            guard changed else { return 0 }

            layoutManager.setGlyphs(
                glyphs,
                properties: adjusted,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange
            )
            return glyphRange.length
        }

        /// Return and the keypad's Enter, which are different keys sending
        /// different characters — carriage return against ETX.
        ///
        /// The standard bindings send both to `insertNewline:`, but a keyboard
        /// or a `DefaultKeyBinding.dict` can route Enter to `insertLineBreak:`
        /// instead, and that used to fall through to AppKit and quietly insert
        /// a line. Both are claimed so the two keys can't disagree.
        ///
        /// Option+Return is deliberately left alone: it maps to
        /// `insertNewlineIgnoringFieldEditor:`, so it stays a way to break a
        /// line without reaching for Shift.
        private static let newlineCommands: Set<Selector> = [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertLineBreak(_:)),
        ]

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard Self.newlineCommands.contains(selector) else { return false }

            // Shift makes a new line, alone sends. Which key it was doesn't
            // matter, so the modifier has to come from the event.
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

        // Fences are dimmed rather than hidden — see hiddenDelimiterRanges for
        // why they can't simply go. Faint enough to stop competing with the
        // code, still legible when the fence carries a language.
        for fence in fenceRanges(of: span, in: string) {
            textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: fence)
        }

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

    /// A block's fence lines: the opening one always, the closing one when
    /// there is one. Trailing newline excluded, there being nothing to colour.
    private static func fenceRanges(of span: MessageSyntax.Span, in string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []

        let opening = string.lineRange(for: NSRange(location: span.range.location, length: 0))
        ranges.append(withoutTerminator(opening, in: string))

        guard span.isClosed else { return ranges }

        let lastIndex = max(span.range.location, span.range.location + span.range.length - 1)
        let closing = string.lineRange(for: NSRange(location: lastIndex, length: 0))
        if closing.location != opening.location {
            ranges.append(withoutTerminator(closing, in: string))
        }
        return ranges
    }

    private static func withoutTerminator(_ range: NSRange, in string: NSString) -> NSRange {
        var trimmed = range
        while trimmed.length > 0 {
            let last = string.character(at: trimmed.location + trimmed.length - 1)
            guard last == 10 || last == 13 else { break }
            trimmed.length -= 1
        }
        return trimmed
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

    /// The delimiters to suppress: an inline span's own backticks, once the
    /// caret has left it.
    ///
    /// Revealed while the caret is inside, because otherwise the only way to
    /// undo the formatting is to backspace over a character that isn't drawn.
    /// The far end counts as inside, so stepping off the end of a span brings
    /// its closing backtick back within reach.
    ///
    /// **Fences are not in here.** Suppressing a whole fence *line* does work —
    /// the line collapses — but its characters are then absorbed into the
    /// preceding fragment, so a block's first line becomes the prose line above
    /// it and the background would be painted across that prose. They're dimmed
    /// instead, which also keeps a language tag readable and keeps every line
    /// the caret can reach visible.
    static func hiddenDelimiterRanges(in text: String, caret: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        for span in MessageSyntax.codeSpans(in: text) where !span.isBlock {
            let start = span.range.location
            let end = start + span.range.length
            guard span.range.length >= 2 else { continue }
            if caret >= start && caret <= end { continue }
            ranges.append(NSRange(location: start, length: 1))
            ranges.append(NSRange(location: end - 1, length: 1))
        }
        return ranges
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
