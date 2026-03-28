import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct DynamicACPProviderRegistryBuilderTests {
    @Test
    func enabledProfilesProduceExternalProvidersAndDisabledProfilesDoNot() throws {
        let context = try makeModelContext()
        let enabledProfile = ACPProviderProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            displayName: "Enabled",
            executablePath: "/usr/bin/enabled",
            isEnabled: true,
            sortOrder: 1
        )
        let disabledProfile = ACPProviderProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            displayName: "Disabled",
            executablePath: "/usr/bin/disabled",
            isEnabled: false,
            sortOrder: 2
        )
        context.insert(enabledProfile)
        context.insert(disabledProfile)
        try context.save()

        let builder = DynamicACPProviderRegistryBuilder(
            repository: ACPProviderProfileRepository(modelContext: context),
            providerFactory: { profile in
                RegistryBuilderTestProvider(
                    reference: .externalACP(profileID: profile.id),
                    legacyProviderID: nil
                )
            }
        )

        let registry = try builder.build(
            builtIn: RegistryBuilderTestProvider(reference: .builtIn, legacyProviderID: .builtInAgent)
        )

        #expect(registry.allProviders.count == 2)
        #expect(registry.providerIfAvailable(for: .externalACP(profileID: enabledProfile.id)) != nil)
        #expect(registry.providerIfAvailable(for: .externalACP(profileID: disabledProfile.id)) == nil)
    }

    @Test
    func providerLookupByExternalReferenceReturnsMatchingProvider() throws {
        let context = try makeModelContext()
        let profile = ACPProviderProfile(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            displayName: "Profile",
            executablePath: "/usr/bin/profile",
            isEnabled: true,
            sortOrder: 1
        )
        context.insert(profile)
        try context.save()

        let builder = DynamicACPProviderRegistryBuilder(
            repository: ACPProviderProfileRepository(modelContext: context),
            providerFactory: { profile in
                RegistryBuilderTestProvider(
                    reference: .externalACP(profileID: profile.id),
                    legacyProviderID: nil
                )
            }
        )

        let registry = try builder.build(
            builtIn: RegistryBuilderTestProvider(reference: .builtIn, legacyProviderID: .builtInAgent)
        )
        let provider = try #require(registry.providerIfAvailable(for: .externalACP(profileID: profile.id)))

        #expect(provider.reference == .externalACP(profileID: profile.id))
    }

    private func makeModelContext() throws -> ModelContext {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }
}

@MainActor
private final class RegistryBuilderTestProvider: ConversationExecutionProvider {
    let reference: ExecutionProviderReference
    let legacyProviderID: ConversationExecutionProviderID?
    let runtimeScope: ConversationExecutionRuntimeScope? = .externalACP

    init(reference: ExecutionProviderReference, legacyProviderID: ConversationExecutionProviderID?) {
        self.reference = reference
        self.legacyProviderID = legacyProviderID
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        _ = request
    }

    func regenerate(_ request: ConversationRegenerationRequest) async throws {
        _ = request
    }

    func editAndResend(_ request: ConversationEditAndResendRequest) async throws {
        _ = request
    }

    func cancel(session: Session, modelContext: ModelContext) async {
        _ = session
        _ = modelContext
    }
}