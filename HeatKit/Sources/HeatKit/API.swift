import Foundation
import SwiftUI
import SharedKit
import GenKit

@MainActor @Observable
public final class API {
    public static let shared = API()

    private let filesProvider = FilesProvider.shared
    private let logsProvider = LogsProvider.shared

    private var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral

        // The most a reply may go quiet for once it has started, and the
        // floor under everything else. It's an inactivity timeout — reset by
        // every byte — so a streaming answer is safe at any length; what it
        // bounds is a gap. How long a round may take to *start* is decided
        // per round by the chat session (`RoundTimeouts`), a minute for the
        // first token of a turn and five for a round after tool results, and
        // this has to be at least the larger of those or it cuts in first.
        // It did: at 60 a local model reading ten searches' worth of results
        // was killed before its first token.
        cfg.timeoutIntervalForRequest = 300

        // A refused connection has to be reported, not waited out.
        //
        // This was `true`, under a comment saying it kept behaviour similar —
        // it did the opposite. `URLSession.shared` waits for nothing, and
        // waiting means a task that cannot connect does not fail: it sits
        // until connectivity changes, bounded only by
        // `timeoutIntervalForResource`, which defaults to a week. So stopping
        // the Ollama server didn't produce an error anywhere. Nothing was
        // thrown, so nothing was caught, and the conversation showed
        // "Generating…" indefinitely for a request that had been refused in
        // 30 milliseconds. Measured: identical code throws
        // `NSURLErrorCannotConnectToHost` in 0.07s with a default session and
        // was still waiting after 20s with this one.
        //
        // Waiting is for work that can afford to happen later. Someone
        // watching for an answer is owed the news instead.
        cfg.waitsForConnectivity = false

        return URLSession(configuration: cfg)
    }()

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingConfig
        case missingService
        case missingModel

        public var description: String {
            switch self {
            case .missingConfig:
                "Missing config file"
            case .missingService:
                "Missing service ID"
            case .missingModel:
                "Missing model ID"
            }
        }
    }
}

// MARK: - Config

extension API {

    public var config: Config {
        filesProvider.config
    }

    /// Creates a new config and caches it locally. Does NOT upload to a remote server.
    public func configCreate() async throws {
        let config = Config()
        try filesProvider.cacheConfig(config)
    }

    /// Updates the config by replacing the cached data. Does NOT upload to a remote server.
    public func configUpdate(_ config: Config) async throws {
        try filesProvider.cacheConfig(config)
    }
}

// MARK: - Files

extension API {

    public func fileList(flag: String? = nil) -> [File] {
        filesProvider.cachedFileList()
            .filter { $0.flag == flag }
            .sorted { $0.order < $1.order }
    }

    public func fileListTree(fileID: String? = nil) throws -> [FileTree] {
        try filesProvider.cachedFileDirectoryTree(parentID: fileID)
    }

    public func file(_ fileID: String) throws -> File {
        try filesProvider.cachedFileMetadata(fileID)
    }

    public func fileData<T: Decodable>(_ fileID: String, type: T.Type) async throws -> T {
        try filesProvider.cachedFileObject(type, fileID: fileID)
    }

    public func fileData(_ fileID: String) async throws -> Data {
        try filesProvider.cachedFileData(fileID)
    }

    // File Create

    public func fileCreate(_ file: File, object: any Encodable) async throws -> String {
        // Cache and upload file metadata
        try await filesProvider.cacheFileMetadata(file)

        // Cache file object
        if !file.isDirectory {
            try await filesProvider.cacheFileObject(object, fileID: file.id)
        }
        return file.id
    }

    public func fileCreate(_ file: File, data: Data = Data()) async throws -> String {
        // Cache file metadata
        try await filesProvider.cacheFileMetadata(file)

        // Skip caching and uploading of file data if directory
        if file.isDirectory {
            return file.id
        }

        try await filesProvider.cacheFileData(data, fileID: file.id)
        return file.id
    }

    // File Update

    public func fileUpdate(_ file: File) async throws {
        try await filesProvider.cacheFileMetadata(file)
    }

    public func fileUpdate<T: Encodable>(_ fileID: String, object: T) async throws {
        try await filesProvider.cacheFileObject(object, fileID: fileID)
    }

    public func fileUpdate(_ fileID: String, data: Data) async throws {
        try await filesProvider.cacheFileData(data, fileID: fileID)
    }

    public func fileUpdateOrder(_ indexSet: IndexSet, to offset: Int, context: [File]) async throws {
        try await filesProvider.moveFiles(indexSet, to: offset, context: context)
    }

    /// Moves a file into a folder, or back to the top level when `folderID` is
    /// nil. Files only — see `FilesProvider.moveFile`.
    public func fileMove(_ fileID: String, into folderID: String?) async throws {
        try await filesProvider.moveFile(fileID, into: folderID)
    }

    // File Delete

    /// Everything needed to put a deleted file back.
    ///
    /// Held in memory by whoever offers the undo, and dropped when they stop
    /// offering it. Deliberately not a trash folder on disk: a conversation
    /// someone deleted should actually be gone once they've moved on, rather
    /// than lingering somewhere they don't know about and can't see.
    public struct DeletedFile: Sendable {
        public struct Attachment: Sendable {
            public let url: URL
            public let data: Data
        }

        public let file: File

        /// Nil for a directory, which has no contents of its own.
        public let data: Data?

        /// Pictures that were the conversation's own, since deleting it
        /// removes them and restoring it would otherwise leave the message
        /// pointing at a file that no longer exists.
        public let attachments: [Attachment]
    }

