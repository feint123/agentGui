import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ConversationExecutionRecoveryTests {
    @Test
    func restorePendingJobsStartsOtherSessionWhileFirstActivationIsStillBlocked() async throws {
        let harness = try ParallelDispatchHarness.make()
        let firstSession = try harness.makeSession(id: "parallel-a")
        let secondSession = try harness.makeSession(id: "parallel-b")

        try await harness.seedQueuedPrompt(text: "first", in: firstSession)
        try await harness.seedQueuedPrompt(text: "second", in: secondSession)

        let restoreTask = Task {
            await harness.orchestrator.restorePendingJobs()
        }

        #expect(await harness.provider.waitUntilActivationStarts(for: firstSession.sessionId))

        #expect(await waitUntilTrue {
            harness.provider.sentSessionIDs.contains(secondSession.sessionId)
        })
        #expect(harness.provider.sentSessionIDs.contains(firstSession.sessionId) == false)

        harness.provider.releaseActivation(for: firstSession.sessionId)
        await restoreTask.value
        await Task.yield()
    }

    @Test
    func restorePendingJobsRecoversBackgroundSessionWithoutSelectionBootstrap() async throws {
        let harness = try ExecutionRecoveryHarness.make()
        try await harness.seedRecoverableRunningJob(sessionID: "background-a")

        await harness.orchestrator.restorePendingJobs()
        await Task.yield()

        let projection = harness.projectionStore.projection(for: "background-a")
        #expect(projection.activeProviderID == .builtInAgent)
        #expect(projection.isRunning || projection.queuedCount > 0)
        #expect(projection.activityState == .running || projection.activityState == .queued)

        await harness.provider.releaseAll()
    }

    @Test
    func finishingAnotherSessionPrunesStaleQueueHeadAndDispatchesNextValidJob() async throws {
        let harness = try ExecutionRecoveryHarness.make(maxConcurrentJobs: 1)
        let blocker = try await harness.makeSession(id: "blocker")
        let target = try await harness.makeSession(id: "target")

        let blockerHandle = try await harness.enqueuePrompt(text: "blocker", in: blocker)
        await Task.yield()

        _ = blockerHandle
        let staleHandle = try await harness.enqueuePrompt(text: "stale", in: target)
        let validHandle = try await harness.enqueuePrompt(text: "valid", in: target)
        let staleMailboxJobID = UUID()
        let mailbox = try #require(harness.mailbox(for: target.sessionId))
        _ = await mailbox.discardQueuedJob(jobID: staleHandle.jobID)
        _ = await mailbox.discardQueuedJob(jobID: validHandle.jobID)
        await mailbox.enqueue(jobID: staleMailboxJobID)
        await mailbox.enqueue(jobID: validHandle.jobID)
        harness.projectionStore.setProjection(
            SessionExecutionProjection(
                sessionID: target.sessionId,
                runningJobID: nil,
                queuedJobIDs: [staleMailboxJobID, validHandle.jobID],
                queuedCount: 2,
                isRunning: false,
                canEditComposer: true,
                canSubmitNewJob: true,
                activeProviderID: .builtInAgent,
                currentPhase: nil,
                activityState: .queued,
                presentationState: .foreground,
                needsAttention: false,
                attentionReason: nil
            )
        )

        harness.provider.releaseAll()
        await waitUntil {
            let projection = harness.projectionStore.projection(for: target.sessionId)
            return projection.runningJobID == validHandle.jobID
        }

        let projection = harness.projectionStore.projection(for: target.sessionId)
        #expect(projection.runningJobID == validHandle.jobID)
        #expect(projection.queuedJobIDs.contains(staleMailboxJobID) == false)
        #expect(projection.activityState == .running)

        await harness.provider.releaseAll()
    }

    @Test
    func restorePendingJobsPreservesDynamicExternalProviderReference() async throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let projectionStore = ExecutionProjectionStore()
        let dynamicReference = ExecutionProviderReference.externalACP(profileID: UUID())
        let dynamicProvider = BlockingExecutionProvider(reference: dynamicReference, runtimeScope: .externalACP)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: NoOpExecutionProvider(id: .builtInAgent, runtimeScope: .builtIn),
            externalProviders: [dynamicReference: dynamicProvider]
        )
        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: context,
            persistenceStore: ExecutionPersistenceStore(
                modelContext: context,
                persistenceCoordinator: PersistenceCoordinator()
            ),
            projectionStore: projectionStore,
            scheduler: ExecutionScheduler(maxConcurrentJobs: 1),
            runtimePool: ExecutionRuntimePool(),
            providerRegistry: registry,
            runtimeCoordinator: ConversationExecutionRuntimeCoordinator(projectionStore: projectionStore)
        )

        let session = Session.fixture(sessionId: "dynamic-session", title: "Dynamic")
        session.defaultExecutionProviderReference = dynamicReference
        let userMessage = Message.userMessage(text: "dynamic prompt", session: session)
        userMessage.status = .completed
        context.insert(session)
        context.insert(userMessage)
        try context.save()

        let store = ExecutionPersistenceStore(
            modelContext: context,
            persistenceCoordinator: PersistenceCoordinator()
        )
        _ = try await store.enqueue(
            sessionID: session.sessionId,
            providerReference: dynamicReference,
            payload: .userPrompt(
                text: "dynamic prompt",
                modelID: "test-model",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: userMessage.id
        )

        await orchestrator.restorePendingJobs()
        await Task.yield()

        let projection = projectionStore.projection(for: session.sessionId)
        #expect(projection.activeProviderReference == dynamicReference)
        #expect(projection.isRunning || projection.queuedCount > 0)

        await dynamicProvider.releaseAll()
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while !condition() && ContinuousClock.now < deadline {
        await Task.yield()
    }
}

