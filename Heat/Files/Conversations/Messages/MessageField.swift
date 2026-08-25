import SwiftUI
import OSLog
import GenKit
import HeatKit

private let logger = Logger(subsystem: "MessageField", category: "App")

struct MessageField: View {
    @Environment(AppState.self) var state
    @Environment(ConversationViewModel.self) var conversationViewModel
    @Environment(\.colorScheme) var colorScheme

    typealias ActionHandler = (String, [URL], [String: String]?, Set<String>?) -> Void

    let action: ActionHandler

    @State private var content = ""
    @State private var instructionFile: File? = nil
    @State private var photoPickerModel = PhotoPickerModel()
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var inputNaturalHeight: CGFloat = 0

    @FocusState private var isFocused: Bool

    /// macOS asks for the keyboard through the editor rather than `@FocusState`,
    /// which can't reach into an `NSViewRepresentable`.
    @State private var focusRequest = false

    /// Height of the macOS message editor: what the text itself needs plus the
    /// field's padding, clamped between a single line and a scrolling maximum.
    ///
    /// The natural height is now measured by the editor rather than by an
    /// invisible mirror `Text`. A mirror is only right while both text engines
    /// lay out identically, and code spans in a monospaced font is precisely
    /// when they stop agreeing about where a line wraps.
    private var inputHeight: CGFloat {
        min(max(inputNaturalHeight + verticalPadding * 2, 40), 240)
    }

    init(action: @escaping ActionHandler) {
        self.action = action
    }

