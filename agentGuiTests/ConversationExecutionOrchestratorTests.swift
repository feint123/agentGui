import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ConversationExecutionOrchestratorTests {
    @Test func enqueueDispatchesQueuedJobThroughDriver() async throws {
        let harness = try ExecutionOrchestratorHarness.make()

        let handle = try await harness.orchestrator.enqueue(
            .fixture(
                sessionID: harness.session.sessionId,
                providerID: .githubCopilotCLI,
                sourceUserMessageID: harness.userMessage.id,
                text: "queued prompt",
                modelID: "gpt-5"
            )
        )

        await harness.driver.awaitStart(for: handle.jobID)

        let projection = harness.projectionStore.projection(for: harness.session.sessionId)
        #expect(projection.runningJobID == handle.jobID)
        #expect(projection.isRunning == true)
        #expect(projection.queuedCount == 0)
        #expect(harness.driver.executedJobIDs == [handle.jobID])
    }

    @Test func claudeServiceSendMessageRoutesThroughOrchestratorWithoutFeatureGate() async throws {
        let harness = try ClaudeServiceExecutionHarness.make()

        try await harness.service.sendMessage(
            text: "queued facade",
            session: harness.session,
            modelId: "test-model",
            modelContext: harness.modelContext
        )

        let jobID = try #require(harness.driver.executedJobIDs.first)
        await harness.driver.awaitStart(for: jobID)

        let projection = harness.projectionStore.projection(for: harness.session.sessionId)
        #expect(projection.runningJobID == jobID)
        #expect(projection.isRunning == true)
    }

    @Test func claudeServiceRegenerateRoutesThroughOrchestratorAndReplacesTrailingMessages() async throws {
        let harness = try ClaudeServiceExecutionHarness.make()
        let assistantMessage = Message.agentMessage(text: "old answer", session: harness.session)
        assistantMessage.status = .completed
        harness.modelContext.insert(assistantMessage)
        try harness.modelContext.save()

        try await harness.service.regenerate(
            session: harness.session,
            modelId: "test-model",
            modelContext: harness.modelContext
        )

        let jobID = try #require(harness.driver.executedJobIDs.first)
        await harness.driver.awaitStart(for: jobID)

        let jobs = try harness.modelContext.fetch(FetchDescriptor<ExecutionJob>())
        let job = try #require(jobs.first)
        switch try #require(job.payload) {
        case .userPrompt(let text, let modelID, _, _, _):
            #expect(text == "queued")
            #expect(modelID == "test-model")
        }

        let sessionMessages = harness.session.messages
        let hasOldAnswer = sessionMessages.contains(where: { $0.textContent == "old answer" })
        let hasPendingAgentMessage = sessionMessages.contains(where: { message in
            message.direction == .agent && message.status == .pending
        })

        #expect(hasOldAnswer == false)
        #expect(hasPendingAgentMessage)
    }

    @Test func claudeServiceEditAndResendRoutesThroughOrchestratorAndUpdatesTranscript() async throws {
        let harness = try ClaudeServiceExecutionHarness.make()
        let userMessage = try #require(
            harness.session.messages.sorted(by: { $0.sequence < $1.sequence }).last(where: { $0.direction == .user })
        )
        let assistantMessage = Message.agentMessage(text: "old answer", session: harness.session)
        assistantMessage.status = .completed
        harness.modelContext.insert(assistantMessage)
        try harness.modelContext.save()

        try await harness.service.editAndResend(
            message: userMessage,
            newText: "edited prompt",
            session: harness.session,
            modelId: "test-model",
            modelContext: harness.modelContext
        )

        let jobID = try #require(harness.driver.executedJobIDs.first)
        await harness.driver.awaitStart(for: jobID)

        let jobs = try harness.modelContext.fetch(FetchDescriptor<ExecutionJob>())
        let job = try #require(jobs.first)
        switch try #require(job.payload) {
        case .userPrompt(let text, let modelID, _, _, _):
            #expect(text == "edited prompt")
            #expect(modelID == "test-model")
        }

        let sessionMessages = harness.session.messages
        let hasOldAnswer = sessionMessages.contains(where: { $0.textContent == "old answer" })
        let hasPendingAgentMessage = sessionMessages.contains(where: { candidate in
            candidate.direction == .agent && candidate.status == .pending
        })

        #expect(userMessage.textContent == "edited prompt")
        #expect(hasOldAnswer == false)
        #expect(hasPendingAgentMessage)
    }

    @Test func completionDispatchesNextQueuedJobInSameSession() async throws {
        let harness = try ExecutionOrchestratorHarness.make()

        let firstHandle = try await harness.orchestrator.enqueue(
            .fixture(
                sessionID: harness.session.sessionId,
                providerID: .githubCopilotCLI,
                sourceUserMessageID: harness.userMessage.id,
                text: "first",
                modelID: "gpt-5"
            )
        )
        await harness.driver.awaitStart(for: firstHandle.jobID)

        let secondHandle = try await harness.orchestrator.enqueue(
            .fixture(
                sessionID: harness.session.sessionId,
                providerID: .githubCopilotCLI,
                sourceUserMessageID: harness.userMessage.id,
                text: "second",
                modelID: "gpt-5"
            )
        )

        var projection = harness.projectionStore.projection(for: harness.session.sessionId)
        #expect(projection.runningJobID == firstHandle.jobID)
        #expect(projection.queuedJobIDs == [secondHandle.jobID])

        await harness.driver.finish(jobID: firstHandle.jobID, outcome: .completed)
        await harness.driver.awaitStart(for: secondHandle.jobID)

        projection = harness.projectionStore.projection(for: harness.session.sessionId)
        #expect(projection.runningJobID == secondHandle.jobID)
        #expect(projection.queuedCount == 0)
        #expect(harness.driver.executedJobIDs == [firstHandle.jobID, secondHandle.jobID])
    }

    @Test func cancellingRunningJobDoesNotCancelQueuedJobsInSameSession() async throws {
        let harness = try ExecutionOrchestratorHarness.make()

        let runningHandle = try await harness.orchestrator.enqueue(
            .fixture(
                sessionID: harness.session.sessionId,
                providerID: .githubCopilotCLI,
                sourceUserMessageID: harness.userMessage.id,
                text: "running",
                modelID: "gpt-5"
            )
        )
        await harness.driver.awaitStart(for: runningHandle.jobID)

        let queuedHandle = try await harness.orchestrator.enqueue(
            .fixture(
                sessionID: harness.session.sessionId,
                providerID: .githubCopilotCLI,
                sourceUserMessageID: harness.userMessage.id,
                text: "queued",
                modelID: "gpt-5"
            )
        )

        await harness.orchestrator.cancelRunning(in: harness.session.sessionId)
        await harness.driver.awaitCancellation(for: runningHandle.jobID)
        await harness.driver.awaitStart(for: queuedHandle.jobID)

        let projection = harness.projectionStore.projection(for: harness.session.sessionId)
        let jobs = try harness.modelContext.fetch(FetchDescriptor<ExecutionJob>()).reduce(into: [UUID: ExecutionJob]()) {
            $0[$1.id] = $1
        }

        #expect(harness.driver.cancelledJobIDs == [runningHandle.jobID])
        #expect(jobs[runningHandle.jobID]?.state == .cancelled)
        #expect(projection.runningJobID == queuedHandle.jobID)
        #expect(projection.queuedCount == 0)
    }

    @Test func restorePendingJobsDispatchesPersistedQueuedJob() async throws {
        let persistenceHarness = try ExecutionPersistenceHarness.make()
        persistenceHarness.session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        let store = persistenceHarness.makeStore()
        let result = try await store.enqueue(
            sessionID: persistenceHarness.session.sessionId,
            providerID: .githubCopilotCLI,
            payload: .userPrompt(
                text: "restored queued",
                modelID: "gpt-5",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: persistenceHarness.userMessage.id
        )
        let projectionStore = ExecutionProjectionStore()
        let driver = DriverSpy(providerID: .githubCopilotCLI)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI),
            openCode: ProviderSpy(id: .openCodeCLI)
        )
        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: persistenceHarness.modelContext,
            persistenceStore: store,
            projectionStore: projectionStore,
            scheduler: ExecutionScheduler(maxConcurrentJobs: 2),
            runtimePool: ExecutionRuntimePool(driverFactory: { providerID, fallbackRegistry in
                if providerID == .githubCopilotCLI {
                    return driver
                }
                return fallbackRegistry.compatibilityDriver(for: providerID)
            }),
            providerRegistry: registry,
            runtimeCoordinator: ConversationExecutionRuntimeCoordinator()
        )

        await orchestrator.restorePendingJobs()
        await driver.awaitStart(for: result.job.id)

        let projection = projectionStore.projection(for: persistenceHarness.session.sessionId)
        #expect(projection.runningJobID == result.job.id)
        #expect(projection.isRunning == true)
    }

    @Test func restorePendingJobsRequeuesPersistedRunningJob() async throws {
        let persistenceHarness = try ExecutionPersistenceHarness.make()
        persistenceHarness.session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        let store = persistenceHarness.makeStore()
        let result = try await store.enqueue(
            sessionID: persistenceHarness.session.sessionId,
            providerID: .githubCopilotCLI,
            payload: .userPrompt(
                text: "restored running",
                modelID: "gpt-5",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: persistenceHarness.userMessage.id
        )
        let originalAttempt = try store.start(jobID: result.job.id, runtimeScope: .externalACP)

        let projectionStore = ExecutionProjectionStore()
        let driver = DriverSpy(providerID: .githubCopilotCLI)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI),
            openCode: ProviderSpy(id: .openCodeCLI)
        )
        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: persistenceHarness.modelContext,
            persistenceStore: store,
            projectionStore: projectionStore,
            scheduler: ExecutionScheduler(maxConcurrentJobs: 2),
            runtimePool: ExecutionRuntimePool(driverFactory: { providerID, fallbackRegistry in
                if providerID == .githubCopilotCLI {
                    return driver
                }
                return fallbackRegistry.compatibilityDriver(for: providerID)
            }),
            providerRegistry: registry,
            runtimeCoordinator: ConversationExecutionRuntimeCoordinator()
        )

        await orchestrator.restorePendingJobs()
        await driver.awaitStart(for: result.job.id)

        let attempts = try persistenceHarness.modelContext.fetch(FetchDescriptor<ExecutionAttempt>())
        let restoredOriginalAttempt = try #require(attempts.first(where: { $0.id == originalAttempt.id }))

        #expect(restoredOriginalAttempt.state == .interrupted)
        #expect(attempts.count == 2)
    }
}

