import Foundation

@MainActor
protocol RemoteTurnDeliveryHandle: AnyObject {
    func receive(_ event: AgentLoopProjectionEvent) async
    func finish(finalText: String) async
    func fail(summary: String) async
}

@MainActor
final class RemoteTurnDeliveryCoordinator {
    typealias SessionFactory = @MainActor (ChannelProjectionContext) async throws -> (any ChannelProjectionSession)?

    private let textThreshold: Int
    private let thinkingThreshold: Int
    private let sessionFactory: SessionFactory

    init(
        textThreshold: Int = 120,
        thinkingThreshold: Int = 120,
        sessionFactory: @escaping SessionFactory
    ) {
        self.textThreshold = textThreshold
        self.thinkingThreshold = thinkingThreshold
        self.sessionFactory = sessionFactory
    }

    convenience init(
        textThreshold: Int = 120,
        thinkingThreshold: Int = 120,
        driver: (any ChannelProjectionDriver)?
    ) {
        self.init(textThreshold: textThreshold, thinkingThreshold: thinkingThreshold) { context in
            try await driver?.openSession(context: context)
        }
    }

    func beginTurn(context: ChannelProjectionContext) async -> any RemoteTurnDeliveryHandle {
        let session = try? await sessionFactory(context)
        return DeliveryHandle(
            session: session ?? nil,
            textThreshold: textThreshold,
            thinkingThreshold: thinkingThreshold
        )
    }
}

@MainActor
private final class DeliveryHandle: RemoteTurnDeliveryHandle {
    private var session: (any ChannelProjectionSession)?
    private let textThreshold: Int
    private let thinkingThreshold: Int
    private var lastForwardedTextLength = 0
    private var lastForwardedThinkingLength = 0
    private var pendingTextSnapshot: AgentLoopProjectionEvent?
    private var pendingThinkingSnapshot: AgentLoopProjectionEvent?
    private var closed = false

    init(
        session: (any ChannelProjectionSession)?,
        textThreshold: Int,
        thinkingThreshold: Int
    ) {
        self.session = session
        self.textThreshold = textThreshold
        self.thinkingThreshold = thinkingThreshold
    }

    func receive(_ event: AgentLoopProjectionEvent) async {
        guard !closed else { return }

        switch event {
        case .textSnapshot(let accumulatedText, _, _, let isForced):
            pendingTextSnapshot = event
            guard isForced || accumulatedText.count - lastForwardedTextLength >= textThreshold else {
                return
            }
            lastForwardedTextLength = accumulatedText.count
            pendingTextSnapshot = nil
            await send(event)

        case .thinkingSnapshot(let accumulatedThinking, _, let isForced):
            pendingThinkingSnapshot = event
            guard isForced || accumulatedThinking.count - lastForwardedThinkingLength >= thinkingThreshold else {
                return
            }
            lastForwardedThinkingLength = accumulatedThinking.count
            pendingThinkingSnapshot = nil
            await send(event)

        default:
            await send(event)
        }
    }

    func finish(finalText: String) async {
        guard !closed else { return }
        await flushPendingSnapshots()
        await send(.completed(finalText: finalText))
        await closeSession()
    }

    func fail(summary: String) async {
        guard !closed else { return }
        await flushPendingSnapshots()
        await send(.failed(summary: summary))
        await closeSession()
    }

    private func flushPendingSnapshots() async {
        if let event = pendingThinkingSnapshot {
            pendingThinkingSnapshot = nil
            await send(event)
        }
        if let event = pendingTextSnapshot {
            pendingTextSnapshot = nil
            await send(event)
        }
    }

    private func send(_ event: AgentLoopProjectionEvent) async {
        guard let session else { return }
        do {
            try await session.ingest(event)
        } catch {
            self.session = nil
        }
    }

    private func closeSession() async {
        closed = true
        guard let session else { return }
        await session.close()
        self.session = nil
    }
}
