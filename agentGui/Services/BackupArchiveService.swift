import Foundation
import SwiftData

@MainActor
final class BackupArchiveService {
    enum BackupError: LocalizedError {
        case incompatibleSchemaVersion(Int)
        case invalidArchiveStructure

        var errorDescription: String? {
            switch self {
            case .incompatibleSchemaVersion(let version):
                return "Backup schema version \(version) is not supported."
            case .invalidArchiveStructure:
                return "Backup archive is missing required files."
            }
        }
    }

    static let currentSchemaVersion = 1

    private let persistenceCoordinator: PersistenceCoordinator

    init(persistenceCoordinator: PersistenceCoordinator = .shared) {
        self.persistenceCoordinator = persistenceCoordinator
    }

    func exportSession(id sessionId: String, from modelContext: ModelContext) throws -> URL {
        let payload = try makePayload(from: modelContext, scope: .singleSession(sessionId))
        let manifest = BackupArchiveManifest(
            schemaVersion: Self.currentSchemaVersion,
            createdAt: Date(),
            scope: .singleSession(sessionId),
            sessionIDs: [sessionId]
        )
        return try writeArchive(manifest: manifest, payload: payload)
    }

    func exportAll(from modelContext: ModelContext) throws -> URL {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let payload = try makePayload(from: modelContext, scope: .allData)
        let manifest = BackupArchiveManifest(
            schemaVersion: Self.currentSchemaVersion,
            createdAt: Date(),
            scope: .allData,
            sessionIDs: sessions.map(\.sessionId).sorted()
        )
        return try writeArchive(manifest: manifest, payload: payload)
    }

    func restore(from archiveURL: URL, into modelContext: ModelContext, dryRun: Bool) throws {
        let manifest = try readManifest(from: archiveURL)
        guard manifest.schemaVersion == Self.currentSchemaVersion else {
            throw BackupError.incompatibleSchemaVersion(manifest.schemaVersion)
        }
        let payload = try readPayload(from: archiveURL)

        guard !payload.sessions.isEmpty || payload.appSettings != nil else {
            throw BackupError.invalidArchiveStructure
        }

        guard !dryRun else { return }

        if let settingsArchive = payload.appSettings {
            let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
            settings.apiKey = settingsArchive.apiKey
            settings.baseURL = settingsArchive.baseURL
            settings.selectedModel = settingsArchive.selectedModel
            settings.themeMode = settingsArchive.themeMode
            settings.workingDirectory = settingsArchive.workingDirectory
        }

        var sessionsById: [String: Session] = [:]
        let existingSessions = try modelContext.fetch(FetchDescriptor<Session>())
        for archive in payload.sessions {
            let session = existingSessions.first(where: { $0.sessionId == archive.sessionId }) ?? Session(sessionId: archive.sessionId, title: archive.title)
            session.title = archive.title
            session.createdAt = archive.createdAt
            session.updatedAt = archive.updatedAt
            session.isActive = archive.isActive
            session.workingDirectory = archive.workingDirectory
            session.planJson = archive.planJson
            if session.modelContext == nil {
                modelContext.insert(session)
            }
            sessionsById[archive.sessionId] = session
        }

        let existingMessages = try modelContext.fetch(FetchDescriptor<Message>())
        var messagesById: [UUID: Message] = [:]
        for archive in payload.messages {
            let message = existingMessages.first(where: { $0.id == archive.id }) ?? Message(direction: archive.direction, contentType: archive.contentType, text: archive.textContent, session: sessionsById[archive.sessionId])
            message.id = archive.id
            message.session = sessionsById[archive.sessionId]
            message.direction = archive.direction
            message.contentType = archive.contentType
            message.textContent = archive.textContent
            message.status = archive.status
            message.sequence = archive.sequence
            message.timestamp = archive.timestamp
            message.errorMessage = archive.errorMessage
            if message.modelContext == nil {
                modelContext.insert(message)
            }
            messagesById[archive.id] = message
        }

        let existingToolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())
        for archive in payload.toolCalls {
            let toolCall = existingToolCalls.first(where: { $0.id == archive.id }) ?? ToolCall(toolCallId: archive.toolCallId, kind: archive.kind, message: archive.messageId.flatMap { messagesById[$0] })
            toolCall.id = archive.id
            toolCall.toolCallId = archive.toolCallId
            toolCall.kind = archive.kind
            toolCall.title = archive.title
            toolCall.status = archive.status
            toolCall.message = archive.messageId.flatMap { messagesById[$0] }
            toolCall.startTime = archive.startTime
            toolCall.endTime = archive.endTime
            if toolCall.modelContext == nil {
                modelContext.insert(toolCall)
            }
        }

