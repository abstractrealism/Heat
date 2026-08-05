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
    @State private var containerWidth: CGFloat? = nil

    @FocusState private var isFocused: Bool

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

                TextField("Message", text: $content, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.vertical, verticalPadding)
                    // Give the field an explicit width so the text always wraps
                    // inside it. On macOS a vertical-axis TextField can otherwise
                    // wrap at its own intrinsic width and run beneath the send
                    // button regardless of the width it is offered.
                    .frame(width: fieldWidth, alignment: .leading)
                    .frame(minHeight: minHeight, alignment: .leading)
                    .focused($isFocused)
                    #if os(macOS)
                    .onSubmit {
                        Task {
                            do {
                                try await handleSubmit()
                            } catch {
                                print(error)
                            }
                        }
                    }
                    #endif

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
            // Stay flexible even though the text field has a fixed width:
            // without a zero minWidth here the rigid field sets a floor on the
            // window's minimum size, so the window can grow but never shrink.
            // With it, the window can compress; the measurement below then
            // updates and the field re-sizes to fit.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
    }

    /// Explicit width for the text field: the measured container width minus
    /// the inline (+) button, the send/stop button, spacing, and padding.
    /// `nil` until the first layout pass has been measured.
    private var fieldWidth: CGFloat? {
        guard let containerWidth else { return nil }
        return max(50, containerWidth - 8 - inlineButtonSize.width - 8 - primaryButtonSize.width)
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

    private var showStopGenerating: Bool    { false } // TODO: Fix this
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