@MainActor
private struct ExecutionOrchestratorHarness {
    let modelContext: ModelContext
    let session: Session
    let userMessage: Message
    let projectionStore: ExecutionProjectionStore
    let driver: DriverSpy
    let orchestrator: ConversationExecutionOrchestrator

    static func make() throws -> Self {
        let persistenceHarness = try ExecutionPersistenceHarness.make()
        persistenceHarness.session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        let projectionStore = ExecutionProjectionStore()
        let driver = DriverSpy(providerID: .githubCopilotCLI)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI),
            openCode: ProviderSpy(id: .openCodeCLI)
        )
        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: persistenceHarness.modelContext,
            persistenceStore: persistenceHarness.makeStore(),
            projectionStore: projectionStore,
            scheduler: ExecutionScheduler(maxConcurrentJobs: 1),
            runtimePool: ExecutionRuntimePool(driverFactory: { providerID, fallbackRegistry in
                if providerID == .githubCopilotCLI {
                    return driver
                }
                return fallbackRegistry.compatibilityDriver(for: providerID)
            }),
            providerRegistry: registry,
            runtimeCoordinator: ConversationExecutionRuntimeCoordinator()
        )

        return Self(
            modelContext: persistenceHarness.modelContext,
            session: persistenceHarness.session,
            userMessage: persistenceHarness.userMessage,
            projectionStore: projectionStore,
            driver: driver,
            orchestrator: orchestrator
        )
    }
}

