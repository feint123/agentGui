import Foundation

@MainActor
final class ExecutionRuntimePool {
    private let driverFactory: (ExecutionProviderReference, ConversationExecutionProviderRegistry) -> any ConversationExecutionDriver
    private var driversByProviderReference: [String: any ConversationExecutionDriver] = [:]

    init(
        driverFactory: @escaping (ExecutionProviderReference, ConversationExecutionProviderRegistry) -> any ConversationExecutionDriver = {
            providerReference, registry in registry.driver(for: providerReference)
        }
    ) {
        self.driverFactory = driverFactory
    }

    func driver(
        for providerReference: ExecutionProviderReference,
        registry: ConversationExecutionProviderRegistry
    ) -> any ConversationExecutionDriver {
        let key = providerReference.persistedValue
        if let existing = driversByProviderReference[key] {
            return existing
        }

        let driver = driverFactory(providerReference, registry)
        driversByProviderReference[key] = driver
        return driver
    }

    func driver(
        for providerID: ConversationExecutionProviderID,
        registry: ConversationExecutionProviderRegistry
    ) -> any ConversationExecutionDriver {
        let providerReference: ExecutionProviderReference = providerID == .builtInAgent
            ? .builtIn
            : LegacyExternalACPProviderKey.allCases.first(where: { $0.conversationExecutionProviderID == providerID })?.compatibilityReference ?? .builtIn
        return driver(for: providerReference, registry: registry)
    }

    func reset() {
        driversByProviderReference.removeAll()
    }
}