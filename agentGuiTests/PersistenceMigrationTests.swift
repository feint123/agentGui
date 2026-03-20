import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct PersistenceMigrationTests {

    @Test func decodesLegacySessionTaskStateArchiveWithDefaultValues() throws {
        let legacyJSON = """
        {
          "sessionId": "session-legacy",
          "planJson": "{\\\"goal\\\":\\\"ship\\\"}"
        }
        """.data(using: .utf8)!

        let archive = try JSONDecoder().decode(SessionTaskStateArchive.self, from: legacyJSON)

        #expect(archive.sessionId == "session-legacy")
        #expect(archive.planJson.contains("ship"))
        #expect(archive.todoJson == "[]")
        #expect(archive.verificationJson == "")
    }

    @Test func dryRunRestoreRejectsUnsupportedBackupSchemaVersion() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let service = BackupArchiveService()
        let archiveURL = try service.exportAll(from: context)

        var manifest = try loadManifest(from: archiveURL)
        manifest.schemaVersion = agentGuiApp.persistenceSchemaVersion + 10
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: archiveURL.appendingPathComponent("manifest.json"))

        await #expect(throws: BackupArchiveService.BackupError.self) {
            try service.restore(from: archiveURL, into: context, dryRun: true)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: AppSettings.self, Session.self, Message.self, ToolCall.self, SessionTaskState.self, configurations: config)
    }

    private func loadManifest(from archiveURL: URL) throws -> BackupArchiveManifest {
        let data = try Data(contentsOf: archiveURL.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(BackupArchiveManifest.self, from: data)
    }
}