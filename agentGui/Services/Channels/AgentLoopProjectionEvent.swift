import Foundation

enum AgentLoopProjectionEvent: Equatable, Sendable {
    case textSnapshot(
        accumulatedText: String,
        currentRoundText: String,
        roundIndex: Int,
        isForced: Bool
    )
    case thinkingSnapshot(
        accumulatedThinking: String,
        roundIndex: Int,
        isForced: Bool
    )
    case stopReason(String?)
    case toolEvent(name: String, status: String)
    case completed(finalText: String)
    case failed(summary: String)
}
