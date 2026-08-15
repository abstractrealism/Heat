import SwiftUI
import OSLog
import CoreServices
import EventKit
import SharedKit
import HeatKit

private let logger = Logger(subsystem: "MainApp", category: "App")

@main
struct MainApp: App {
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var state = AppState.shared

    @State private var showingError = false
    @State private var error: (any CustomStringConvertible)? = nil

    @AppStorage(AppAppearance.preferenceKey) private var appearance: AppAppearance = .system

    var body: some Scene {
        Window("Heat", id: "heat") {
            NavigationSplitView {
                FileList(selected: $state.selectedFileID)
                    .frame(minWidth: 200)
                    .navigationSplitViewStyle(.prominentDetail)
            } detail: {
                if let fileID = state.selectedFileID {
                    FileDetail(fileID: fileID)
                } else {
                    ContentUnavailableView {
                        Label("No file selected", systemImage: "doc.plaintext")
                    } description: {
                        VStack(spacing: 16) {
                            Text("Selected files will be editable here.")

                            Button("Create New Conversation") {
                                Task { try await state.fileCreateConversation() }
                            }
                            Button("Create New Document") {
                                Task { try await state.fileCreateDocument() }
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .containerBackground(.background, for: .window)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("New Conversation") {
                            Task { try await state.fileCreateConversation() }
                        }
                        Button("New Document") {
                            Task { try await state.fileCreateDocument() }
                        }
                        Button("New Folder") {
                            Task { try await state.folderCreate() }
                        }
                    } label: {
                        Label("New File", systemImage: "plus")
                    }
                    .menuIndicator(.hidden)
                    .help("New conversation, document, or folder")
                }
            }
            .alert("Error", isPresented: $showingError, presenting: error) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.description)
            }
            .onAppear {
                Task { await appActive() }
            }
            .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 600, height: 700)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.presented)
        .environment(state)
        .commands {
            CommandMenu("Heat") {
                Button("New Conversation") {
                    Task { try await state.fileCreateConversation() }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Document") {
                    Task { try await state.fileCreateDocument() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Folder") {
                    Task { try await state.folderCreate() }
                }

                Divider()

                Button("Reset All Data") {
                    Task { await appReset() }
                }
            }
        }

        Settings {
            PreferencesView()
                // An ideal size as well as a floor. Without one the window
                // opens at the smallest size that fits, which is how the
                // longest pane ended up with its last control below the
                // bottom edge and no way to reach it.
                .frame(
                    minWidth: 600, idealWidth: 760, maxWidth: .infinity,
                    minHeight: 420, idealHeight: 640, maxHeight: .infinity
                )
                .preferredColorScheme(appearance.colorScheme)
        }
        // A Settings window sizes itself to its content and stays that way
        // unless told otherwise, so a pane that outgrows it can't be scrolled
        // or dragged open. contentMinSize keeps the floor above and lets it be
        // made as large as wanted.
        .windowResizability(.contentMinSize)
        .environment(state)
    }

    func appActive() async {
        do {
            try await state.ready()
        } catch {
            state.log(error: error)
        }
    }

    func appReset() async {
        state.resetAll()
        await appActive()
    }
}
