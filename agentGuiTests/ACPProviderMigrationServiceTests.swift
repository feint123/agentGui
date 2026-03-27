import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ACPProviderMigrationServiceTests {
    @Test
    func migrationCreatesStablePresetProfilesAndUpdatesReferences() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")
        settings.defaultExecutionProviderID = ConversationExecutionProviderID.openCodeCLI.rawValue
        settings.githubCopilotCLIConfiguration = ACPCLIConfiguration(executablePath: "/usr/bin/copilot", defaultModel: "gpt-5", defaultApprovalMode: "default")
        settings.openCodeCLIConfiguration = ACPCLIConfiguration(executablePath: "/usr/bin/opencode", defaultModel: "gpt-5-mini", defaultApprovalMode: "review")
        settings.claudeAdapterCLIConfiguration = ACPCLIConfiguration(executablePath: "/usr/bin/claude", defaultModel: "claude-sonnet", defaultApprovalMode: "default")

        let session = Session.fixture(title: "Migrated")
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        session.executionPreferences = SessionExecutionPreferences(
            builtIn: .init(modelID: "claude-sonnet-4-6", approvalMode: "default"),
            gitHubCopilotCLI: .init(modelID: "gpt-5", approvalMode: "always", modeID: "plan"),
            openCodeCLI: .init(modelID: "gpt-5-mini", approvalMode: "review", modeID: "edit"),
            claudeAdapterCLI: .init(modelID: "claude-code", approvalMode: "default", modeID: "chat")
        )

        context.insert(settings)
        context.insert(session)
        try context.save()

        let service = ACPProviderMigrationService(modelContext: context)
        let profiles = try service.migrate()

        #expect(profiles.count == 3)
        #expect(try #require(profiles[.githubCopilotCLI]).id == LegacyExternalACPProviderKey.githubCopilotCLI.presetProfileID)
        #expect(try #require(profiles[.openCodeCLI]).id == LegacyExternalACPProviderKey.openCodeCLI.presetProfileID)
        #expect(try #require(profiles[.claudeAdapterCLI]).id == LegacyExternalACPProviderKey.claudeAdapterCLI.presetProfileID)
        #expect(settings.defaultExecutionProviderReference == .externalACP(profileID: try #require(profiles[.openCodeCLI]).id))
        #expect(session.defaultExecutionProviderReference == .externalACP(profileID: try #require(profiles[.githubCopilotCLI]).id))

        let migratedPreferences = session.executionPreferences
        #expect(migratedPreferences.externalACP[try #require(profiles[.githubCopilotCLI]).id]?.selectedModeID == "plan")
        #expect(migratedPreferences.externalACP[try #require(profiles[.openCodeCLI]).id]?.selectedModeID == "edit")
        #expect(migratedPreferences.externalACP[try #require(profiles[.claudeAdapterCLI]).id]?.selectedModeID == "chat")
    }

    @Test
    func migrationIsIdempotent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")
        context.insert(settings)
        try context.save()

        let service = ACPProviderMigrationService(modelContext: context)
        _ = try service.migrate()
        _ = try service.migrate()

        let repository = ACPProviderProfileRepository(modelContext: context)
        let profiles = try repository.allProfiles()
        #expect(profiles.count == 3)
        #expect(Set(profiles.compactMap(\ .legacyProviderKey)).count == 3)
        #expect(profiles.first(where: { $0.legacyProviderKey == .githubCopilotCLI })?.id == LegacyExternalACPProviderKey.githubCopilotCLI.presetProfileID)
        #expect(profiles.first(where: { $0.legacyProviderKey == .openCodeCLI })?.id == LegacyExternalACPProviderKey.openCodeCLI.presetProfileID)
        #expect(profiles.first(where: { $0.legacyProviderKey == .claudeAdapterCLI })?.id == LegacyExternalACPProviderKey.claudeAdapterCLI.presetProfileID)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}