@MainActor
private func waitUntilTrue(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while !condition() && ContinuousClock.now < deadline {
        await Task.yield()
    }
    return condition()
}

@MainActor
private struct ExecutionRecoveryHarness {
    let context: ModelContext
    let orchestrator: ConversationExecutionOrchestrator
    let projectionStore: ExecutionProjectionStore
    let provider: BlockingExecutionProvider

    static func make(maxConcurrentJobs: Int = 2) throws -> ExecutionRecoveryHarness {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let projectionStore = ExecutionProjectionStore()
        let provider = BlockingExecutionProvider(id: .builtInAgent, runtimeScope: .builtIn)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: provider,
            externalProviders: [
                LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference: NoOpExecutionProvider(id: .githubCopilotCLI, runtimeScope: .externalACP),
                LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference: NoOpExecutionProvider(id: .openCodeCLI, runtimeScope: .externalACP),
                LegacyExternalACPProviderKey.claudeAdapterCLI.compatibilityReference: NoOpExecutionProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
            ]
        )
        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: context,
            persistenceStore: ExecutionPersistenceStore(
                modelContext: context,
                persistenceCoordinator: PersistenceCoordinator()
            ),
            projectionStore: projectionStore,
            scheduler: ExecutionScheduler(maxConcurrentJobs: maxConcurrentJobs),
            runtimePool: ExecutionRuntimePool(),
            providerRegistry: registry,
            runtimeCoordinator: ConversationExecutionRuntimeCoordinator()
        )

        return ExecutionRecoveryHarness(
            context: context,
            orchestrator: orchestrator,
            projectionStore: projectionStore,
            provider: provider
        )
    }

    func makeSession(id: String) throws -> Session {
        let session = Session.fixture(sessionId: id, title: id)
        let userMessage = Message.userMessage(text: "prompt-\(id)", session: session)
        userMessage.status = .completed
        context.insert(session)
        context.insert(userMessage)
        try context.save()
        return session
    }

    func enqueuePrompt(text: String, in session: Session) async throws -> ExecutionJobHandle {
        let userMessage = try #require(
            session.messages.last(where: { $0.direction == .user })
        )
        return try await orchestrator.enqueue(
            EnqueueExecutionCommand(
                sessionID: session.sessionId,
                providerID: .builtInAgent,
                payload: .userPrompt(
                    text: text,
                    modelID: "test-model",
                    selectedFilePath: nil,
                    selectedText: nil,
                    directives: []
                ),
                sourceUserMessageID: userMessage.id
            )
        )
    }

    func mailbox(for sessionID: String) -> SessionExecutionMailbox? {
        let mirror = Mirror(reflecting: orchestrator)
        guard let mailboxes = mirror.children.first(where: { $0.label == "mailboxes" })?.value as? [String: SessionExecutionMailbox] else {
            return nil
        }

        return mailboxes[sessionID]
    }

    func seedRecoverableRunningJob(sessionID: String) async throws {
        let session = Session.fixture(sessionId: sessionID, title: "Background Session")
        let userMessage = Message.userMessage(text: "resume me", session: session)
        userMessage.status = .completed
        context.insert(session)
        context.insert(userMessage)
        try context.save()

        let persistenceStore = ExecutionPersistenceStore(
            modelContext: context,
            persistenceCoordinator: PersistenceCoordinator()
        )
        let enqueueResult = try await persistenceStore.enqueue(
            sessionID: sessionID,
            providerID: .builtInAgent,
            payload: .userPrompt(
                text: "resume me",
                modelID: "test-model",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: userMessage.id
        )
        _ = try persistenceStore.start(jobID: enqueueResult.job.id, runtimeScope: .builtIn)
    }
}

@MainActor
private struct ParallelDispatchHarness {
    let context: ModelContext
    let orchestrator: ConversationExecutionOrchestrator
    let provider: ActivationBlockingExecutionProvider

