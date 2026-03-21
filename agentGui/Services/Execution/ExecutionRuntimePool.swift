import Foundation

@MainActor
final class ExecutionRuntimePool {
    private let driverFactory: (ConversationExecutionProviderID, ConversationExecutionProviderRegistry) -> any ConversationExecutionDriver
    private var driversByProviderID: [ConversationExecutionProviderID: any ConversationExecutionDriver] = [:]

    init(
        driverFactory: @escaping (ConversationExecutionProviderID, ConversationExecutionProviderRegistry) -> any ConversationExecutionDriver = {
            providerID, registry in registry.compatibilityDriver(for: providerID)
        }
    ) {
        self.driverFactory = driverFactory
    }

    func driver(
        for providerID: ConversationExecutionProviderID,
        registry: ConversationExecutionProviderRegistry
    ) -> any ConversationExecutionDriver {
        if let existing = driversByProviderID[providerID] {
            return existing
        }

        let driver = driverFactory(providerID, registry)
        driversByProviderID[providerID] = driver
        return driver
    }

    func reset() {
        driversByProviderID.removeAll()
    }
}