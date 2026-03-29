import Foundation
import Testing
import SwiftData
@testable import agentGui

@MainActor
struct ConversationExecutionRuntimeCoordinatorTests {
    @Test
    func foregroundActivationReleasesPreviousSessionLeaseAndSiblingProviders() async throws {
        let runtimeStateStore = SessionExecutionRuntimeStateStore()
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness(runtimeStateStore: runtimeStateStore)
        let coordinator = ConversationExecutionRuntimeCoordinator(runtimeStateStore: runtimeStateStore)
        let builtIn = RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = makeRegistry(
            builtIn: builtIn,
            providers: [
                copilot,
                openCode,
                RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
            ]
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
        let runtimeStateStore = SessionExecutionRuntimeStateStore()
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness(runtimeStateStore: runtimeStateStore)
        let coordinator = ConversationExecutionRuntimeCoordinator(runtimeStateStore: runtimeStateStore)
        let builtIn = RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let registry = makeRegistry(
            builtIn: builtIn,
            providers: [
                copilot,
                RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP),
                RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
            ]
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
        let runtimeStateStore = SessionExecutionRuntimeStateStore()
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness(runtimeStateStore: runtimeStateStore)
        let coordinator = ConversationExecutionRuntimeCoordinator(runtimeStateStore: runtimeStateStore)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = makeRegistry(
            builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
            providers: [
                copilot,
                openCode,
                RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
            ]
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
    func selectionSwitchKeepsExecutionDispatchLeaseBeforeProjectionTurnsRunning() async throws {
        let runtimeStateStore = SessionExecutionRuntimeStateStore()
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness(runtimeStateStore: runtimeStateStore)
        let coordinator = ConversationExecutionRuntimeCoordinator(runtimeStateStore: runtimeStateStore)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = makeRegistry(
            builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
            providers: [
                copilot,
                openCode,
                RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
            ]
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .executionDispatch
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
    }

    @Test
    func switchingProviderInSameSessionKeepsDispatchLeaseOwnerRuntime() async throws {
        let runtimeStateStore = SessionExecutionRuntimeStateStore()
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness(runtimeStateStore: runtimeStateStore)
        let coordinator = ConversationExecutionRuntimeCoordinator(runtimeStateStore: runtimeStateStore)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = makeRegistry(
            builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
            providers: [
                copilot,
                openCode,
                RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
            ]
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .executionDispatch
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: openCode,
            registry: registry,
            modelContext: harness.context,
            trigger: .selection
        )

        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .providerBecameInactive)) == false)
        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)) == false)
    }

    @Test
    func projectionLagsBehindRunningRuntimeButRetentionStillHolds() async throws {
        let runtimeStateStore = SessionExecutionRuntimeStateStore()
        let projectionStore = ExecutionProjectionStore()
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness(
            runtimeStateStore: runtimeStateStore,
            projectionStore: projectionStore
        )
        let coordinator = ConversationExecutionRuntimeCoordinator(runtimeStateStore: runtimeStateStore)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = makeRegistry(
            builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
            providers: [
                copilot,
                openCode,
                RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
            ]
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        runtimeStateStore.apply(
            .started(
                sessionID: harness.firstSession.sessionId,
                jobID: UUID(),
                providerReference: LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
            )
        )

        projectionStore.setProjection(.fixture(sessionID: harness.firstSession.sessionId))

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
    func projectionLagsBehindFinishedRuntimeButReconcileStillReleases() async throws {
        let runtimeStateStore = SessionExecutionRuntimeStateStore()
        let projectionStore = ExecutionProjectionStore()
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness(
            runtimeStateStore: runtimeStateStore,
            projectionStore: projectionStore
        )
        let coordinator = ConversationExecutionRuntimeCoordinator(runtimeStateStore: runtimeStateStore)
        let copilot = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
        let openCode = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
        let registry = makeRegistry(
            builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
            providers: [
                copilot,
                openCode,
                RuntimeCoordinatorTestProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
            ]
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: copilot,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        let runningJobID = UUID()
        runtimeStateStore.apply(
            .started(
                sessionID: harness.firstSession.sessionId,
                jobID: runningJobID,
                providerReference: LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
            )
        )

        projectionStore.setProjection(
            .fixture(
                sessionID: harness.firstSession.sessionId,
                runningJobID: runningJobID,
                activeProviderID: .githubCopilotCLI,
                currentPhase: .executing,
                activityState: .running
            )
        )

        await coordinator.prepareForActivation(
            session: harness.secondSession,
            activeProvider: openCode,
            registry: registry,
            modelContext: harness.context,
            trigger: .selection
        )

        runtimeStateStore.apply(
            .finished(
                sessionID: harness.firstSession.sessionId,
                jobID: runningJobID,
                outcome: .completed
            )
        )

        projectionStore.setProjection(
            .fixture(
                sessionID: harness.firstSession.sessionId,
                runningJobID: runningJobID,
                isRunning: true,
                activeProviderID: .githubCopilotCLI,
                currentPhase: .executing,
                activityState: .running,
                presentationState: .background
            )
        )

        await coordinator.reconcileRuntimeRetention(
            registry: registry,
            modelContext: harness.context
        )

        #expect(copilot.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)))
        #expect(openCode.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)))
    }

    @Test
    func selectionSwitchKeepsRunningDynamicProviderRuntimeRetainedByReference() async throws {
        let runtimeStateStore = SessionExecutionRuntimeStateStore()
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness(runtimeStateStore: runtimeStateStore)
        let coordinator = ConversationExecutionRuntimeCoordinator(runtimeStateStore: runtimeStateStore)
        let firstReference = ExecutionProviderReference.externalACP(profileID: UUID())
        let secondReference = ExecutionProviderReference.externalACP(profileID: UUID())
        let firstProvider = RuntimeCoordinatorTestProvider(reference: firstReference, runtimeScope: .externalACP)
        let secondProvider = RuntimeCoordinatorTestProvider(reference: secondReference, runtimeScope: .externalACP)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
            externalProviders: [
                firstReference: firstProvider,
                secondReference: secondProvider
            ]
        )

        await coordinator.prepareForActivation(
            session: harness.firstSession,
            activeProvider: firstProvider,
            registry: registry,
            modelContext: harness.context,
            trigger: .sessionBootstrap
        )

        runtimeStateStore.apply(
            .started(
                sessionID: harness.firstSession.sessionId,
                jobID: UUID(),
                providerReference: firstReference
            )
        )

        await coordinator.prepareForActivation(
            session: harness.secondSession,
            activeProvider: secondProvider,
            registry: registry,
            modelContext: harness.context,
            trigger: .selection
        )

        #expect(firstProvider.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)) == false)
        #expect(secondProvider.releasedRuntimeEvents.contains(.init(localSessionID: harness.firstSession.sessionId, reason: .sessionBecameInactive)) == false)
        #expect(secondProvider.activePreparationEvents == [harness.secondSession.sessionId])
    }
}

@MainActor
private func makeRegistry(
    builtIn: any ConversationExecutionProvider,
    providers: [any ConversationExecutionProvider]
) -> ConversationExecutionProviderRegistry {
    ConversationExecutionProviderRegistry(
        builtIn: builtIn,
        externalProviders: Dictionary(
            uniqueKeysWithValues: providers.map { ($0.reference, $0) }
        )
    )
}

@MainActor
private final class RuntimeCoordinatorTestProvider: ConversationExecutionProvider {
    struct ReleaseEvent: Equatable {
        let localSessionID: String
        let reason: ConversationExecutionRuntimeReleaseReason
    }

    let id: ConversationExecutionProviderID
    let reference: ExecutionProviderReference
    let legacyProviderID: ConversationExecutionProviderID?
    let runtimeScope: ConversationExecutionRuntimeScope?

    private(set) var activePreparationEvents: [String] = []
    private(set) var releasedRuntimeEvents: [ReleaseEvent] = []

    init(id: ConversationExecutionProviderID, runtimeScope: ConversationExecutionRuntimeScope?) {
        self.id = id
        self.legacyProviderID = id
        self.reference = switch id {
        case .builtInAgent:
            .builtIn
        case .githubCopilotCLI:
            LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        case .openCodeCLI:
            LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        case .claudeAdapterCLI:
            LegacyExternalACPProviderKey.claudeAdapterCLI.compatibilityReference
        }
        self.runtimeScope = runtimeScope
    }

    init(
        reference: ExecutionProviderReference,
        legacyProviderID: ConversationExecutionProviderID? = nil,
        runtimeScope: ConversationExecutionRuntimeScope?
    ) {
        self.id = legacyProviderID ?? .builtInAgent
        self.reference = reference
        self.legacyProviderID = legacyProviderID
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