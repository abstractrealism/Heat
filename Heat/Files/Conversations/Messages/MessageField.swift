import SwiftUI
import OSLog
import GenKit
import HeatKit

private let logger = Logger(subsystem: "MessageField", category: "App")

struct MessageField: View {
    @Environment(AppState.self) var state
    @Environment(ConversationViewModel.self) var conversationViewModel
    @Environment(\.colorScheme) var colorScheme

    typealias ActionHandler = (String, [String: String]?, Set<String>?) -> Void

    let action: ActionHandler

    @State private var content = ""
    @State private var instructionFile: File? = nil
    @State private var photoPickerModel = PhotoPickerModel()
    @State private var showingPhotoPicker = false
    @State private var inputNaturalHeight: CGFloat = 0

    @FocusState private var isFocused: Bool

    /// Height of the macOS message editor: the mirror text's natural height,
    /// clamped between a single line and a scrolling maximum.
    private var inputHeight: CGFloat {
        min(max(inputNaturalHeight, 40), 240)
    }

    /// What the sizing mirror renders. SwiftUI Text ignores a trailing
    /// newline that NSTextView counts as a line, so pad it with a space to
    /// keep the caret's empty last line visible.
    private var mirrorContent: String {
        if content.isEmpty { return " " }
        return content.hasSuffix("\n") ? content + " " : content
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
                    Button("Attach Image") {
                        showingPhotoPicker = true
                    }
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

                messageInput

                Spacer(minLength: 8)

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
                }
            }
            .padding(4)
            .sheet(item: $instructionFile) { file in
                NavigationStack {
                    MessageInstructions(file: file) { (instructions, context, toolIDs) in
                        action(instructions, context, toolIDs)
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
            .overlay {
                Text(mirrorContent)
                    .font(.body)
                    .padding(.vertical, verticalPadding)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        inputNaturalHeight = height
                    }
            }
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
                TextEditor(text: $content)
                    .font(.body)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .padding(.vertical, verticalPadding)
                    .focused($isFocused)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        // Return submits; Shift+Return inserts a newline.
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        guard !content.isEmpty else { return .handled }
                        Task {
                            do {
                                try await handleSubmit()
                            } catch {
                                print(error)
                            }
                        }
                        return .handled
                    }
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
        action(content, nil, nil)
        clear()
    }

    func handleStop() {
        conversationViewModel.cancel()
    }

    private func clear() {
        content = ""
    }

    // Stop replaces send only while the field is empty: sending a follow-up
    // mid-generation is supported (it supersedes the running turn), so typing
    // must always get the send button back.
    private var showStopGenerating: Bool    { conversationViewModel.isGenerating && content.isEmpty }
    private var showSubmit: Bool            { !content.isEmpty }

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