private extension EnqueueExecutionCommand {
    static func fixture(
        sessionID: String,
        providerID: ConversationExecutionProviderID,
        sourceUserMessageID: UUID,
        text: String,
        modelID: String
    ) -> Self {
        EnqueueExecutionCommand(
            sessionID: sessionID,
            providerID: providerID,
            payload: .userPrompt(
                text: text,
                modelID: modelID,
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: sourceUserMessageID
        )
    }
}

@MainActor
private struct ClaudeServiceExecutionHarness {
    let modelContext: ModelContext
    let session: Session
    let projectionStore: ExecutionProjectionStore
    let driver: DriverSpy
    let service: ClaudeService

    static func make() throws -> Self {
        let persistenceHarness = try ExecutionPersistenceHarness.make()
        persistenceHarness.session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        let projectionStore = ExecutionProjectionStore()
        let driver = DriverSpy(providerID: .githubCopilotCLI)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI),
            openCode: ProviderSpy(id: .openCodeCLI)
        )
        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: persistenceHarness.modelContext,
            persistenceStore: persistenceHarness.makeStore(),
            projectionStore: projectionStore,
            scheduler: ExecutionScheduler(maxConcurrentJobs: 1),
            runtimePool: ExecutionRuntimePool(driverFactory: { providerID, fallbackRegistry in
                if providerID == .githubCopilotCLI {
                    return driver
                }
                return fallbackRegistry.compatibilityDriver(for: providerID)
            }),
            providerRegistry: registry,
            runtimeCoordinator: ConversationExecutionRuntimeCoordinator()
        )
        let service = ClaudeService()
        service.executionProjectionStore = projectionStore
        service.executionOrchestrator = orchestrator
        service.executionProviderRegistry = registry

        return Self(
            modelContext: persistenceHarness.modelContext,
            session: persistenceHarness.session,
            projectionStore: projectionStore,
            driver: driver,
            service: service
        )
    }
}

