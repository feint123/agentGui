import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ACPProviderProfileRepositoryTests {
    @Test
    func savesProfilesSortedBySortOrder() throws {
        let repository = try makeRepository()

        _ = try repository.save(
            profileDraft: ACPProviderProfileDraft(
                displayName: "Second",
                executablePath: "/usr/bin/second",
                sortOrder: 2
            )
        )
        _ = try repository.save(
            profileDraft: ACPProviderProfileDraft(
                displayName: "First",
                executablePath: "/usr/bin/first",
                sortOrder: 1
            )
        )

        let profiles = try repository.allProfiles()
        #expect(profiles.map(\ .displayName) == ["First", "Second"])
    }

    @Test
    func enabledProfilesExcludeDisabledEntries() throws {
        let repository = try makeRepository()

        _ = try repository.save(
            profileDraft: ACPProviderProfileDraft(
                displayName: "Enabled",
                executablePath: "/usr/bin/enabled",
                isEnabled: true
            )
        )
        _ = try repository.save(
            profileDraft: ACPProviderProfileDraft(
                displayName: "Disabled",
                executablePath: "/usr/bin/disabled",
                isEnabled: false
            )
        )

        let profiles = try repository.enabledProfiles()
        #expect(profiles.count == 1)
        #expect(profiles.first?.displayName == "Enabled")
    }

    @Test
    func argumentsAndValidationSnapshotRoundTripThroughProfileHelpers() throws {
        let repository = try makeRepository()
        let verifiedAt = Date(timeIntervalSince1970: 1234)
        let snapshot = ACPProviderValidationSnapshot(
            agentInfo: ACPImplementation(name: "copilot", title: "GitHub Copilot", version: "1.0.0"),
            agentCapabilities: ACPAgentCapabilities(loadSession: true),
            authMethods: [ACPAuthMethod(description: "Browser", id: "login", name: "Login")],
            status: .ready,
            message: "ok",
            resolvedExecutablePath: "/usr/local/bin/copilot",
            verifiedAt: verifiedAt
        )

        let saved = try repository.save(
            profileDraft: ACPProviderProfileDraft(
                displayName: "Copilot",
                executablePath: "copilot",
                arguments: ["acp", "--stdio"],
                validationSnapshot: snapshot
            )
        )

        #expect(saved.arguments == ["acp", "--stdio"])
        #expect(saved.validationSnapshot == snapshot)
    }

    private func makeRepository() throws -> ACPProviderProfileRepository {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ACPProviderProfileRepository(modelContext: ModelContext(container))
    }
}