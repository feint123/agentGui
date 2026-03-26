import Foundation
import SwiftData

@MainActor
final class ConversationExecutionRuntimeCoordinator {
    private struct ScopeState {
        var foregroundSessionID: String?
        var retainedSessionIDs: Set<String> = []
    }

    private struct ReleasePlan {
        let scope: ConversationExecutionRuntimeScope
        let sessionID: String
    }

    private let projectionStore: ExecutionProjectionStore
    private var scopeStates: [ConversationExecutionRuntimeScope: ScopeState] = [:]

    init(projectionStore: ExecutionProjectionStore) {
        self.projectionStore = projectionStore
    }

    convenience init() {
        self.init(projectionStore: ExecutionProjectionStore())
    }

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

        let transition = makeActivationTransition(
            activatingSessionID: session.sessionId,
            activeScope: runtimeScope,
            registry: registry,
            trigger: trigger
        )
        await applyReleasePlans(transition.releasePlans, registry: registry, modelContext: modelContext)
        scopeStates = transition.scopeStates

        let scopedProviders = registry.providers(in: runtimeScope)

        for provider in scopedProviders where provider.id != activeProvider.id {
            await provider.releasePreparedRuntime(
                localSessionID: session.sessionId,
                modelContext: modelContext,
                reason: .providerBecameInactive
            )
        }

        await activeProvider.prepareForActivation(
            session: session,
            isActiveProvider: true,
            modelContext: modelContext,
            trigger: trigger
        )
    }

    func reconcileRuntimeRetention(
        registry: ConversationExecutionProviderRegistry,
        modelContext: ModelContext
    ) async {
        let transition = makeRetentionTransition(registry: registry)
        await applyReleasePlans(transition.releasePlans, registry: registry, modelContext: modelContext)
        scopeStates = transition.scopeStates
    }

    private func makeActivationTransition(
        activatingSessionID sessionID: String,
        activeScope: ConversationExecutionRuntimeScope,
        registry: ConversationExecutionProviderRegistry,
        trigger: ConversationExecutionActivationTrigger
    ) -> (scopeStates: [ConversationExecutionRuntimeScope: ScopeState], releasePlans: [ReleasePlan]) {
        let knownScopes = Set(registry.allProviders.compactMap(\.runtimeScope))
        var nextStates = scopeStates

        for scope in knownScopes {
            var state = nextStates[scope] ?? ScopeState()

            switch trigger {
            case .selection, .sessionBootstrap:
                state.foregroundSessionID = scope == activeScope ? sessionID : nil
            case .executionDispatch:
                break
            }

            state.retainedSessionIDs = retainedSessionIDs(
                for: scope,
                currentState: state,
                activatingSessionID: scope == activeScope ? sessionID : nil,
                registry: registry
            )
            nextStates[scope] = state
        }

        return (nextStates, releasePlans(from: scopeStates, to: nextStates))
    }

    private func makeRetentionTransition(
        registry: ConversationExecutionProviderRegistry
    ) -> (scopeStates: [ConversationExecutionRuntimeScope: ScopeState], releasePlans: [ReleasePlan]) {
        let knownScopes = Set(registry.allProviders.compactMap(\.runtimeScope))
        var nextStates = scopeStates

        for scope in knownScopes {
            var state = nextStates[scope] ?? ScopeState()
            state.retainedSessionIDs = retainedSessionIDs(
                for: scope,
                currentState: state,
                activatingSessionID: nil,
                registry: registry
            )
            nextStates[scope] = state
        }

        return (nextStates, releasePlans(from: scopeStates, to: nextStates))
    }

    private func retainedSessionIDs(
        for scope: ConversationExecutionRuntimeScope,
        currentState: ScopeState,
        activatingSessionID: String?,
        registry: ConversationExecutionProviderRegistry
    ) -> Set<String> {
        var retainedSessionIDs: Set<String> = []

        if let foregroundSessionID = currentState.foregroundSessionID {
            retainedSessionIDs.insert(foregroundSessionID)
        }

        if let activatingSessionID {
            retainedSessionIDs.insert(activatingSessionID)
        }

        for sessionID in currentState.retainedSessionIDs where shouldProtectRuntime(for: sessionID, in: scope, registry: registry) {
            retainedSessionIDs.insert(sessionID)
        }

        return retainedSessionIDs
    }

    private func shouldProtectRuntime(
        for sessionID: String,
        in scope: ConversationExecutionRuntimeScope,
        registry: ConversationExecutionProviderRegistry
    ) -> Bool {
        let projection = projectionStore.projection(for: sessionID)
        guard projection.isRunning,
              let providerID = projection.activeProviderID else {
            return false
        }

        return registry.provider(for: providerID).runtimeScope == scope
    }

    private func releasePlans(
        from currentStates: [ConversationExecutionRuntimeScope: ScopeState],
        to nextStates: [ConversationExecutionRuntimeScope: ScopeState]
    ) -> [ReleasePlan] {
        let knownScopes = Set(currentStates.keys).union(nextStates.keys)
        var plans: [ReleasePlan] = []

        for scope in knownScopes {
            let currentSessions = currentStates[scope]?.retainedSessionIDs ?? []
            let nextSessions = nextStates[scope]?.retainedSessionIDs ?? []
            for sessionID in currentSessions.subtracting(nextSessions) {
                plans.append(ReleasePlan(scope: scope, sessionID: sessionID))
            }
        }

        return plans
    }

    private func applyReleasePlans(
        _ releasePlans: [ReleasePlan],
        registry: ConversationExecutionProviderRegistry,
        modelContext: ModelContext
    ) async {
        for plan in releasePlans {
            for provider in registry.providers(in: plan.scope) {
                await provider.releasePreparedRuntime(
                    localSessionID: plan.sessionID,
                    modelContext: modelContext,
                    reason: .sessionBecameInactive
                )
            }
        }
    }
}