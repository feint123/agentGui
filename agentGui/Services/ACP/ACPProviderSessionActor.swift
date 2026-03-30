import Foundation

protocol ACPProviderSessionActorStepSink: AnyObject, Sendable {
    func record(_ step: ACPProviderSessionActorStep) async
}

nonisolated enum ACPProviderSessionActorStep: Sendable, Equatable {
    case beginPrompt(requestText: String)
    case promptStarted(remoteSessionID: String)
    case promptFinished(stopReason: ACPStopReason)
    case flushProjectedUpdates
    case finalizeAssistantMessage(requestText: String)
    case finishLiveTurn
    case cancelCleanup
    case failCleanup
}

actor ACPProviderSessionActor {
    struct PreparedTurn: Sendable {
        let requestText: String
        let localSessionID: String
        let remoteSessionID: String
        let promptText: String
        let beginPromptAction: @Sendable () async throws -> Void
        let promptAction: @Sendable () async throws -> ACPStopReason
        let drainPendingUpdatesAction: @Sendable () async -> Void
        let flushProjectedUpdatesAction: @Sendable () async -> Void
        let finalizeAssistantMessageAction: @Sendable (ACPStopReason) async -> Void
        let cancellationCleanupAction: @Sendable () async -> Void
        let failureCleanupAction: @Sendable (Error) async -> Void
        let finishLiveTurnAction: @Sendable () async -> Void
    }

    struct Hooks: Sendable {
        let beginPrompt: @Sendable (PreparedTurn) async throws -> Void
        let prompt: @Sendable (PreparedTurn) async throws -> ACPStopReason
        let drainPendingUpdates: @Sendable (String) async -> Void
        let flushProjectedUpdates: @Sendable (PreparedTurn) async -> Void
        let finalizeAssistantMessage: @Sendable (PreparedTurn, ACPStopReason) async -> Void
        let handleCancellation: @Sendable (PreparedTurn) async -> Void
        let handleFailure: @Sendable (PreparedTurn, Error) async -> Void
        let finishLiveTurn: @Sendable (PreparedTurn) async -> Void

        init(
            beginPrompt: @escaping @Sendable (PreparedTurn) async throws -> Void = { _ in },
            prompt: @escaping @Sendable (PreparedTurn) async throws -> ACPStopReason = { _ in .endTurn },
            drainPendingUpdates: @escaping @Sendable (String) async -> Void = { _ in },
            flushProjectedUpdates: @escaping @Sendable (PreparedTurn) async -> Void = { _ in },
            finalizeAssistantMessage: @escaping @Sendable (PreparedTurn, ACPStopReason) async -> Void = { _, _ in },
            handleCancellation: @escaping @Sendable (PreparedTurn) async -> Void = { _ in },
            handleFailure: @escaping @Sendable (PreparedTurn, Error) async -> Void = { _, _ in },
            finishLiveTurn: @escaping @Sendable (PreparedTurn) async -> Void = { _ in }
        ) {
            self.beginPrompt = beginPrompt
            self.prompt = prompt
            self.drainPendingUpdates = drainPendingUpdates
            self.flushProjectedUpdates = flushProjectedUpdates
            self.finalizeAssistantMessage = finalizeAssistantMessage
            self.handleCancellation = handleCancellation
            self.handleFailure = handleFailure
            self.finishLiveTurn = finishLiveTurn
        }

        static func passthrough() -> Self {
            Self(
                beginPrompt: { turn in
                    try await turn.beginPromptAction()
                },
                prompt: { turn in
                    try await turn.promptAction()
                },
                drainPendingUpdates: { _ in },
                flushProjectedUpdates: { turn in
                    await turn.flushProjectedUpdatesAction()
                },
                finalizeAssistantMessage: { turn, stopReason in
                    await turn.finalizeAssistantMessageAction(stopReason)
                },
                handleCancellation: { turn in
                    await turn.cancellationCleanupAction()
                },
                handleFailure: { turn, error in
                    await turn.failureCleanupAction(error)
                },
                finishLiveTurn: { turn in
                    await turn.finishLiveTurnAction()
                }
            )
        }
    }

    let localSessionID: String
    private let hooks: Hooks
    private var hasActiveSend = false
    private var waitingSenders: [CheckedContinuation<Void, Never>] = []

    init(localSessionID: String, hooks: Hooks) {
        self.localSessionID = localSessionID
        self.hooks = hooks
    }

    func sendPreparedTurn(_ turn: PreparedTurn) async throws {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        try await hooks.beginPrompt(turn)

        do {
            let stopReason = try await hooks.prompt(turn)
            await turn.drainPendingUpdatesAction()
            await hooks.drainPendingUpdates(turn.localSessionID)
            await hooks.flushProjectedUpdates(turn)
            await hooks.finalizeAssistantMessage(turn, stopReason)
            await hooks.finishLiveTurn(turn)
        } catch is CancellationError {
            await hooks.flushProjectedUpdates(turn)
            await hooks.handleCancellation(turn)
            throw CancellationError()
        } catch {
            await hooks.flushProjectedUpdates(turn)
            await hooks.handleFailure(turn, error)
            throw error
        }
    }

    private func acquireSendSlot() async {
        guard hasActiveSend else {
            hasActiveSend = true
            return
        }

        await withCheckedContinuation { continuation in
            waitingSenders.append(continuation)
        }
    }

    private func releaseSendSlot() {
        guard waitingSenders.isEmpty == false else {
            hasActiveSend = false
            return
        }

        let next = waitingSenders.removeFirst()
        next.resume()
    }
}