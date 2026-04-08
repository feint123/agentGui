import Testing
import Foundation
@testable import agentGui

@MainActor
struct ChatMessageListStreamingThrottleIntegrationTests {

    @Test
    func contentDeltaRefreshesAreCoalescedByTaskCancellation() async {
        // 验证：模型的 refresh() 在快速连续调用中只保留最新 generation 结果
        let session = Session.fixture(sessionId: "throttle-coalesce", title: "Throttle")
        let message = Message.agentMessage(text: "hello", session: session)
        message.status = .pending

        let worker = ProjectionWorkerProbeThrottle()
        let model = ChatMessageListProjectionModel(worker: worker)

        // 并发提交 3 次 refresh，模拟流式连续触发
        let r1 = Task { @MainActor in
            await model.refresh(messages: [message], workspaceRoot: "/ws")
        }
        await worker.waitForStart(of: 1)

        message.textContent = "hello world"
        let r2 = Task { @MainActor in
            await model.refresh(messages: [message], workspaceRoot: "/ws")
        }
        await worker.waitForStart(of: 2)
        await worker.waitForCancellation(of: 1)   // generation 1 被取消

        message.textContent = "hello world today"
        let r3 = Task { @MainActor in
            await model.refresh(messages: [message], workspaceRoot: "/ws")
        }
        await worker.waitForStart(of: 3)
        await worker.waitForCancellation(of: 2)   // generation 2 被取消

        await worker.finishGeneration(3)
        await r1.value
        await r2.value
        await r3.value

        // 最终 snapshot 非空（generation 3 完成）
        #expect(model.snapshot.rows.isEmpty == false)
    }
}

// MARK: - Private Probe (本文件专用，避免与 ProjectionWorkerProbe 重名)

private actor ProjectionWorkerProbeThrottle: ChatMessageListProjectionWorking {
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
                    semanticFingerprint: MessageRowSemanticFingerprint(message),
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
        if startedGenerations.contains(generation) { return }
        await withCheckedContinuation { continuation in
            startWaiters[generation] = continuation
        }
    }

    func waitForCancellation(of generation: UInt64) async {
        for _ in 0..<50 {
            if cancelledGenerations.contains(generation) { return }
            await Task.yield()
        }
    }

    private func handleCancellation(for generation: UInt64) {
        cancelledGenerations.insert(generation)
        pendingRequests.removeValue(forKey: generation)
        pendingBuilds.removeValue(forKey: generation)?.resume(throwing: CancellationError())
    }
}
