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
                                Task { do { try await state.fileCreateConversation() } catch { state.log(error: error) } }
                            }
                            Button("Create New Document") {
                                Task { do { try await state.fileCreateDocument() } catch { state.log(error: error) } }
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
                            Task { do { try await state.fileCreateConversation() } catch { state.log(error: error) } }
                        }
                        Button("New Document") {
                            Task { do { try await state.fileCreateDocument() } catch { state.log(error: error) } }
                        }
                        Button("New Folder") {
                            Task { do { try await state.folderCreate() } catch { state.log(error: error) } }
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
            .confirmationDialog(
                "Delete everything in Heat?",
                isPresented: Binding(
                    get: { state.showingResetConfirmation },
                    set: { state.showingResetConfirmation = $0 }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    Task { await appReset() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every conversation, document and setting is removed, and the services are returned to their defaults. This cannot be undone.")
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
            // Into the File menu, where macOS puts new documents and where ⌘N
            // is expected. These were in a CommandMenu named after the app,
            // which builds a second top-level menu rather than adding to the
            // app's own — so the menu bar read Heat, Edit, View, Heat.
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    Task { do { try await state.fileCreateConversation() } catch { state.log(error: error) } }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Document") {
                    Task { do { try await state.fileCreateDocument() } catch { state.log(error: error) } }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Folder") {
                    Task { do { try await state.folderCreate() } catch { state.log(error: error) } }
                }
            }

            // Beside Settings, this being a thing you do to the app rather
            // than to a file.
            CommandGroup(after: .appSettings) {
                Divider()
                Button("Reset All Data…") {
                    state.showingResetConfirmation = true
                }
            }
        }

        Settings {
            PreferencesView()
                // A floor and no ceiling, but deliberately no ideal: naming
                // one pinned the window to that height instead of letting it
                // take the size its content asked for, which made a pane that
                // was already too tall shorter still.
                .frame(
                    minWidth: 600, maxWidth: .infinity,
                    minHeight: 552, maxHeight: .infinity
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