@MainActor
private final class ProviderSpy: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID

    init(id: ConversationExecutionProviderID) {
        self.id = id
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        if let targetAgentMessageID = request.targetAgentMessageID,
           let targetMessage = request.session.messages.first(where: { $0.id == targetAgentMessageID }) {
            targetMessage.status = .completed
            if targetMessage.textContent?.isEmpty ?? true {
                targetMessage.textContent = "done"
            }
            try? request.modelContext.save()
        }
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
}

@MainActor
private final class DriverSpy: ConversationExecutionDriver {
    private struct Awaiter {
        let jobID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    let providerID: ConversationExecutionProviderID
    let runtimeScope: ConversationExecutionRuntimeScope? = .externalACP

    private(set) var executedJobIDs: [UUID] = []
    private(set) var cancelledJobIDs: [UUID] = []
    private var finishContinuations: [UUID: AsyncThrowingStream<ExecutionDriverEvent, Error>.Continuation] = [:]
    private var startedJobIDs = Set<UUID>()
    private var cancelledJobs = Set<UUID>()
    private var startAwaiters: [Awaiter] = []
    private var cancelAwaiters: [Awaiter] = []

    init(providerID: ConversationExecutionProviderID) {
        self.providerID = providerID
    }

    func execute(_ job: ExecutionJob, context: ExecutionDriverContext) -> AsyncThrowingStream<ExecutionDriverEvent, Error> {
        _ = context
        return AsyncThrowingStream { continuation in
            self.executedJobIDs.append(job.id)
            self.startedJobIDs.insert(job.id)
            continuation.yield(.started(jobID: job.id))
            self.finishContinuations[job.id] = continuation
            self.resumeAwaiters(for: job.id, from: &self.startAwaiters)
        }
    }

    func cancel(jobID: UUID, sessionID: String) async {
        _ = sessionID
        cancelledJobIDs.append(jobID)
        cancelledJobs.insert(jobID)
        resumeAwaiters(for: jobID, from: &cancelAwaiters)
        if let continuation = finishContinuations.removeValue(forKey: jobID) {
            continuation.yield(.finished(jobID: jobID, outcome: .cancelled))
            continuation.finish()
        }
    }

    func finish(jobID: UUID, outcome: ExecutionJobState) async {
        guard let continuation = finishContinuations.removeValue(forKey: jobID) else {
            return
        }
        continuation.yield(.finished(jobID: jobID, outcome: outcome))
        continuation.finish()
    }

    func awaitStart(for jobID: UUID) async {
        if startedJobIDs.contains(jobID) {
            return
        }
        await withCheckedContinuation { continuation in
            startAwaiters.append(Awaiter(jobID: jobID, continuation: continuation))
        }
    }

    func awaitCancellation(for jobID: UUID) async {
        if cancelledJobs.contains(jobID) {
            return
        }
        await withCheckedContinuation { continuation in
            cancelAwaiters.append(Awaiter(jobID: jobID, continuation: continuation))
        }
    }

    private func resumeAwaiters(for jobID: UUID, from awaiters: inout [Awaiter]) {
        let ready = awaiters.filter { $0.jobID == jobID }
        awaiters.removeAll { $0.jobID == jobID }
        ready.forEach { $0.continuation.resume() }
    }
}