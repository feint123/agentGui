import Foundation
import SwiftData

@MainActor
struct ACPProviderMigrationService {
    let modelContext: ModelContext

    @discardableResult
    func migrate() throws -> [LegacyExternalACPProviderKey: ACPProviderProfile] {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let repository = ACPProviderProfileRepository(modelContext: modelContext)
        let existingProfiles = try repository.allProfiles()
        var profilesByLegacyKey: [LegacyExternalACPProviderKey: ACPProviderProfile] = [:]

        profilesByLegacyKey[.githubCopilotCLI] = try upsertPresetProfile(
            legacyKey: .githubCopilotCLI,
            displayName: ConversationExecutionProviderID.githubCopilotCLI.displayName,
            configuration: settings.githubCopilotCLIConfiguration,
            existingProfiles: existingProfiles,
            sortOrder: 0
        )
        profilesByLegacyKey[.openCodeCLI] = try upsertPresetProfile(
            legacyKey: .openCodeCLI,
            displayName: ConversationExecutionProviderID.openCodeCLI.displayName,
            configuration: settings.openCodeCLIConfiguration,
            existingProfiles: existingProfiles,
            sortOrder: 1
        )
        profilesByLegacyKey[.claudeAdapterCLI] = try upsertPresetProfile(
            legacyKey: .claudeAdapterCLI,
            displayName: ConversationExecutionProviderID.claudeAdapterCLI.displayName,
            configuration: settings.claudeAdapterCLIConfiguration,
            existingProfiles: existingProfiles,
            sortOrder: 2
        )

        migrateDefaultProviderReference(for: settings, profilesByLegacyKey: profilesByLegacyKey)
        try migrateSessions(profilesByLegacyKey: profilesByLegacyKey)
        try modelContext.save()
        return profilesByLegacyKey
    }

    private func upsertPresetProfile(
        legacyKey: LegacyExternalACPProviderKey,
        displayName: String,
        configuration: ACPCLIConfiguration,
        existingProfiles: [ACPProviderProfile],
        sortOrder: Int
    ) throws -> ACPProviderProfile {
        if let existing = existingProfiles.first(where: { $0.legacyProviderKey == legacyKey }) {
            existing.id = legacyKey.presetProfileID
            existing.displayName = displayName
            existing.executablePath = configuration.executablePath
            existing.arguments = []
            existing.isEnabled = true
            existing.sourceKind = .preset
            existing.sortOrder = sortOrder
            existing.updatedAt = Date()
            return existing
        }

        let profile = ACPProviderProfile(
            id: legacyKey.presetProfileID,
            legacyProviderKeyRaw: legacyKey.rawValue,
            displayName: displayName,
            executablePath: configuration.executablePath,
            arguments: [],
            isEnabled: true,
            sortOrder: sortOrder,
            sourceKind: .preset,
            createdAt: Date(),
            updatedAt: Date()
        )
        modelContext.insert(profile)
        return profile
    }

    private func migrateDefaultProviderReference(
        for settings: AppSettings,
        profilesByLegacyKey: [LegacyExternalACPProviderKey: ACPProviderProfile]
    ) {
        let legacyValue = settings.defaultExecutionProviderID
        if let legacyKey = ExecutionProviderReference.legacyExternalACPKey(from: legacyValue),
           let profile = profilesByLegacyKey[legacyKey] {
            settings.defaultExecutionProviderReference = .externalACP(profileID: profile.id)
        } else {
            settings.defaultExecutionProviderReference = ExecutionProviderReference.decodePersisted(legacyValue)
        }
    }

    private func migrateSessions(
        profilesByLegacyKey: [LegacyExternalACPProviderKey: ACPProviderProfile]
    ) throws {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let legacyProfileIDs = Dictionary(uniqueKeysWithValues: profilesByLegacyKey.map { ($0.key, $0.value.id) })

        for session in sessions {
            if let legacyKey = ExecutionProviderReference.legacyExternalACPKey(from: session.defaultExecutionProviderID),
               let profile = profilesByLegacyKey[legacyKey] {
                session.defaultExecutionProviderReference = .externalACP(profileID: profile.id)
            } else {
                session.defaultExecutionProviderReference = ExecutionProviderReference.decodePersisted(session.defaultExecutionProviderID)
            }

            session.executionPreferences = session.executionPreferences.migrated(using: legacyProfileIDs)
        }
    }
}