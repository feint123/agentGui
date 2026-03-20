import Foundation
import SwiftData

@MainActor
struct ConversationExecutionRuntimeCoordinator {
    func prepareForActivation(
        session: Session,
        activeProvider: any ConversationExecutionProvider,
        registry: ConversationExecutionProviderRegistry,
        modelContext: ModelContext
    ) async {
        guard let runtimeScope = activeProvider.runtimeScope else {
            return
        }

        for provider in registry.providers(in: runtimeScope) {
            await provider.prepareForActivation(
                session: session,
                isActiveProvider: provider.id == activeProvider.id,
                modelContext: modelContext
            )
        }
    }
}