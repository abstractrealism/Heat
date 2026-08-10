import SwiftUI
import HeatKit

struct InstructionsView: View {
    @Environment(AppState.self) var state

    @State var selection: String?
    @State private var pendingDeletion: String?

    /// The app's own prompts: the system prompt behind every new conversation,
    /// and the task prompts behind titles, suggestions and web search. Removing
    /// one breaks whatever reads it until the next launch seeds it again, so
    /// they aren't deletable here — only instructions you add are.
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

    var body: some View {
        #if os(macOS)
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
    private var controlBar: some View {
        HStack(spacing: 4) {
            Button {
                handleCreate()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Add a template")

            Button {
                pendingDeletion = selection
            } label: {
                Image(systemName: "minus")
                    .frame(width: 20)
                    .contentShape(.rect)
                    .opacity(isDeletable(selection) ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .disabled(!isDeletable(selection))
            .help("Delete the selected instruction. The app's own prompts can't be deleted.")

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
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
