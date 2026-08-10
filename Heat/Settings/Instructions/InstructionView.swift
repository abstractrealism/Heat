import SwiftUI
import HeatKit

struct InstructionsView: View {
    @Environment(AppState.self) var state

    @State var selection: String?

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
            .overlay(alignment: .bottom) {
                Button {
                    handleCreate()
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(.linearGradient(colors: [Color(hex: "#FAFAFA"), Color(hex: "#F5F5F5")], startPoint: .top, endPoint: .bottom))
                    .padding(1)
                }
                .buttonStyle(.plain)
                .overlay {
                    Rectangle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                }
            }

            Group {
                InstructionForm(selection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading)
            .layoutPriority(1)
        }
        #else
        List {
            ForEach(state.instructions) { file in
                NavigationLink(file.name ?? "Untitled") {
                    InstructionForm(file.id)
                        .id(file.id)
                }
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
        #endif
    }

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
}
