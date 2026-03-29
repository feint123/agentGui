import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatMessageListProjectionModelConcurrencyTests {
    @Test
    func staleGenerationResultIsDropped() async {
        let session = Session.fixture(sessionId: "stale-generation", title: "Stale Generation")
        let slowMessage = Message.userMessage(text: "older", session: session)
        slowMessage.status = .completed

        let fastMessage = Message.userMessage(text: "newer", session: session)
        fastMessage.status = .completed

        let worker = ProjectionWorkerProbe()
        let model = ChatMessageListProjectionModel(worker: worker)

        let slowRefresh = Task {
            await model.refresh(messages: [slowMessage], workspaceRoot: "/tmp/ws", showsLoadingPlaceholder: true)
        }
        await worker.waitForStart(of: 1)

        let fastRefresh = Task {
            await model.refresh(messages: [fastMessage], workspaceRoot: "/tmp/ws")
        }
        await worker.waitForStart(of: 2)

        await worker.finishGeneration(1)
        #expect(model.snapshot.rows.isEmpty)
        #expect(model.isInitialLoadInFlight == true)

        await worker.finishGeneration(2)
        await slowRefresh.value
        await fastRefresh.value
        #expect(model.snapshot.rows.map(\.id) == [fastMessage.id])
        #expect(model.isInitialLoadInFlight == false)
    }

    @Test
    func refreshCancelsSupersededBuildTask() async {
        let session = Session.fixture(sessionId: "cancel-generation", title: "Cancel Generation")
        let firstMessage = Message.userMessage(text: "one", session: session)
        let secondMessage = Message.userMessage(text: "two", session: session)
        firstMessage.status = .completed
        secondMessage.status = .completed

        let worker = ProjectionWorkerProbe()
        let model = ChatMessageListProjectionModel(worker: worker)

        let firstRefresh = Task {
            await model.refresh(messages: [firstMessage], workspaceRoot: "/tmp/ws")
        }
        await worker.waitForStart(of: 1)

        let secondRefresh = Task {
            await model.refresh(messages: [secondMessage], workspaceRoot: "/tmp/ws")
        }
        await worker.waitForStart(of: 2)
        await worker.waitForCancellation(of: 1)
        await worker.finishGeneration(2)
        await firstRefresh.value
        await secondRefresh.value

        #expect(await worker.wasCancelled(generation: 1))
    }

    @Test
    func latestGenerationPublishesImmediatelyEvenIfEarlierWorkIsStillRunning() async {
        let session = Session.fixture(sessionId: "latest-generation", title: "Latest Generation")
        let slowMessage = Message.userMessage(text: "slow", session: session)
        let fastMessage = Message.userMessage(text: "fast", session: session)
        slowMessage.status = .completed
        fastMessage.status = .completed

        let worker = ProjectionWorkerProbe()
        let model = ChatMessageListProjectionModel(worker: worker)

        let slowRefresh = Task {
            await model.refresh(messages: [slowMessage], workspaceRoot: "/tmp/ws", showsLoadingPlaceholder: true)
        }
        await worker.waitForStart(of: 1)

        let fastRefresh = Task {
            await model.refresh(messages: [fastMessage], workspaceRoot: "/tmp/ws")
        }
        await worker.waitForStart(of: 2)

        await worker.finishGeneration(2)
        await fastRefresh.value

        #expect(model.snapshot.rows.map(\.id) == [fastMessage.id])
        #expect(model.isInitialLoadInFlight == false)

        await worker.waitForCancellation(of: 1)
        await slowRefresh.value
    }
}

private actor ProjectionWorkerProbe: ChatMessageListProjectionWorking {
    private var pendingBuilds: [UInt64: CheckedContinuation<ChatMessageListBuildResult, Error>] = [:]
    private var pendingRequests: [UInt64: ChatMessageListBuildRequest] = [:]
    private var startedGenerations: Set<UInt64> = []
    private var cancelledGenerations: Set<UInt64> = []
    private var startWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    func build(request: ChatMessageListBuildRequest) async throws -> ChatMessageListBuildResult {
        let generation = request.generation
        startedGenerations.insert(generation)
        startWaiters.removeValue(forKey: generation)?.resume()
        pendingRequests[generation] = request

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pendingBuilds[generation] = continuation
            }
        }, onCancel: {
            Task {
                await self.handleCancellation(for: generation)
            }
        })
    }

    func finishGeneration(_ generation: UInt64) {
        guard let continuation = pendingBuilds.removeValue(forKey: generation),
              let request = pendingRequests.removeValue(forKey: generation) else {
            return
        }

        let rows = request.messages.map { MessageRowSnapshot.make(for: $0, workspaceRoot: request.workspaceRoot) }
        let cache = Dictionary(uniqueKeysWithValues: zip(request.messages, rows).map { message, row in
            (
                message.id,
                CachedMessageRowSnapshot(
                    semanticFingerprint: MessageRowFingerprint(message),
                    workspaceDependency: message.workspaceDependency,
                    snapshot: row
                )
            )
        })
        let result = ChatMessageListBuildResult(
            generation: generation,
            snapshot: ChatMessageListSnapshot(rows: rows, cache: cache),
            rebuiltRowIDs: request.messages.map(\.id),
            reusedRowCount: 0
        )
        continuation.resume(returning: result)
    }

    func waitForStart(of generation: UInt64) async {
        if startedGenerations.contains(generation) {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters[generation] = continuation
        }
    }

    func wasCancelled(generation: UInt64) -> Bool {
        cancelledGenerations.contains(generation)
    }

    func waitForCancellation(of generation: UInt64) async {
        for _ in 0..<50 {
            if cancelledGenerations.contains(generation) {
                return
            }
            await Task.yield()
        }
    }

    private func handleCancellation(for generation: UInt64) {
        cancelledGenerations.insert(generation)
        pendingRequests.removeValue(forKey: generation)
        pendingBuilds.removeValue(forKey: generation)?.resume(throwing: CancellationError())
    }
}