    @discardableResult
    public func fileDelete(_ fileID: String) async throws -> DeletedFile {
        // Read before removing: afterwards there is nothing left saying what
        // the file held or which pictures were its.
        let deleted = snapshot(fileID)

        deleteAttachments(of: fileID)
        try await filesProvider.cacheFileDelete(fileID)
        return deleted
    }

    /// Restores a file that `fileDelete` removed.
    public func fileRestore(_ deleted: DeletedFile) async throws {
        for attachment in deleted.attachments {
            do {
                try FileManager.default.createDirectory(
                    at: attachment.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try attachment.data.write(to: attachment.url, options: .atomic)
            } catch {
                // A picture that won't come back shouldn't cost the
                // conversation it belonged to.
                logsProvider.log(error: error)
            }
        }
        try await filesProvider.cacheFileRestore(deleted.file, data: deleted.data)
    }

    private func snapshot(_ fileID: String) -> DeletedFile {
        let file = (try? filesProvider.cachedFileMetadata(fileID))
            ?? File(id: fileID, path: fileID, mimetype: .json)
        let data = file.isDirectory ? nil : try? filesProvider.cachedFileData(fileID)

        let attachments = attachmentURLs(of: fileID).compactMap { url -> DeletedFile.Attachment? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return .init(url: url, data: data)
        }
        return .init(file: file, data: data, attachments: attachments)
    }

    /// Removes the pictures a conversation was carrying.
    ///
    /// Attachments are copied into the app's own storage when they're sent, and
    /// nothing had ever removed them — every picture ever attached stayed on
    /// disk, including from conversations long since deleted, growing quietly
    /// where nobody would look for it.
    ///
    /// Only files in that storage are touched. A message can hold the address
    /// of a picture the app didn't put there, and deleting a conversation is no
    /// reason to go removing something elsewhere on the disk.
    private func deleteAttachments(of fileID: String) {
        for url in attachmentURLs(of: fileID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The pictures a conversation owns — those copied into the app's own
    /// storage, never one that merely lives somewhere else on disk.
    private func attachmentURLs(of fileID: String) -> [URL] {
        guard let conversation = try? filesProvider.cachedFileObject(Conversation.self, fileID: fileID) else {
            return []
        }
        guard let documents = Resource.document("").url?.deletingLastPathComponent() else { return [] }

        var urls: [URL] = []
        for message in conversation.messages {
            for content in message.contents ?? [] {
                guard case .image(let image) = content, isInAppStorage(image.url, under: documents) else {
                    continue
                }
                urls.append(image.url)
            }
        }
        return urls
    }

    /// Whether a file is one of ours to remove.
    ///
    /// Anywhere beneath the app's storage, not only directly in it: attachments
    /// are written alongside the conversations, while generated images go into
    /// a folder of their own, and both are the app's.
    ///
    /// Compared by path component rather than by prefix, so a directory that
    /// merely starts with the same characters isn't mistaken for a child of it.
    private func isInAppStorage(_ url: URL, under documents: URL) -> Bool {
        guard url.isFileURL else { return false }
        let base = documents.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        return target.count > base.count && Array(target.prefix(base.count)) == base
    }
}

// MARK: - Services

extension API {

    public func preferredChatService() throws -> (ChatService, Model) {
        let service = try get(serviceID: config.serviceChatDefault, config: config)
        let model = try get(modelID: service.preferredChatModel, service: service)
        return (try service.chatService(session: session), model)
    }

    public func preferredImageService() throws -> (ImageService, Model) {
        let service = try get(serviceID: config.serviceImageDefault, config: config)
        let model = try get(modelID: service.preferredImageModel, service: service)
        return (try service.imageService(session: session), model)
    }

    public func preferredSummarizationService() throws -> (ChatService, Model) {
        let service = try get(serviceID: config.serviceSummarizationDefault, config: config)
        let model = try get(modelID: service.preferredSummarizationModel, service: service)
        return (try service.summarizationService(session: session), model)
    }

    /// Which service and model an explicit choice actually resolves to.
    ///
    /// Falls back to the configured default whenever the choice can't be
    /// honoured — nothing chosen, or a service or model that has since been
    /// removed, switched off or renamed. A conversation pinned to a model that
    /// no longer exists should keep working rather than refuse to send.
    ///
    /// Separate from `chatService` so a caller can record what it's about to
    /// use, which needs the identifiers rather than the ready-made client.
    public func resolvedChatService(serviceID: String?, modelID: String?) throws -> (Service, Model) {
        if let serviceID, let modelID,
           let service = try? get(serviceID: serviceID, config: config),
           let model = try? get(modelID: modelID, service: service),
           config.isEnabled(service) {
            return (service, model)
        }
        let service = try get(serviceID: config.serviceChatDefault, config: config)
        let model = try get(modelID: service.preferredChatModel, service: service)
        return (service, model)
    }

    /// The chat service for an explicitly chosen model, falling back as above.
    public func chatService(serviceID: String?, modelID: String?) throws -> (ChatService, Model) {
        let (service, model) = try resolvedChatService(serviceID: serviceID, modelID: modelID)
        return (try service.chatService(session: session), model)
    }

    public func get(serviceID: String?, config: Config) throws -> Service {
        guard let service = config.services.first(where: { $0.id == serviceID }) else {
            throw Error.missingService
        }
        return service
    }

    public func get(modelID: String?, service: Service) throws -> Model {
        guard let model = service.models.first(where: { $0.id == modelID }) else {
            throw Error.missingModel
        }
        return model
    }
}

