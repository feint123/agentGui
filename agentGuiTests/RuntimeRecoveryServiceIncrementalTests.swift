import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct RuntimeRecoveryServiceIncrementalTests {
    @Test
    func persistedRecoveryItemsPublishWithoutExposingModelInstances() async throws {
        let harness = try InMemoryAppHarness.makeRecoveryScenario()
        let service = harness.runtimeRecoveryService
        service.configurePersistence(container: harness.container)

        await service.scheduleBootstrapRefresh()
        await service.waitForRefreshForTesting()

        let items = service.recoveryItems(for: harness.session.sessionId)
        #expect(items.count == 1)
        #expect(items.first?.sourceKind == .messageGeneration)
        #expect(items.first?.sourceIdentifier == harness.session.messages.first(where: { $0.direction == .agent })?.id.uuidString)
    }

    @Test
    func bootstrapRefreshReturnsImmediatelyAndPublishesLater() async throws {
        let harness = try InMemoryAppHarness.makeRecoveryScenario()
        let service = harness.runtimeRecoveryService
        service.configurePersistence(container: harness.container)
        let clock = ContinuousClock()
        let start = clock.now

        await service.scheduleBootstrapRefresh()
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .milliseconds(50))
        #expect(service.recoveryItems(for: harness.session.sessionId).isEmpty)

        await service.waitForRefreshForTesting()

        #expect(service.recoveryItems(for: harness.session.sessionId).isEmpty == false)
    }

    @Test
    func reliabilityCenterViewModelConsumesPersistedRecoveryItems() async throws {
        let harness = try InMemoryAppHarness.makeRecoveryScenario()
        let service = harness.runtimeRecoveryService
        service.configurePersistence(container: harness.container)
        await service.scheduleBootstrapRefresh()
        await service.waitForRefreshForTesting()

        let viewModel = ReliabilityCenterViewModel()
        viewModel.bindRuntimeRecoveryService(service)
        viewModel.refresh(using: harness.context)

        #expect(viewModel.recoveryItems.count == 1)
        #expect(viewModel.recoveryItems.first?.sourceKind == .messageGeneration)
    }

    @Test
    func enqueueCreatesTargetedMessageRecoveryRefreshEvent() async throws {
        let harness = try InMemoryAppHarness.makeConversationScenario()
        let sink = RuntimeRecoveryRefreshSinkSpy()
        let store = ExecutionPersistenceStore(
            modelContext: harness.context,
            persistenceCoordinator: PersistenceCoordinator(),
            recoveryRefreshSink: sink
        )
        let userMessage = try #require(harness.session.messages.first(where: { $0.direction == .user }))

        let result = try await store.enqueue(
            sessionID: harness.session.sessionId,
            providerReference: .builtIn,
            payload: .userPrompt(
                text: "hello",
                modelID: "test-model",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: userMessage.id
        )

        #expect(await waitUntilTrue { sink.events.count == 1 })
        #expect(sink.events == [.messageChanged(messageIDs: [try #require(result.agentMessageID)])])
        #expect(sink.bootstrapRequests == 0)
    }

    @Test
    func finishRemovesResolvedMessageRecoveryWithoutFullBootstrap() async throws {
        let harness = try InMemoryAppHarness.makeConversationScenario()
        let sink = RuntimeRecoveryRefreshSinkSpy()
        let store = ExecutionPersistenceStore(
            modelContext: harness.context,
            persistenceCoordinator: PersistenceCoordinator(),
            recoveryRefreshSink: sink
        )
        let userMessage = try #require(harness.session.messages.first(where: { $0.direction == .user }))
        let enqueueResult = try await store.enqueue(
            sessionID: harness.session.sessionId,
            providerReference: .builtIn,
            payload: .userPrompt(
                text: "hello",
                modelID: "test-model",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: userMessage.id
        )
        let attempt = try store.start(jobID: enqueueResult.job.id, runtimeScope: nil)

        try store.finish(jobID: enqueueResult.job.id, attemptID: attempt.id, outcome: .completed)

        #expect(await waitUntilTrue { sink.events.count >= 2 })
        #expect(sink.events.contains(.messageChanged(messageIDs: [try #require(enqueueResult.agentMessageID)])))
        #expect(sink.bootstrapRequests == 0)
    }

    @Test
    func backgroundRunLifecycleSendsTargetedRefreshEvents() async throws {
        let harness = try InMemoryAppHarness.makeConversationScenario()
        let sink = RuntimeRecoveryRefreshSinkSpy()
        let observationService = BackgroundTaskObservationService(
            persistenceCoordinator: PersistenceCoordinator(),
            recoveryRefreshSink: sink
        )
        let task = BackgroundAgentTask.fixture(sessionId: harness.session.sessionId)
        harness.context.insert(task)
        try harness.context.save()

        let run = try observationService.recordTriggeredRun(
            for: task,
            schedulerIdentifier: "scheduler",
            modelContext: harness.context
        )
        observationService.recordStarted(task: task, run: run)
        observationService.recordCompleted(task: task, run: run, summary: "done")

        #expect(await waitUntilTrue { sink.events.count >= 3 })
        #expect(sink.events == [
            .backgroundTaskChanged(runIDs: [run.id]),
            .backgroundTaskChanged(runIDs: [run.id]),
            .backgroundTaskChanged(runIDs: [run.id])
        ])
        #expect(sink.bootstrapRequests == 0)
    }

    @Test
    func bootstrapReconcileRemovesVisibleSnapshotsWhoseSourcesAlreadyFinished() async throws {
        let harness = try InMemoryAppHarness.makeConversationScenario()
        let container = harness.container
        let context = ModelContext(container)
        let service = RuntimeRecoveryService()
        service.configurePersistence(container: container)

        let session = Session.fixture(sessionId: "finished-session", title: "Finished")
        let completedMessage = Message.agentFixture(
            text: "Complete response",
            session: session,
            status: .completed
        )
        let snapshot = RecoverySnapshot(
            id: completedMessage.id,
            sessionId: session.sessionId,
            sourceKind: .messageGeneration,
            sourceIdentifier: completedMessage.id.uuidString,
            summaryText: "未完成的回复：Complete response"
        )
        context.insert(session)
        context.insert(completedMessage)
        context.insert(snapshot)
        try context.save()

        await service.scheduleBootstrapRefresh()
        await service.waitForRefreshForTesting()

        #expect(service.recoveryItems(for: session.sessionId).isEmpty)
        let snapshots = try context.fetch(FetchDescriptor<RecoverySnapshot>())
        #expect(snapshots.isEmpty)
    }

    @Test
    func userActionsTriggerTargetedMutationAndFollowupRefresh() async throws {
        let harness = try InMemoryAppHarness.makeRecoveryScenario()
        let service = harness.runtimeRecoveryService
        service.configurePersistence(container: harness.container)

        await service.scheduleBootstrapRefresh()
        await service.waitForRefreshForTesting()

        let item = try #require(service.recoveryItems(for: harness.session.sessionId).first)
        try await service.clear(item)
        await service.waitForRefreshForTesting()

        #expect(service.recoveryItems(for: harness.session.sessionId).isEmpty)
        let snapshots = try harness.context.fetch(FetchDescriptor<RecoverySnapshot>())
        #expect(snapshots.allSatisfy { $0.handlingState == .cleared })
    }
}

@MainActor
private final class RuntimeRecoveryRefreshSinkSpy: RuntimeRecoveryRefreshSink {
    private(set) var events: [RuntimeRecoveryRefreshEvent] = []

    var bootstrapRequests: Int {
        events.filter {
            if case .bootstrap = $0 {
                return true
            }
            return false
        }.count
    }

    func enqueue(_ event: RuntimeRecoveryRefreshEvent) async {
        events.append(event)
    }
}

@MainActor
private func waitUntilTrue(
    timeoutNanoseconds: UInt64 = 500_000_000,
    condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while !condition() && ContinuousClock.now < deadline {
        await Task.yield()
    }
    return condition()
}