    static func make() throws -> ParallelDispatchHarness {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let provider = ActivationBlockingExecutionProvider(blockedSessionIDs: ["parallel-a"])
        let registry = ConversationExecutionProviderRegistry(
            builtIn: NoOpExecutionProvider(id: .builtInAgent, runtimeScope: .builtIn),
            externalProviders: [
                provider.reference: provider,
                LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference: NoOpExecutionProvider(id: .openCodeCLI, runtimeScope: .externalACP),
                LegacyExternalACPProviderKey.claudeAdapterCLI.compatibilityReference: NoOpExecutionProvider(id: .claudeAdapterCLI, runtimeScope: .externalACP)
            ]
        )
        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: context,
            persistenceStore: ExecutionPersistenceStore(
                modelContext: context,
                persistenceCoordinator: PersistenceCoordinator()
            ),
            projectionStore: ExecutionProjectionStore(),
            scheduler: ExecutionScheduler(maxConcurrentJobs: 2),
            runtimePool: ExecutionRuntimePool(),
            providerRegistry: registry,
            runtimeCoordinator: ConversationExecutionRuntimeCoordinator()
        )

        return ParallelDispatchHarness(
            context: context,
            orchestrator: orchestrator,
            provider: provider
        )
    }

    func makeSession(id: String) throws -> Session {
        let session = Session.fixture(sessionId: id, title: id)
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        let userMessage = Message.userMessage(text: "prompt-\(id)", session: session)
        userMessage.status = .completed
        context.insert(session)
        context.insert(userMessage)
        try context.save()
        return session
    }

    func enqueuePrompt(text: String, in session: Session) async throws -> ExecutionJobHandle {
        let userMessage = try #require(session.messages.last(where: { $0.direction == .user }))
        return try await orchestrator.enqueue(
            EnqueueExecutionCommand(
                sessionID: session.sessionId,
                providerID: .githubCopilotCLI,
                payload: .userPrompt(
                    text: text,
                    modelID: "test-model",
                    selectedFilePath: nil,
                    selectedText: nil,
                    directives: []
                ),
                sourceUserMessageID: userMessage.id
            )
        )
    }

    func seedQueuedPrompt(text: String, in session: Session) async throws {
        let userMessage = try #require(session.messages.last(where: { $0.direction == .user }))
        let store = ExecutionPersistenceStore(
            modelContext: context,
            persistenceCoordinator: PersistenceCoordinator()
        )

        _ = try await store.enqueue(
            sessionID: session.sessionId,
            providerID: .githubCopilotCLI,
            payload: .userPrompt(
                text: text,
                modelID: "test-model",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: userMessage.id
        )
    }
}

@MainActor
private final class BlockingExecutionProvider: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID
    let reference: ExecutionProviderReference
    let legacyProviderID: ConversationExecutionProviderID?
    let runtimeScope: ConversationExecutionRuntimeScope?

    private var continuations: [CheckedContinuation<Void, Never>] = []

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
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
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
        releaseAll()
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
        _ = session
        _ = isActiveProvider
        _ = modelContext
        _ = trigger
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

@MainActor
private final class ActivationBlockingExecutionProvider: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID = .githubCopilotCLI
    let reference: ExecutionProviderReference = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
    let legacyProviderID: ConversationExecutionProviderID? = .githubCopilotCLI
    let runtimeScope: ConversationExecutionRuntimeScope? = .externalACP

    private let blockedSessionIDs: Set<String>
    private var activationContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var activationStartedSessionIDs = Set<String>()
    private var activationWaitContinuations: [String: CheckedContinuation<Bool, Never>] = [:]

    private(set) var sentSessionIDs: [String] = []

    init(blockedSessionIDs: Set<String>) {
        self.blockedSessionIDs = blockedSessionIDs
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        sentSessionIDs.append(request.session.sessionId)
        if let targetAgentMessageID = request.targetAgentMessageID,
           let message = request.session.messages.first(where: { $0.id == targetAgentMessageID }) {
            message.status = .completed
            message.textContent = request.text
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
        _ = modelContext
        releaseActivation(for: session.sessionId)
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

        activationStartedSessionIDs.insert(session.sessionId)
        if let continuation = activationWaitContinuations.removeValue(forKey: session.sessionId) {
            continuation.resume(returning: true)
        }

        guard blockedSessionIDs.contains(session.sessionId) else {
            return
        }

        await withCheckedContinuation { continuation in
            activationContinuations[session.sessionId] = continuation
        }
    }

    func waitUntilActivationStarts(
        for sessionID: String
    ) async -> Bool {
        if activationStartedSessionIDs.contains(sessionID) {
            return true
        }

        return await withCheckedContinuation { continuation in
            activationWaitContinuations[sessionID] = continuation
        }
    }

    func releaseActivation(for sessionID: String) {
        guard let continuation = activationContinuations.removeValue(forKey: sessionID) else {
            return
        }
        continuation.resume()
    }
}

@MainActor
private final class NoOpExecutionProvider: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID
    let reference: ExecutionProviderReference
    let legacyProviderID: ConversationExecutionProviderID?
    let runtimeScope: ConversationExecutionRuntimeScope?

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
}