/*
 ___   ___   ______   ________   _________
/__/\ /__/\ /_____/\ /_______/\ /________/\
\::\ \\  \ \\::::_\/_\::: _  \ \\__.::.__\/
 \::\/_\ .\ \\:\/___/\\::(_)  \ \  \::\ \
  \:: ___::\ \\::___\/_\:: __  \ \  \::\ \
   \: \ \\::\ \\:\____/\\:.\ \  \ \  \::\ \
    \__\/ \::\/ \_____\/ \__\/\__\/   \__\/
 */

import SwiftUI
import OSLog
import HeatKit
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "AppState", category: "App")

@MainActor @Observable
final class AppState {

    static let shared = AppState()

    enum Error: Swift.Error, CustomStringConvertible {
        case restorationError(String)
        case serviceError(String)

        public var description: String {
            switch self {
            case .restorationError(let detail):
                "Restoration error: \(detail)"
            case .serviceError(let detail):
                "Service error: \(detail)"
            }
        }
    }

    var selectedFileID: String? = nil

    /// Whether the confirmation for Reset All Data is up.
    ///
    /// Here rather than on the app itself. State declared on an `App` doesn't
    /// reliably re-evaluate the window's contents when it changes, so setting
    /// it from a menu command left the dialog waiting: nothing happened until
    /// something else invalidated the view — creating a conversation, say — and
    /// then it appeared alongside whatever that was.
    var showingResetConfirmation = false

    // Providers oversee a specific top-level kind of data and provide methods
    // for mutating and storing the data they're responsible for.

    private let filesProvider: FilesProvider
    private let logsProvider: LogsProvider

    // Shortcuts

    var areModelsAvailable: Bool {
        API.shared.config.serviceChatDefault != nil
    }

    var config: Config {
        filesProvider.config
    }

    var files: [File] {
        filesProvider.files
    }

    var fileTree: [FileTree] {
        let files = try? API.shared.fileListTree()
        return files ?? []
    }

    var instructions: [File] {
        filesProvider.files.filter { $0.isInstruction }
    }

    var logs: [Log] {
        logsProvider.logs
    }

