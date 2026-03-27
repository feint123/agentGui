import Foundation
import SwiftData

actor ACPExternalProviderUpdateQueue {
    private struct SessionState {
        var tailTask: Task<Void, Never>
        var tailToken: UUID
    }

    private var sessionStates: [String: SessionState] = [:]

    func enqueue(
        localSessionID: String,
        operation: @escaping @Sendable () async -> Void
    ) {
        let previousTask = sessionStates[localSessionID]?.tailTask
        let token = UUID()
        let task = Task {
            await previousTask?.value
            await operation()
            await finish(localSessionID: localSessionID, token: token)
        }

        sessionStates[localSessionID] = SessionState(tailTask: task, tailToken: token)
    }

    func drain(localSessionID: String) async {
        for _ in 0..<3 {
            while let task = sessionStates[localSessionID]?.tailTask {
                await task.value
            }
            await Task.yield()
        }
    }

    func clear(localSessionID: String) {
        sessionStates.removeValue(forKey: localSessionID)
    }

    private func finish(localSessionID: String, token: UUID) {
        guard sessionStates[localSessionID]?.tailToken == token else {
            return
        }

        sessionStates.removeValue(forKey: localSessionID)
    }
}

@MainActor
struct ACPExternalProviderActiveTurnState {
    let assistantMessage: Message
    let modelContext: ModelContext
}

@MainActor
final class ACPExternalProviderSessionStateStore {
    @MainActor
    final class SessionState {
        static let projectedPersistenceBatchThreshold = 8

        let localSessionID: String

        var modelContext: ModelContext?
        var activeTurn: ACPExternalProviderActiveTurnState?
        var remoteSessionID: String?
        var activationID: RuntimeActivationID?
        private(set) var pendingProjectedMutationCount = 0

        private var featureStoreCache: ACPExternalSessionFeatureStore?

        init(localSessionID: String) {
            self.localSessionID = localSessionID
        }

        func featureStore(modelContext: ModelContext) -> ACPExternalSessionFeatureStore {
            if let featureStoreCache {
                return featureStoreCache
            }

            let store = ACPExternalSessionFeatureStore(
                taskStateStore: SessionTaskStateStore(modelContext: modelContext),
                planProjector: ACPPlanProjector()
            )
            featureStoreCache = store
            return store
        }

        func commands(
            for providerReference: ExecutionProviderReference,
            remoteSessionID: String
        ) -> [ACPCommandDescriptor] {
            featureStoreCache?.commands(for: providerReference, remoteSessionID: remoteSessionID) ?? []
        }

        func commands(
            for providerReference: ExecutionProviderReference
        ) -> [ACPCommandDescriptor] {
            featureStoreCache?.commands(for: localSessionID, providerReference: providerReference) ?? []
        }

        func plan() -> ACPPlanSnapshotDraft? {
            featureStoreCache?.plan(for: localSessionID)
        }

        func sessionConfiguration(
            for providerReference: ExecutionProviderReference
        ) -> ACPExternalAgentSessionConfigurationSnapshot? {
            featureStoreCache?.sessionConfiguration(for: localSessionID, providerReference: providerReference)
        }

        func sessionConfiguration(
            for providerReference: ExecutionProviderReference,
            remoteSessionID: String
        ) -> ACPExternalAgentSessionConfigurationSnapshot? {
            featureStoreCache?.sessionConfiguration(for: providerReference, remoteSessionID: remoteSessionID)
        }

        var hasPendingProjectedMutations: Bool {
            pendingProjectedMutationCount > 0
        }

        @discardableResult
        func recordProjectedMutation(count: Int = 1) -> Bool {
            pendingProjectedMutationCount += max(1, count)
            return pendingProjectedMutationCount >= Self.projectedPersistenceBatchThreshold
        }

        func resetProjectedMutations() {
            pendingProjectedMutationCount = 0
        }

        func clearRuntimeState(
            removeBinding: Bool,
            removeFeatureStore: Bool
        ) {
            modelContext = nil
            activeTurn = nil
            activationID = nil
            resetProjectedMutations()

            if removeBinding {
                remoteSessionID = nil
            }

            if removeFeatureStore {
                featureStoreCache = nil
            }
        }
    }

    private var sessionStates: [String: SessionState] = [:]

    func state(for localSessionID: String) -> SessionState {
        if let existing = sessionStates[localSessionID] {
            return existing
        }

        let created = SessionState(localSessionID: localSessionID)
        sessionStates[localSessionID] = created
        return created
    }

    func existingState(for localSessionID: String) -> SessionState? {
        sessionStates[localSessionID]
    }

    func removeState(for localSessionID: String) {
        sessionStates.removeValue(forKey: localSessionID)
    }
}