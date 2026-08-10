import SwiftUI
import OSLog
import SharedKit
import GenKit
import HeatKit

/// How long editing pauses before an edit is written. Long enough that typing
/// doesn't write on every keystroke, short enough that a save is never far
/// behind what's on screen. Whatever is still pending gets flushed when the
/// form goes away, so nothing rests on that timer completing.
private let autosaveDelay: Duration = .milliseconds(400)

struct InstructionForm: View {
    let fileID: String?

    @State private var selectedTab: Tab = .profile

    enum Tab: String, CaseIterable {
        case profile = "Profile"
        case instructions = "Instructions"
        case tools = "Tools"
    }

    init(_ fileID: String? = nil) {
        self.fileID = fileID
    }

    var body: some View {
        if let fileID {
            editor(fileID)
        } else {
            ContentUnavailableView {
                Label("No instruction selected", systemImage: "text.book.closed")
            } description: {
                Text("Pick one from the list, or use + to add a template.")
            }
        }
    }

    @ViewBuilder
    private func editor(_ fileID: String) -> some View {
        #if os(macOS)
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabContent(for: tab, fileID: fileID)
                    .padding()
                    .id(fileID)
                    .tag(tab)
                    .tabItem {
                        Text(tab.rawValue)
                    }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .navigationTitle("Instruction")
        #else
        VStack {
            Picker("Select item", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            tabContent(for: selectedTab, fileID: fileID)
        }
        #endif
    }

    @ViewBuilder
    private func tabContent(for tab: Tab, fileID: String) -> some View {
        VStack(alignment: .leading) {
            switch tab {
            case .profile:
                InstructionProfileForm(fileID)
            case .instructions:
                InstructionTextForm(fileID)
            case .tools:
                InstructionToolsForm(fileID)
            }
        }
    }
}

struct InstructionProfileForm: View {
    @Environment(AppState.self) var state

    let fileID: String

    @State private var name = ""
    @State private var kind = Instruction.Kind.template
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?

    init(_ fileID: String) {
        self.fileID = fileID
    }

    var body: some View {
        Form {
            TextField("ID", text: .constant(fileID))
                .disabled(true)

            TextField("Name", text: $name)

            Picker("Kind", selection: $kind) {
                ForEach(Instruction.Kind.allCases, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: name) { _, _ in scheduleSave() }
        .onChange(of: kind) { _, _ in scheduleSave() }
        .onDisappear { flush() }
    }

    private func load() {
        do {
            kind = try state.file(Instruction.self, fileID: fileID).kind
            name = try API.shared.file(fileID).name ?? ""
            isLoaded = true
        } catch {
            state.log(error: error)
        }
    }

    private func scheduleSave() {
        guard isLoaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func flush() {
        saveTask?.cancel()
        Task { await save() }
    }

    private func save() async {
        guard isLoaded else { return }
        do {
            var instruction = try state.file(Instruction.self, fileID: fileID)
            instruction.kind = kind
            try await API.shared.fileUpdate(fileID, object: instruction)

            var file = try API.shared.file(fileID)
            file.name = name.isEmpty ? nil : name
            try await API.shared.fileUpdate(file)
        } catch {
            state.log(error: error)
        }
    }
}

struct InstructionToolsForm: View {
    @Environment(AppState.self) var state

    let fileID: String

    @State private var toolIDs: Set<String> = []
    @State private var selection: String? = nil
    @State private var newToolID = ""
    @State private var isAddingTool = false
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?

    init(_ fileID: String) {
        self.fileID = fileID
    }

    var body: some View {
        VStack {
            List(selection: $selection) {
                ForEach(Array(toolIDs.sorted(by: <)), id: \.self) { toolID in
                    Text(toolID)
                        .tag(toolID)
                }
                if isAddingTool {
                    TextField("Tool ID", text: $newToolID)
                        .onSubmit {
                            handleInsertTool()
                        }
                }
            }
            #if os(macOS)
            .listStyle(.bordered)
            #endif

            HStack {
                ControlGroup {
                    Button("Decrease", systemImage: "minus") {
                        if let selection {
                            toolIDs.remove(selection)
                        }
                    }
                    Button("Increase", systemImage: "plus") {
                        if !newToolID.isEmpty {
                            handleInsertTool()
                        }
                        isAddingTool = true
                    }
                }
                .frame(width: 60)
                Spacer()
                Text("Available: \(Toolbox.allCases.map(\.name).sorted().joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { load() }
        .onChange(of: toolIDs) { _, _ in scheduleSave() }
        .onDisappear {
            // Commit a tool that was typed but never submitted.
            handleInsertTool()
            flush()
        }
    }

    private func load() {
        do {
            toolIDs = try state.file(Instruction.self, fileID: fileID).toolIDs
            isLoaded = true
        } catch {
            state.log(error: error)
        }
    }

    private func scheduleSave() {
        guard isLoaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func flush() {
        saveTask?.cancel()
        let toolIDs = toolIDs
        Task { await save(toolIDs) }
    }

    private func save() async {
        await save(toolIDs)
    }

    private func save(_ toolIDs: Set<String>) async {
        guard isLoaded else { return }
        do {
            var instruction = try state.file(Instruction.self, fileID: fileID)
            instruction.toolIDs = toolIDs
            try await API.shared.fileUpdate(fileID, object: instruction)
        } catch {
            state.log(error: error)
        }
    }

    private func handleInsertTool() {
        guard !newToolID.isEmpty else {
            isAddingTool = false
            return
        }
        toolIDs.insert(newToolID.trimmingCharacters(in: .whitespacesAndNewlines))
        newToolID = ""
        isAddingTool = false
    }
}

struct InstructionTextForm: View {
    @Environment(AppState.self) var state

    let fileID: String

    @State private var instructions: String = ""
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?

    init(_ fileID: String) {
        self.fileID = fileID
    }

    var body: some View {
        VStack {
            TextEditor(text: $instructions)
                .overlay {
                    Rectangle()
                        .fill(.clear)
                        .stroke(.separator, lineWidth: 1)
                }
        }
        .onAppear { load() }
        .onChange(of: instructions) { _, _ in scheduleSave() }
        .onDisappear { flush() }
    }

    private func load() {
        do {
            instructions = try state.file(Instruction.self, fileID: fileID).instructions
            isLoaded = true
        } catch {
            state.log(error: error)
        }
    }

    private func scheduleSave() {
        guard isLoaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func flush() {
        saveTask?.cancel()
        Task { await save() }
    }

    private func save() async {
        guard isLoaded else { return }
        do {
            var instruction = try state.file(Instruction.self, fileID: fileID)
            instruction.instructions = instructions
            try await API.shared.fileUpdate(fileID, object: instruction)
        } catch {
            state.log(error: error)
        }
    }
}

struct InstructionTool: View {
    @Environment(\.dismiss) var dismiss

    @State var text: String = ""

    let action: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            TextField("Name", text: $text)
                .focused($isFocused)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            handleSubmit()
                        } label: {
                            Text("Done")
                        }
                    }
                }
        }
        .onAppear {
            isFocused = true
        }
    }

    func handleSubmit() {
        action(text.trimmingCharacters(in: .whitespacesAndNewlines))
        text = ""
        dismiss()
    }
}