    /// What Settings knows about the person using the app, phrased for the
    /// model. Nil when nothing has been filled in, so an empty profile adds
    /// nothing to the prompt.
    ///
    /// GenKit puts this in a `user_context` block on the system prompt. The
    /// fields were being saved and read back by the settings form alone
    /// before this — the model was never told any of it.
    var userProfile: String? {
        let config = config
        var lines: [String] = []
        if let name = config.userName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            lines.append("Name: \(name)")
        }
        if let location = config.userLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            lines.append("Location: \(location)")
        }
        if let biography = config.userBiography?.trimmingCharacters(in: .whitespacesAndNewlines), !biography.isEmpty {
            lines.append("About them: \(biography)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private init() {
        self.filesProvider = .shared
        self.logsProvider = .shared

        logger.info("🍱 \(URL.documentsDirectory.path())")

        Task { try await ready() }
    }

    func restore() async throws {
        try await filesProvider.restore()
        try await logsProvider.restore()
    }

    func ready() async throws {
        async let filesReady: Void = filesProvider.ready()
        async let logsReady: Void = logsProvider.ready()
        _ = try await [filesReady, logsReady]

        // A fresh install has no files on disk yet. Several features — most
        // notably "New Conversation" — expect the default instruction files to
        // exist, so create any that are missing before we're considered ready.
        try await seedDefaultInstructionsIfNeeded()
    }

    /// Creates any missing default instruction files. Safe to call repeatedly:
    /// instructions that already exist are left untouched.
    private func seedDefaultInstructionsIfNeeded() async throws {
        for (id, name, instruction) in Defaults.instructions {
            guard (try? API.shared.file(id)) == nil else { continue }
            _ = try await fileCreateInstruction(id: id, name: name, instruction: instruction)
        }
    }

    @discardableResult
    func ping() async throws -> Bool {
        try await ready()
        return true
    }

    func resetAll() {
        do {
            // Reset providers
            filesProvider.reset()
            logsProvider.reset()

            // Drop cached conversation view models so none survives the reset
            // holding messages that no longer exist on disk.
            ConversationViewModelStore.shared.removeAll()

            // Delete all files
            try FileManager.default.removeItems(at: URL.documentsDirectory)

            // Recreate default instruction files
            Task {
                do {
                    try await seedDefaultInstructionsIfNeeded()
                } catch {
                    log(error: error)
                }
            }
        } catch {
            log(error: error)
        }
    }

    // MARK: - Moving Between Conversations

    /// The conversations the sidebar is showing, top to bottom.
    ///
    /// Ordered and filtered exactly as the list draws it — same sort
    /// preference, same rule about folders — so the keyboard moves through what
    /// is on screen rather than through some second order of its own.
    ///
    /// Conversations only. Documents and folders are in the same list and are
    /// stepped straight past, since a shortcut called Next Conversation that
    /// stops on a folder isn't the one that was asked for.
    var visibleConversationIDs: [String] {
        let files = self.files
        let byID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Read rather than observed: the sort lives in user defaults, written
        // by the list's own @AppStorage. Nothing here needs to redraw when it
        // changes — this is only ever asked at the moment a key is pressed.
        let stored = UserDefaults.standard.string(forKey: FileSortOrder.preferenceKey) ?? ""
        let order = FileSortOrder(rawValue: stored) ?? .recentActivity

        let sorted = FileOrder.sorted(fileTree, files: files, by: order)
        return FileOrder.visibleIDs(in: sorted, files: files)
            .filter { byID[$0]?.isConversation == true }
    }

    /// Whether stepping between conversations can go anywhere.
    ///
    /// Deliberately not `visibleConversationIDs.count > 1`. The menu asks this
    /// on every validation pass, which is far too often to build and sort the
    /// whole file hierarchy for — and it was being asked twice, once per menu
    /// item, on top of the build that stepping itself does.
    ///
    /// It counts conversations rather than *visible* ones, so the commands stay
    /// enabled in the one case where they do nothing: every conversation shut
    /// inside a collapsed folder. A command that no-ops in a corner is a far
    /// cheaper mistake than walking the file tree on every keystroke.
    var canStepConversations: Bool {
        var found = 0
        for file in files where file.isConversation {
            found += 1
            if found > 1 { return true }
        }
        return false
    }

    /// Opens the conversation before or after the open one.
    func step(_ step: FileOrder.Step) {
        guard let destination = FileOrder.step(step, from: selectedFileID, in: visibleConversationIDs) else {
            return
        }
        selectedFileID = destination
    }

    // MARK: - File Handling

    func file<T: Decodable>(_ type: T.Type, fileID: String) throws -> T {
        try filesProvider.cachedFileObject(type, fileID: fileID)
    }

    @discardableResult
    func folderCreate(id: String = .id) async throws -> String {
        let filename = "\(id)"
        let fileID = try await fileCreate(id: id, filename: filename, mimetype: .directory)
        selectedFileID = fileID
        return fileID
    }

    @discardableResult
    func fileCreateConversation(id: String = .id) async throws -> String {
        let instruction = try filesProvider.cachedFileObject(Instruction.self, fileID: Defaults.instructionAssistantID)
        let object = Conversation(
            instructions: instruction.instructions,
            toolIDs: instruction.toolIDs
        )
        let filename = "\(id).conversation"
        let fileID = try await fileCreate(id: id, filename: filename, mimetype: .json, object: object)
        selectedFileID = fileID
        return fileID
    }

    @discardableResult
    func fileCreateDocument(id: String = .id) async throws -> String {
        let object = Document.untitled
        let filename = "\(id).document"
        let fileID = try await fileCreate(id: id, filename: filename, mimetype: .json, object: object)
        selectedFileID = fileID
        return fileID
    }

    func fileCreateInstruction(id: String = .id, name: String, instruction: Instruction) async throws -> String {
        let object = instruction
        let filename = "\(id).instruction"
        let fileID = try await fileCreate(id: id, filename: filename, path: ".app/instructions/\(filename)", name: name, mimetype: .json, object: object)
        return fileID
    }

    func fileUpdate(_ object: any Encodable, fileID: String) async throws {
        try await filesProvider.cacheFileObject(object, fileID: fileID)
    }

    private func fileCreate(id: String, filename: String, path: String? = nil, name: String? = nil, mimetype: UTType, object: any Encodable) async throws -> String {
        let directory = try currentFilePath()
        let path = path ?? directory?.appending(path: filename).path ?? filename
        let file = File(id: id, path: path, name: name, mimetype: mimetype)
        return try await API.shared.fileCreate(file, object: object)
    }

    private func fileCreate(id: String, filename: String, path: String? = nil, name: String? = nil, mimetype: UTType) async throws -> String {
        let directory = try currentFilePath()
        let path = path ?? directory?.appending(path: filename).path ?? filename
        let file = File(id: id, path: path, name: name, mimetype: mimetype)
        return try await API.shared.fileCreate(file)
    }

    private func currentFilePath() throws -> URL? {
        guard let fileID = selectedFileID, let file = try? API.shared.file(fileID) else {
            return nil
        }
        if file.isDirectory {
            return URL(string: file.path)
        }
        guard let parentFilePath = URL(string: file.path)?.deletingLastPathComponent().path else {
            return nil
        }
        guard parentFilePath != "." else {
            return nil
        }
        return URL(string: parentFilePath)
    }

    // MARK: - Logging

    func log(error: Swift.Error) {
        logsProvider.log(error: error)
    }

    func logsReset() {
        logsProvider.reset()
    }
}
