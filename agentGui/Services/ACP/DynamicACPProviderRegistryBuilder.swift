import Foundation

@MainActor
struct DynamicACPProviderRegistryBuilder {
    typealias ProviderFactory = @MainActor (ACPProviderProfile) -> any ConversationExecutionProvider

    let repository: ACPProviderProfileRepository
    let providerFactory: ProviderFactory

    init(
        repository: ACPProviderProfileRepository,
        providerFactory: @escaping ProviderFactory
    ) {
        self.repository = repository
        self.providerFactory = providerFactory
    }

    func build(builtIn: any ConversationExecutionProvider) throws -> ConversationExecutionProviderRegistry {
        let profiles = try repository.enabledProfiles()
        var externalProviders: [ExecutionProviderReference: any ConversationExecutionProvider] = [:]

        for profile in profiles {
            let provider = providerFactory(profile)
            externalProviders[provider.reference] = provider
        }

        return ConversationExecutionProviderRegistry(
            builtIn: builtIn,
            externalProviders: externalProviders
        )
    }
}