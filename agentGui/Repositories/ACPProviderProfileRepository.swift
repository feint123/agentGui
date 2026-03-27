import Foundation
import SwiftData

@MainActor
struct ACPProviderProfileRepository {
    let modelContext: ModelContext

    func allProfiles() throws -> [ACPProviderProfile] {
        let profiles = try modelContext.fetch(FetchDescriptor<ACPProviderProfile>())
        return profiles.sorted(using: profileSort)
    }

    func enabledProfiles() throws -> [ACPProviderProfile] {
        try allProfiles().filter(\ .isEnabled)
    }

    func nextSortOrder() throws -> Int {
        try (allProfiles().map(\ .sortOrder).max() ?? -1) + 1
    }

    @discardableResult
    func save(profileDraft: ACPProviderProfileDraft) throws -> ACPProviderProfile {
        let now = Date()
        let profile: ACPProviderProfile

        if let id = profileDraft.id,
           let existing = try allProfiles().first(where: { $0.id == id }) {
            profile = existing
        } else {
            profile = ACPProviderProfile(
                id: profileDraft.id ?? UUID(),
                legacyProviderKeyRaw: "",
                displayName: profileDraft.displayName,
                executablePath: profileDraft.executablePath,
                arguments: profileDraft.arguments,
                isEnabled: profileDraft.isEnabled,
                sortOrder: try profileDraft.sortOrder ?? nextSortOrder(),
                sourceKind: profileDraft.sourceKind,
                validationSnapshot: profileDraft.validationSnapshot,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(profile)
        }

        profile.displayName = profileDraft.displayName
        profile.executablePath = profileDraft.executablePath
        profile.arguments = profileDraft.arguments
        profile.isEnabled = profileDraft.isEnabled
        profile.sourceKind = profileDraft.sourceKind
        if let sortOrder = profileDraft.sortOrder {
            profile.sortOrder = sortOrder
        }
        profile.validationSnapshot = profileDraft.validationSnapshot
        profile.updatedAt = now

        try modelContext.save()
        return profile
    }

    func delete(profileID: UUID) throws {
        guard let profile = try allProfiles().first(where: { $0.id == profileID }) else {
            return
        }
        modelContext.delete(profile)
        try modelContext.save()
    }

    private var profileSort: SortComparator<ACPProviderProfile> {
        SortDescriptor(\ACPProviderProfile.sortOrder)
    }
}