    var body: some View {
        VStack(spacing: 0) {
            if !photoPickerModel.selections.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom) {
                        ForEach(photoPickerModel.selections) { selected in
                            MessageFieldPhoto(id: selected.id, image: selected.photo)
                                .environment(photoPickerModel)
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }

            Divider()
            HStack(alignment: .bottom, spacing: 0) {
                Menu {
                    // Both, rather than one or the other. A picture worth
                    // asking about is as likely to be a file on disk — a
                    // screenshot, something downloaded — as it is to be in the
                    // photo library.
                    Group {
                        Button("Attach Photo from Photos…") {
                            showingPhotoPicker = true
                        }
                        Button(fileImportLabel) {
                            showingFileImporter = true
                        }
                    }
                    // Offered only where they can be looked at. Unknown counts
                    // as yes, as elsewhere — only Ollama reports this, so
                    // gating on a missing answer would withdraw attachments
                    // from every hosted service.
                    .disabled(!modelCanSeeImages)
                    .help(modelCanSeeImages
                          ? "Attach a picture to your message"
                          : "\(conversationViewModel.selectedModelName) can't read images. Pick a model that supports them to attach one.")
                    Divider()
                    ForEach(state.instructions) { file in
                        if let instruction = try? state.file(Instruction.self, fileID: file.id), instruction.kind == .template {
                            Button(file.name ?? "Untitled") {
                                instructionFile = file
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                        .tint(.primary)
                        .frame(width: inlineButtonSize.width, height: inlineButtonSize.height)
                }
                .buttonStyle(.plain)
                .help("Attach an image or use a saved prompt")

                messageInput

                Spacer(minLength: 8)

                // Only while the model is still reasoning. Once it has started
                // answering there is nothing to cut short, and the button would
                // be offering to restart a reply already arriving.
                if conversationViewModel.canAnswerNow {
                    Button(action: conversationViewModel.answerNow) {
                        // Named as well as drawn. The glyph reads as "skip" to
                        // anyone who has met it before, and as nothing to
                        // anyone who hasn't — and this is the one control here
                        // that discards work, which is a poor thing to guess at.
                        HStack(spacing: 5) {
                            Image(systemName: "forward.end.fill")
                            Text("Skip Thinking")
                        }
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: primaryButtonSize.height)
                        .background(.quaternary, in: .rect(cornerRadius: 8))
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    // Sized to its label rather than to what's left over: the
                    // field beside it takes all the width it can get, and would
                    // otherwise squeeze the words to an ellipsis.
                    .fixedSize()
                    .padding(.trailing, 4)
                    .help("Stop reasoning and answer from what it has worked out so far. The reasoning is kept.")
                }

                if showStopGenerating {
                    Button(action: handleStop) {
                        Image(systemName: "stop.fill")
                            .fontWeight(.medium)
                            .frame(width: primaryButtonSize.width, height: primaryButtonSize.height)
                            .foregroundStyle(.white)
                            .background(.tint, in: .rect(cornerRadius: 8))
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else if showSubmit {
                    Button {
                        Task {
                            do {
                                try await handleSubmit()
                            } catch {
                                print(error)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .fontWeight(.medium)
                            .frame(width: primaryButtonSize.width, height: primaryButtonSize.height)
                            .foregroundStyle(.white)
                            .background(.tint, in: .rect(cornerRadius: 8))
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .help("Send message")
                }
            }
            .padding(4)
            .sheet(item: $instructionFile) { file in
                NavigationStack {
                    MessageInstructions(file: file) { (instructions, context, toolIDs) in
                        // Anything attached goes with a template too. Picking a
                        // saved prompt while a picture is waiting shouldn't
                        // silently drop the picture.
                        action(instructions, attachedImages(), context, toolIDs)
                        clear()
                    }
                }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $photoPickerModel.items,
                maxSelectionCount: 3,
                selectionBehavior: .ordered,
                matching: .images,
                photoLibrary: .shared()
            )
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    // Capped to match the photo picker, so the two ways in
                    // don't disagree about how much can be attached.
                    photoPickerModel.addFiles(Array(urls.prefix(3)))
                case .failure(let error):
                    conversationViewModel.error = "Couldn't open that picture: \(error.localizedDescription)"
                }
            }

            MessageFieldControls()
                .padding(.trailing, 8)
                .padding(.bottom, 6)
        }
        .task(id: conversationViewModel.file.id) {
            // A new conversation opens ready to type into. Existing ones are
            // left alone so opening one to read doesn't steal the keyboard.
            guard conversationViewModel.messages.isEmpty else { return }
            #if os(macOS)
            focusRequest = true
            #else
            isFocused = true
            #endif
        }
    }

    /// The multiline message input.
    ///
    /// On macOS this is a TextEditor (NSTextView) rather than a vertical-axis
    /// TextField: the NSTextField-backed multiline field wraps at a stale
    /// intrinsic width in this layout (observed on macOS 15 Sequoia), running
    /// beneath the send button and ignoring later width changes, while
    /// NSTextView tracks its container width reliably. The invisible Text
    /// mirror gives the editor its auto-growing height, since TextEditor does
    /// not size itself to its content.
    @ViewBuilder
    private var messageInput: some View {
        #if os(macOS)
        // The layout height comes from the invisible mirror Text (measured at
        // its natural, uncapped size via fixedSize), clamped between one line
        // and a maximum. The editor and placeholder are overlays, so nothing
        // greedy participates in layout.
        // The mirror, placeholder, and editor share the same font, and the
        // mirror/placeholder are inset by NSTextView's 5pt line-fragment
        // padding, so both text engines wrap at the same width and the field
        // grows right when the editor's own text wraps.
        Color.clear
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if content.isEmpty {
                    Text("Message")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, verticalPadding)
                        .padding(.horizontal, 5)
                }
            }
            .overlay {
                MessageTextView(
                    text: $content,
                    focusRequest: $focusRequest,
                    onSubmit: {
                        Task {
                            do {
                                try await handleSubmit()
                            } catch {
                                conversationViewModel.error = "Couldn't send that: \(error.localizedDescription)"
                            }
                        }
                    },
                    onHeightChange: { inputNaturalHeight = $0 }
                )
                .padding(.vertical, verticalPadding)
            }
        #else
        TextField("Message", text: $content, axis: .vertical)
            .textFieldStyle(.plain)
            .padding(.vertical, verticalPadding)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .focused($isFocused)
        #endif
    }

    func handleSubmit() async throws {
        action(content, attachedImages(), nil, nil)
        clear()
    }

    /// Writes anything attached to disk and returns where it went.
    ///
    /// Written here, at the point of sending, rather than when picked: a
    /// picture chosen and then removed shouldn't leave a file behind.
    ///
    /// A failure is reported rather than swallowed. Silently sending the text
    /// without the picture is the worst outcome — the model answers as though
    /// nothing was attached, and there's no way to tell that from a model that
    /// looked and didn't understand.
    private func attachedImages() -> [URL] {
        guard !photoPickerModel.selections.isEmpty else { return [] }
        do {
            let urls = try photoPickerModel.writeAll()
            ChatDebug.log("→ attaching \(urls.count) image(s): \(urls.map(\.lastPathComponent).joined(separator: ", "))")
            return urls
        } catch {
            ChatDebug.log("→ attachment failed, sending without it: \(error)")
            conversationViewModel.error = "Couldn't attach the picture: \(error.localizedDescription)"
            return []
        }
    }

    func handleStop() {
        conversationViewModel.cancel()
    }

    private func clear() {
        content = ""
        photoPickerModel.removeAll()
    }

    /// Named for the app that opens, since that's what somebody is looking for.
    private var fileImportLabel: String {
        #if os(macOS)
        "Attach Photo from Finder…"
        #else
        "Attach Photo from Files…"
        #endif
    }

    /// Whether the conversation's model can read a picture at all.
    private var modelCanSeeImages: Bool {
        conversationViewModel.selectedModel?.supports(.vision) ?? true
    }

    /// Whether there's anything to send. A picture on its own counts — asking
    /// what something is, with no words, is a reasonable thing to want, and
    /// the send button was hidden until text was typed.
    private var hasContent: Bool { !content.isEmpty || !photoPickerModel.selections.isEmpty }

    // Stop replaces send only while the field is empty: sending a follow-up
    // mid-generation is supported (it supersedes the running turn), so typing
    // must always get the send button back.
    private var showStopGenerating: Bool    { conversationViewModel.isGenerating && !hasContent }
    private var showSubmit: Bool            { hasContent }

    #if os(macOS)
    private var minHeight: CGFloat = 0
    private var verticalPadding: CGFloat = 9
    private var inlineButtonSize = CGSize(width: 34, height: 34)
    private var primaryButtonSize = CGSize(width: 30, height: 30)
    #else
    private var minHeight: CGFloat = 44
    private var verticalPadding: CGFloat = 11
    private var inlineButtonSize = CGSize(width: 44, height: 44)
    private var primaryButtonSize = CGSize(width: 40, height: 40)
    #endif
}

struct MessageFieldPhoto: View {
    @Environment(PhotoPickerModel.self) var imagePickerViewModel

    let id: String
    #if os(macOS)
    let image: NSImage?
    #else
    let image: UIImage?
    #endif

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image {
                #if os(macOS)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(.rect(cornerRadius: 10))
                #else
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(.rect(cornerRadius: 10))
                #endif
            } else {
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 100, height: 100)
                    .clipShape(.rect(cornerRadius: 10))
            }

            Button {
                imagePickerViewModel.remove(id: id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.regularMaterial)
            .shadow(color: .primary.opacity(0.25), radius: 5)
        }
    }
}
