import Foundation
import SwiftData

@MainActor
struct ConversationExecutionRuntimeCoordinator {
    func prepareForActivation(
        session: Session,
        activeProvider: any ConversationExecutionProvider,
        registry: ConversationExecutionProviderRegistry,
        modelContext: ModelContext,
        trigger: ConversationExecutionActivationTrigger
    ) async {
        guard let runtimeScope = activeProvider.runtimeScope else {
            return
        }

        let scopedProviders = registry.providers(in: runtimeScope)

        for provider in scopedProviders where provider.id != activeProvider.id {
            await provider.prepareForActivation(
                session: session,
                isActiveProvider: false,
                modelContext: modelContext,
                trigger: trigger
            )
        }

        await activeProvider.prepareForActivation(
            session: session,
            isActiveProvider: true,
            modelContext: modelContext,
            trigger: trigger
        )
    }
}