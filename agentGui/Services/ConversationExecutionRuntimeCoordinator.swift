import Foundation
import SwiftData

@MainActor
final class ConversationExecutionRuntimeCoordinator {
    private struct ScopeState {
        var foregroundSessionID: String?
        var executionLeaseProviderReferencesBySessionID: [String: Set<ExecutionProviderReference>] = [:]
        var retainedSessionIDs: Set<String> = []
    }

    private struct ReleasePlan {
        let scope: ConversationExecutionRuntimeScope
        let sessionID: String
    }

    private let runtimeStateStore: SessionExecutionRuntimeStateStore
    private var scopeStates: [ConversationExecutionRuntimeScope: ScopeState] = [:]

    init(runtimeStateStore: SessionExecutionRuntimeStateStore) {
        self.runtimeStateStore = runtimeStateStore
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
            activeProviderReference: activeProvider.reference,
            registry: registry,
            trigger: trigger
        )
        scopeStates = transition.scopeStates
        await applyReleasePlans(transition.releasePlans, registry: registry, modelContext: modelContext)

        let scopedProviders = registry.providers(in: runtimeScope)
        let protectedProviderReferences = protectedProviderReferences(
            for: session.sessionId,
            in: runtimeScope,
            state: transition.scopeStates[runtimeScope] ?? ScopeState(),
            registry: registry
        )

        for provider in scopedProviders
        where provider.reference != activeProvider.reference
        && !protectedProviderReferences.contains(provider.reference) {
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
        scopeStates = transition.scopeStates
        await applyReleasePlans(transition.releasePlans, registry: registry, modelContext: modelContext)
    }

    private func makeActivationTransition(
        activatingSessionID sessionID: String,
        activeScope: ConversationExecutionRuntimeScope,
        activeProviderReference: ExecutionProviderReference,
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
                if scope == activeScope {
                    state.executionLeaseProviderReferencesBySessionID[sessionID, default: []].insert(activeProviderReference)
                }
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
            state.executionLeaseProviderReferencesBySessionID = retainedExecutionLeaseProviderReferencesBySessionID(
                state.executionLeaseProviderReferencesBySessionID,
                in: scope,
                registry: registry
            )
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

        retainedSessionIDs.formUnion(currentState.executionLeaseProviderReferencesBySessionID.keys)

        for sessionID in currentState.retainedSessionIDs where shouldProtectRuntime(for: sessionID, in: scope, registry: registry) {
            retainedSessionIDs.insert(sessionID)
        }

        return retainedSessionIDs
    }

    private func retainedExecutionLeaseProviderReferencesBySessionID(
        _ providerReferencesBySessionID: [String: Set<ExecutionProviderReference>],
        in scope: ConversationExecutionRuntimeScope,
        registry: ConversationExecutionProviderRegistry
    ) -> [String: Set<ExecutionProviderReference>] {
        var retained: [String: Set<ExecutionProviderReference>] = [:]

        for (sessionID, providerReferences) in providerReferencesBySessionID {
            let retainedReferences = providerReferences.filter {
                shouldProtectRuntime(for: sessionID, providerReference: $0, in: scope, registry: registry)
            }

            if !retainedReferences.isEmpty {
                retained[sessionID] = Set(retainedReferences)
            }
        }

        return retained
    }

    private func protectedProviderReferences(
        for sessionID: String,
        in scope: ConversationExecutionRuntimeScope,
        state: ScopeState,
        registry: ConversationExecutionProviderRegistry
    ) -> Set<ExecutionProviderReference> {
        var protectedReferences = state.executionLeaseProviderReferencesBySessionID[sessionID] ?? []

        if let runningProviderReference = runtimeState(for: sessionID).runningProviderReference,
           shouldProtectRuntime(
               for: sessionID,
               providerReference: runningProviderReference,
               in: scope,
               registry: registry
           ) {
            protectedReferences.insert(runningProviderReference)
        }

        return protectedReferences
    }

    private func runtimeState(for sessionID: String) -> SessionExecutionRuntimeState {
        runtimeStateStore.state(for: sessionID)
    }

    private func shouldProtectRuntime(
        for sessionID: String,
        in scope: ConversationExecutionRuntimeScope,
        registry: ConversationExecutionProviderRegistry
    ) -> Bool {
        let state = runtimeState(for: sessionID)
        guard state.isRunning,
              let providerReference = state.runningProviderReference,
              let protectedProvider = registry.providerIfAvailable(for: providerReference) else {
            return false
        }

        return protectedProvider.runtimeScope == scope
    }

    private func shouldProtectRuntime(
        for sessionID: String,
        providerReference: ExecutionProviderReference,
        in scope: ConversationExecutionRuntimeScope,
        registry: ConversationExecutionProviderRegistry
    ) -> Bool {
        let state = runtimeState(for: sessionID)
        guard state.isRunning,
              state.runningProviderReference == providerReference,
              let protectedProvider = registry.providerIfAvailable(for: providerReference) else {
            return false
        }

        return protectedProvider.runtimeScope == scope
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