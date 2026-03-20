import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct BackupArchiveServiceTests {

    @Test func exportsSingleSessionWithoutLeakingOtherSessions() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        seedTwoSessions(into: context)

        let service = BackupArchiveService()
        let archiveURL = try service.exportSession(id: "session-1", from: context)
        let manifest = try loadManifest(from: archiveURL)
        let payload = try loadPayload(from: archiveURL)

        #expect(manifest.scope == .singleSession("session-1"))
        #expect(manifest.sessionIDs == ["session-1"])
        #expect(payload.sessions.count == 1)
        #expect(payload.messages.allSatisfy { $0.sessionId == "session-1" })
    }

    @Test func exportsFullBackupWithCoreModelSections() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        seedTwoSessions(into: context)

        let service = BackupArchiveService()
        let archiveURL = try service.exportAll(from: context)
        let manifest = try loadManifest(from: archiveURL)
        let payload = try loadPayload(from: archiveURL)

        #expect(manifest.scope == .allData)
        #expect(payload.appSettings != nil)
        #expect(!payload.sessions.isEmpty)
        #expect(!payload.messages.isEmpty)
        #expect(!payload.toolCalls.isEmpty)
        #expect(!payload.taskStates.isEmpty)
    }

    @Test func restoreDryRunRejectsIncompatibleManifestVersion() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        seedTwoSessions(into: context)

        let service = BackupArchiveService()
        let archiveURL = try service.exportAll(from: context)
        try overwriteManifestVersion(at: archiveURL, version: 999)

        await #expect(throws: BackupArchiveService.BackupError.self) {
            try service.restore(from: archiveURL, into: context, dryRun: true)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: AppSettings.self,
            Session.self,
            Message.self,
            ToolCall.self,
            SessionTaskState.self,
            configurations: config
        )
    }

    private func seedTwoSessions(into context: ModelContext) {
        let settings = AppSettings.getOrCreate(in: context)
        settings.selectedModel = "claude-sonnet-4-6"

        let session1 = Session(sessionId: "session-1", title: "First")
        let session2 = Session(sessionId: "session-2", title: "Second")
        context.insert(session1)
        context.insert(session2)

        let user1 = Message.userMessage(text: "hello", session: session1)
        let user2 = Message.userMessage(text: "world", session: session2)
        context.insert(user1)
        context.insert(user2)

        let toolCall = ToolCall(toolCallId: "tool-1", kind: .read, message: user1)
        context.insert(toolCall)

        let taskState = SessionTaskState(sessionId: "session-1", planJson: "{}", todoJson: "[]", verificationJson: "")
        context.insert(taskState)

        try? context.save()
    }

    private func loadManifest(from archiveURL: URL) throws -> BackupArchiveManifest {
        let data = try Data(contentsOf: archiveURL.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(BackupArchiveManifest.self, from: data)
    }

    private func loadPayload(from archiveURL: URL) throws -> BackupArchivePayload {
        let data = try Data(contentsOf: archiveURL.appendingPathComponent("payload.json"))
        return try JSONDecoder().decode(BackupArchivePayload.self, from: data)
    }

    private func overwriteManifestVersion(at archiveURL: URL, version: Int) throws {
        var manifest = try loadManifest(from: archiveURL)
        manifest.schemaVersion = version
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: archiveURL.appendingPathComponent("manifest.json"))
    }
}