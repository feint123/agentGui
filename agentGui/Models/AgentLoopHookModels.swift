import Foundation
import SwiftAnthropic

enum AgentLoopStreamProjectionTarget {
    case none
    case message(Message)
    case workflowAction((String) -> Void)
}

enum AgentLoopHookStage {
    case prepareRun
    case didStartRun
    case didApplyBootstrap
    case willStartRound
    case didReceiveTextDelta
    case didReceiveThinkingDelta
    case didResolveStopReason
    case didCompleteRoundPersistence
    case didDiscoverToolCall
    case willExecuteTool
    case didExecuteTool
    case didClassifyToolFailure
    case didAppendToolResults
    case classifyFailureTrigger
    case prepareContinuation
    case prepareResumeAfterPause
    case decideFinalization
    case willFinishRun
    case didFinishRun
    case didFailRun
}

enum AgentLoopHookKind {
    case observer
    case mutator
    case decisionMaker
}

enum FinalizationDecision: Equatable {
    case allow
    case retry(prompt: String?)
    case fail(reason: String?)
}

enum AgentLoopDecision: Equatable {
    case finalization(FinalizationDecision)
}

struct AgentLoopMessagePatch {
    struct Insertion {
        let index: Int
        let message: MessageParameter.Message
    }

    var insertions: [Insertion] = []
    var metadata: [String: Any] = [:]
}

enum AgentLoopHookAbortReason: Equatable {
    case requiredHookFailed(hookID: String)
}

struct AgentLoopHookFailure: Equatable {
    let hookID: String
    let stage: AgentLoopHookStage
    let message: String
}

enum AgentLoopHookResult: Equatable {
    case `continue`
    case decision(AgentLoopDecision)
    case messagePatch(AgentLoopMessagePatch)
    case toolCallRecord(ToolCall)
    case failureTrigger(FailureTrigger)
    /// Bootstrap 阶段专用：将 `section` 追加到本次 run 的系统提示末尾。
    /// 不插入消息链。
    case systemPromptAppend(String)

    static func == (lhs: AgentLoopHookResult, rhs: AgentLoopHookResult) -> Bool {
        switch (lhs, rhs) {
        case (.continue, .continue):
            return true
        case (.decision(let lhsDecision), .decision(let rhsDecision)):
            return lhsDecision == rhsDecision
        case (.messagePatch(let lhsPatch), .messagePatch(let rhsPatch)):
            return lhsPatch.insertions.count == rhsPatch.insertions.count
                && lhsPatch.metadata.keys.sorted() == rhsPatch.metadata.keys.sorted()
        case (.toolCallRecord(let lhsRecord), .toolCallRecord(let rhsRecord)):
            return lhsRecord.id == rhsRecord.id
        case (.failureTrigger(let lhsTrigger), .failureTrigger(let rhsTrigger)):
            return lhsTrigger == rhsTrigger
        case (.systemPromptAppend(let lhs), .systemPromptAppend(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

struct AgentLoopHookDispatchResult {
    var failures: [AgentLoopHookFailure] = []
    var decisions: [AgentLoopDecision] = []
    var abortReason: AgentLoopHookAbortReason?
    var messagePatch: AgentLoopMessagePatch?
    var toolCallRecord: ToolCall?
    var failureTrigger: FailureTrigger?
    /// 由 `.systemPromptAppend` hook result 聚合的系统提示附加文本。
    /// 多个 hook 返回 systemPromptAppend 时，内容按 hook order 拼接（\n\n 分隔）。
    var systemAppend: String?
}

struct AgentLoopHookContext {
    let runID: String
    let sessionID: String
    let workflowID: String?
    let executionContext: ToolContext
    let modelId: String
    let roundIndex: Int
    let phase: String

    var messagesSnapshot: [MessageParameter.Message] = []
    var pendingToolName: String?
    var stopReason: String?
    var failureTrigger: FailureTrigger?
    var accumulatedText: String = ""
    var currentRoundText: String = ""
    var currentRoundThinking: String = ""
    var toolInput: MessageResponse.Content.Input = [:]
    var toolResultText: String = ""
    var metadata: [String: Any] = [:]
    var streamProjectionTarget: AgentLoopStreamProjectionTarget = .none
    var toolCallRecord: ToolCall?
    var remoteDeliveryHandle: (any RemoteTurnDeliveryHandle)?
}

protocol AgentLoopHook {
    var id: String { get }
    var order: Int { get }
    var kind: AgentLoopHookKind { get }
    var isRequired: Bool { get }

    func supports(_ stage: AgentLoopHookStage) -> Bool
    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult
}