        let existingTaskStates = try modelContext.fetch(FetchDescriptor<SessionTaskState>())
        for archive in payload.taskStates {
            let taskState = existingTaskStates.first(where: { $0.sessionId == archive.sessionId }) ?? SessionTaskState(sessionId: archive.sessionId)
            taskState.planJson = archive.planJson
            taskState.todoJson = archive.todoJson
            taskState.verificationJson = archive.verificationJson
            taskState.updatedAt = archive.updatedAt
            if taskState.modelContext == nil {
                modelContext.insert(taskState)
            }
        }

        try persistenceCoordinator.save(
            modelContext,
            domain: .backupRestore,
            userMessage: "备份恢复未成功保存"
        )
    }

    private func makePayload(from modelContext: ModelContext, scope: BackupArchiveScope) throws -> BackupArchivePayload {
        let sessionIDs: Set<String>
        switch scope {
        case .allData:
            sessionIDs = Set(try modelContext.fetch(FetchDescriptor<Session>()).map(\.sessionId))
        case .singleSession(let sessionId):
            sessionIDs = [sessionId]
        }

        let settings = try modelContext.fetch(FetchDescriptor<AppSettings>()).first.map {
            AppSettingsArchive(
                apiKey: $0.apiKey,
                baseURL: $0.baseURL,
                selectedModel: $0.selectedModel,
                themeMode: $0.themeMode,
                workingDirectory: $0.workingDirectory
            )
        }

        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
            .filter { sessionIDs.contains($0.sessionId) }
            .map {
                SessionArchive(
                    sessionId: $0.sessionId,
                    title: $0.title,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    isActive: $0.isActive,
                    workingDirectory: $0.workingDirectory,
                    planJson: $0.planJson
                )
            }

        let messages = try modelContext.fetch(FetchDescriptor<Message>())
            .compactMap { message -> MessageArchive? in
                guard let sessionId = message.session?.sessionId, sessionIDs.contains(sessionId) else { return nil }
                return MessageArchive(
                    id: message.id,
                    sessionId: sessionId,
                    direction: message.direction,
                    contentType: message.contentType,
                    textContent: message.textContent,
                    status: message.status,
                    sequence: message.sequence,
                    timestamp: message.timestamp,
                    errorMessage: message.errorMessage
                )
            }

        let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())
            .compactMap { toolCall -> ToolCallArchive? in
                guard let sessionId = toolCall.message?.session?.sessionId, sessionIDs.contains(sessionId) else { return nil }
                return ToolCallArchive(
                    id: toolCall.id,
                    toolCallId: toolCall.toolCallId,
                    kind: toolCall.kind,
                    title: toolCall.title,
                    status: toolCall.status,
                    messageId: toolCall.message?.id,
                    startTime: toolCall.startTime,
                    endTime: toolCall.endTime
                )
            }

        let taskStates = try modelContext.fetch(FetchDescriptor<SessionTaskState>())
            .filter { sessionIDs.contains($0.sessionId) }
            .map {
                SessionTaskStateArchive(
                    sessionId: $0.sessionId,
                    planJson: $0.planJson,
                    todoJson: $0.todoJson,
                    verificationJson: $0.verificationJson,
                    updatedAt: $0.updatedAt
                )
            }

        return BackupArchivePayload(
            appSettings: scope == .allData ? settings : nil,
            sessions: sessions,
            messages: messages,
            toolCalls: toolCalls,
            taskStates: taskStates
        )
    }

    private func writeArchive(manifest: BackupArchiveManifest, payload: BackupArchivePayload) throws -> URL {
        let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("agentgui-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: archiveURL.appendingPathComponent("manifest.json"))
        try encoder.encode(payload).write(to: archiveURL.appendingPathComponent("payload.json"))
        return archiveURL
    }

    private func readManifest(from archiveURL: URL) throws -> BackupArchiveManifest {
        let url = archiveURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.invalidArchiveStructure
        }
        return try JSONDecoder().decode(BackupArchiveManifest.self, from: Data(contentsOf: url))
    }

    private func readPayload(from archiveURL: URL) throws -> BackupArchivePayload {
        let url = archiveURL.appendingPathComponent("payload.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.invalidArchiveStructure
        }
        return try JSONDecoder().decode(BackupArchivePayload.self, from: Data(contentsOf: url))
    }
}