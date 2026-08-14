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
        cfg.timeoutIntervalForRequest = 60       // keep it conservative
        cfg.waitsForConnectivity = true          // keeps behaviour similar
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

    // File Delete

    public func fileDelete(_ fileID: String) async throws {
        try await filesProvider.cacheFileDelete(fileID)
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

