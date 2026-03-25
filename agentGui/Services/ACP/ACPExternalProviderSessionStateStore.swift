import Foundation
import SwiftData

@MainActor
struct ACPExternalProviderActiveTurnState {
    let assistantMessage: Message
    let modelContext: ModelContext
}

@MainActor
final class ACPExternalProviderSessionStateStore {
    @MainActor
    final class SessionState {
        let localSessionID: String

        var modelContext: ModelContext?
        var activeTurn: ACPExternalProviderActiveTurnState?
        var remoteSessionID: String?
        var activationID: RuntimeActivationID?
        var pendingUpdateTask: Task<Void, Never>?
        var pendingUpdateTaskToken: UUID?

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
            for providerID: ConversationExecutionProviderID,
            remoteSessionID: String
        ) -> [ACPCommandDescriptor] {
            featureStoreCache?.commands(for: providerID, remoteSessionID: remoteSessionID) ?? []
        }

        func commands(
            for providerID: ConversationExecutionProviderID
        ) -> [ACPCommandDescriptor] {
            featureStoreCache?.commands(for: localSessionID, providerID: providerID) ?? []
        }

        func plan() -> ACPPlanSnapshotDraft? {
            featureStoreCache?.plan(for: localSessionID)
        }

        func sessionConfiguration(
            for providerID: ConversationExecutionProviderID
        ) -> ACPExternalAgentSessionConfigurationSnapshot? {
            featureStoreCache?.sessionConfiguration(for: localSessionID, providerID: providerID)
        }

        func sessionConfiguration(
            for providerID: ConversationExecutionProviderID,
            remoteSessionID: String
        ) -> ACPExternalAgentSessionConfigurationSnapshot? {
            featureStoreCache?.sessionConfiguration(for: providerID, remoteSessionID: remoteSessionID)
        }

        func clearPendingUpdateTask() {
            pendingUpdateTask = nil
            pendingUpdateTaskToken = nil
        }

        func clearRuntimeState(
            removeBinding: Bool,
            removeFeatureStore: Bool
        ) {
            modelContext = nil
            activeTurn = nil
            activationID = nil
            clearPendingUpdateTask()

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