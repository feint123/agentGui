import Foundation
import Testing
import SwiftData
@testable import agentGui

@MainActor
struct ConversationExecutionRuntimeCoordinatorTests {
    @Test
    func foregroundActivationReleasesPreviousSessionLeaseAndSiblingProviders() async throws {
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()
        let projectionStore = ExecutionProjectionStore()
        let coordinator = ConversationExecutionRuntimeCoordinator(projectionStore: projectionStore)
        let builtIn = RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: builtIn,
            copilot: copilot,
            openCode: openCode,
            claudeAdapter: RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        await coordinator.prepareForActivation(
            session: harness.secondSession,
            activeProvider: openCode,
            registry: registry,
            modelContext: harness.context,
            trigger: .selection
        )

        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)))
        #expect(openCode.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)))
        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.secondSession.sessionId, reason: .providerBecameInactive)))
        #expect(openCode.activePreparationEvents == [harness.secondSession.sessionId])
    }

    @Test
    func foregroundBuiltInActivationClearsExternalForegroundLease() async throws {
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()
        let projectionStore = ExecutionProjectionStore()
        let coordinator = ConversationExecutionRuntimeCoordinator(projectionStore: projectionStore)
        let builtIn = RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: builtIn,
            copilot: copilot,
            openCode: RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP),
            claudeAdapter: RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        await coordinator.prepareForActivation(
            session: harness.secondSession,
            activeProvider: builtIn,
            registry: registry,
            modelContext: harness.context,
            trigger: .selection
        )

        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)))
        #expect(builtIn.activePreparationEvents == [harness.secondSession.sessionId])
    }

    @Test
    func executionDispatchDoesNotEvictForegroundSessionLease() async throws {
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()
        let projectionStore = ExecutionProjectionStore()
        let coordinator = ConversationExecutionRuntimeCoordinator(projectionStore: projectionStore)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
            copilot: copilot,
            openCode: openCode,
            claudeAdapter: RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        await coordinator.prepareForActivation(
            session: harness.secondSession,
            activeProvider: openCode,
            registry: registry,
            modelContext: harness.context,
            trigger: .executionDispatch
        )

        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.secondSession.sessionId, reason: .providerBecameInactive)))
        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)) == false)
        #expect(openCode.activePreparationEvents == [harness.secondSession.sessionId])
    }

    @Test
    func selectionSwitchKeepsRunningPreviousForegroundRuntimeRetained() async throws {
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()
        let projectionStore = ExecutionProjectionStore()
        let coordinator = ConversationExecutionRuntimeCoordinator(projectionStore: projectionStore)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
            copilot: copilot,
            openCode: openCode,
            claudeAdapter: RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        projectionStore.setProjection(
            SessionExecutionProjection(
                sessionID: harness.firstSession.sessionId,
                runningJobID: UUID(),
                queuedJobIDs: [],
                queuedCount: 0,
                isRunning: true,
                canEditComposer: true,
                canSubmitNewJob: true,
                activeProviderID: .githubCopilotCLI,
                currentPhase: .executing,
                activityState: .running,
                presentationState: .foreground,
                needsAttention: false,
                attentionReason: nil
            )
        )

        await coordinator.prepareForActivation(
            session: harness.secondSession,
            activeProvider: openCode,
            registry: registry,
            modelContext: harness.context,
            trigger: .selection
        )

        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)) == false)
        #expect(openCode.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)) == false)
        #expect(openCode.activePreparationEvents == [harness.secondSession.sessionId])
    }

    @Test
    func reconcileRuntimeRetentionReleasesBackgroundRuntimeAfterExecutionFinishes() async throws {
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()
        let projectionStore = ExecutionProjectionStore()
        let coordinator = ConversationExecutionRuntimeCoordinator(projectionStore: projectionStore)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
            copilot: copilot,
            openCode: openCode,
            claudeAdapter: RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        projectionStore.setProjection(
            SessionExecutionProjection(
                sessionID: harness.firstSession.sessionId,
                runningJobID: UUID(),
                queuedJobIDs: [],
                queuedCount: 0,
                isRunning: true,
                canEditComposer: true,
                canSubmitNewJob: true,
                activeProviderID: .githubCopilotCLI,
                currentPhase: .executing,
                activityState: .running,
                presentationState: .foreground,
                needsAttention: false,
                attentionReason: nil
            )
        )

        await coordinator.prepareForActivation(
            session: harness.secondSession,
            activeProvider: openCode,
            registry: registry,
            modelContext: harness.context,
            trigger: .selection
        )

        projectionStore.setProjection(
            SessionExecutionProjection(
                sessionID: harness.firstSession.sessionId,
                runningJobID: nil,
                queuedJobIDs: [],
                queuedCount: 0,
                isRunning: false,
                canEditComposer: true,
                canSubmitNewJob: true,
                activeProviderID: .githubCopilotCLI,
                currentPhase: nil,
                activityState: .idle,
                presentationState: .background,
                needsAttention: false,
                attentionReason: nil
            )
        )

        await coordinator.reconcileRuntimeRetention(
            registry: registry,
            modelContext: harness.context
        )

        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)))
        #expect(openCode.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)))
    }
}

@MainActor
private final class RuntimeCoordinatorTestProvider: ConversationExecutionProvider {
    struct ReleaseEvent: Equatable {
        let localSessionID: String
        let reason: ConversationExecutionRuntimeReleaseReason
    }

    let id: ConversationExecutionProviderID
    let runtimeScope: ConversationExecutionRuntimeScope?

    private(set) var activePreparationEvents: [String] = []
    private(set) var releasedRuntimeEvents: [ReleaseEvent] = []

    init(id: ConversationExecutionProviderID, runtimeScope: ConversationExecutionRuntimeScope?) {
        self.id = id
        self.runtimeScope = runtimeScope
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

    func resetSessionState(session: Session, modelContext: ModelContext) async {
        _ = session
        _ = modelContext
    }

    func prepareForActivation(
        session: Session,
        isActiveProvider: Bool,
        modelContext: ModelContext,
        trigger: ConversationExecutionActivationTrigger
    ) async {
        _ = modelContext
        _ = trigger
        guard isActiveProvider else { return }
        activePreparationEvents.append(session.sessionId)
    }

    func releasePreparedRuntime(
        localSessionID: String,
        modelContext: ModelContext,
        reason: ConversationExecutionRuntimeReleaseReason
    ) async {
        _ = modelContext
        releasedRuntimeEvents.append(.init(localSessionID: localSessionID, reason: reason))
    }
}