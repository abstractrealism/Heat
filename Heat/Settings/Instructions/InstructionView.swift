import SwiftUI
import HeatKit

struct InstructionsView: View {
    @Environment(AppState.self) var state

    @State var selection: String?
    @State private var pendingDeletion: String?

    /// The app's own prompts: the system prompt behind every new conversation,
    /// and the task prompts behind titles, suggestions and compaction.
    /// Removing one breaks whatever reads it until the next launch seeds it
    /// again, so they aren't deletable here — only instructions you add are.
    ///
    /// Derived from the seed list rather than written out, which means a
    /// prompt retired from that list stops being protected and becomes
    /// deletable. That is what should happen: Web Search was retired when its
    /// text moved into the tool's own description, and the file left behind
    /// on existing installs is exactly the thing somebody should be able to
    /// get rid of.
    private var builtInIDs: Set<String> {
        Set(Defaults.instructions.map(\.id))
    }

    private func isDeletable(_ fileID: String?) -> Bool {
        guard let fileID else { return false }
        return !builtInIDs.contains(fileID)
    }

    private func name(of fileID: String) -> String {
        state.instructions.first { $0.id == fileID }?.name ?? "Untitled"
    }

    /// What this screen is for, above the whole pane rather than tucked into
    /// one tab of the editor — it explains the list as much as the form.
    private var explanation: some View {
        Text("Instructions are prompt text Heat keeps and reuses. **Assistant** is the personality every new conversation starts with; **Title**, **Suggestions** and **Web Search** are prompts Heat runs for itself. Anything you add is a **Template**: a reusable prompt you can pick from the message field options menu, instead of typing it again. E.g. a \"Code Review\" template reading *\"Review this code for bugs and edge cases:\"*")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
        explanation
        HSplitView {
            List(selection: $selection) {
                ForEach(state.instructions) { file in
                    Text(file.name ?? "Untitled")
                        .tag(file.id)
                }
            }
            .navigationTitle("Instructions")
            .frame(minWidth: 200, idealWidth: 200, maxWidth: 400)
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.enabled)
            .environment(\.defaultMinListRowHeight, 32)
            .onDeleteCommand {
                guard isDeletable(selection) else { return }
                pendingDeletion = selection
            }
            .overlay(alignment: .bottom) {
                controlBar
            }

            Group {
                InstructionForm(selection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading)
            .layoutPriority(1)
        }
        }
        .confirmationDialog(
            "Delete Instruction",
            isPresented: isConfirmingDeletion,
            presenting: pendingDeletion
        ) { fileID in
            Button("Delete", role: .destructive) { handleDelete(fileID) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { fileID in
            Text("“\(name(of: fileID))” will be deleted. This can't be undone.")
        }
        #else
        List {
            Section { explanation }

            ForEach(state.instructions) { file in
                NavigationLink(file.name ?? "Untitled") {
                    InstructionForm(file.id)
                        .id(file.id)
                }
                .deleteDisabled(builtInIDs.contains(file.id))
            }
            .onDelete { indexSet in
                pendingDeletion = indexSet
                    .map { state.instructions[$0].id }
                    .first { isDeletable($0) }
            }
        }
        .navigationTitle("Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem {
                Button("New Instruction", systemImage: "plus") {
                    handleCreate()
                }
            }
        }
        .confirmationDialog(
            "Delete Instruction",
            isPresented: isConfirmingDeletion,
            presenting: pendingDeletion
        ) { fileID in
            Button("Delete", role: .destructive) { handleDelete(fileID) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { fileID in
            Text("“\(name(of: fileID))” will be deleted. This can't be undone.")
        }
        #endif
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    #if os(macOS)
    /// Clickable area per button. Sized so the bar keeps roughly the height it
    /// had when the glyphs sat directly in it.
    private let buttonSize = CGSize(width: 24, height: 22)

    private var controlBar: some View {
        HStack(spacing: 2) {
            Button {
                handleCreate()
            } label: {
                // The glyph alone is a tiny target — a minus is a few points
                // of horizontal bar — so each button gets an explicit box to
                // click, made hit-testable as a whole by contentShape.
                Image(systemName: "plus")
                    .frame(width: buttonSize.width, height: buttonSize.height)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Add a template")

            Button {
                pendingDeletion = selection
            } label: {
                Image(systemName: "minus")
                    .opacity(isDeletable(selection) ? 1 : 0.3)
                    .frame(width: buttonSize.width, height: buttonSize.height)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isDeletable(selection))
            .help("Delete the selected instruction. The app's own prompts can't be deleted.")

            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(.linearGradient(colors: [Color(hex: "#FAFAFA"), Color(hex: "#F5F5F5")], startPoint: .top, endPoint: .bottom))
        .padding(1)
        .overlay {
            Rectangle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }
    #endif

    /// Creates an instruction and selects it so the editor has something to
    /// work on. The form edits a file in place — it has no draft state of its
    /// own — so the file has to exist before anything can be typed into it.
    ///
    /// New instructions start as templates: that's the kind with no defaults,
    /// and the one this list exists for. The others are the app's own prompts.
    func handleCreate() {
        Task {
            do {
                let fileID = try await state.fileCreateInstruction(
                    name: "Untitled",
                    instruction: .init(kind: .template, instructions: "")
                )
                selection = fileID
            } catch {
                state.log(error: error)
            }
        }
    }

    func handleDelete(_ fileID: String) {
        pendingDeletion = nil
        Task {
            do {
                try await API.shared.fileDelete(fileID)
                if selection == fileID {
                    selection = nil
                }
            } catch {
                state.log(error: error)
            }
        }
    }
}
