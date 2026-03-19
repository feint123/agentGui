import Foundation
import SwiftData

struct ChannelInboundExecutionRequest: Sendable {
    let message: InboundChannelMessage
    let authorizationPolicy: ToolAuthorizationPolicy
    let executionPolicy: RemoteExecutionPolicy
    let modelContext: ModelContext
}

actor ChannelInboundTaskScheduler {
    typealias Executor = @MainActor @Sendable (ChannelInboundExecutionRequest) async throws -> Void
    typealias FailureHandler = @MainActor @Sendable (ChannelInboundExecutionRequest, Error) -> Void

    private struct ConversationKey: Hashable {
        let channelKind: IMChannelKind
        let externalConversationID: String
    }

    private struct ScheduledTask {
        let generation: Int
        let channelKind: IMChannelKind
        let task: Task<Void, Never>
    }

    private let executor: Executor
    private let failureHandler: FailureHandler
    private var scheduledTasks: [ConversationKey: ScheduledTask] = [:]
    private var nextGeneration = 0
    private var pendingTaskCount = 0
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        executor: @escaping Executor,
        failureHandler: @escaping FailureHandler = { _, _ in }
    ) {
        self.executor = executor
        self.failureHandler = failureHandler
    }

    func submit(_ request: ChannelInboundExecutionRequest) {
        let key = ConversationKey(
            channelKind: request.message.channelKind,
            externalConversationID: request.message.externalConversationID
        )
        let previousTask = scheduledTasks[key]?.task
        nextGeneration += 1
        let generation = nextGeneration
        pendingTaskCount += 1

        let task = Task { [executor, failureHandler] in
            _ = await previousTask?.result
            guard !Task.isCancelled else {
                await self.finishTask(for: key, generation: generation)
                return
            }

            do {
                try await executor(request)
            } catch {
                await failureHandler(request, error)
            }

            await self.finishTask(for: key, generation: generation)
        }

        scheduledTasks[key] = ScheduledTask(
            generation: generation,
            channelKind: request.message.channelKind,
            task: task
        )
    }

    func cancelTasks(for channelKind: IMChannelKind) {
        let matchingKeys = scheduledTasks.compactMap { key, value in
            value.channelKind == channelKind ? key : nil
        }
        for key in matchingKeys {
            scheduledTasks[key]?.task.cancel()
            scheduledTasks[key] = nil
        }
    }

    func waitUntilIdle() async {
        guard pendingTaskCount > 0 else { return }
        await withCheckedContinuation { continuation in
            idleContinuations.append(continuation)
        }
    }

    private func finishTask(for key: ConversationKey, generation: Int) {
        if scheduledTasks[key]?.generation == generation {
            scheduledTasks[key] = nil
        }
        pendingTaskCount = max(0, pendingTaskCount - 1)
        guard pendingTaskCount == 0 else { return }
        let continuations = idleContinuations
        idleContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }
}