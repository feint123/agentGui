import Foundation
import SwiftAnthropic

// MARK: - S-F3 Fork Context

/// S-F3: fork 子代理执行所需的父代理上下文，在 AgentLoopRoundExecutor.handleToolUseOutcome
/// 中注入（batch planning 前）。
///
/// 使用独立类型而非直接扩展 AgentLoopPendingTool，避免将大型 MessageParameter.Message
/// 数组带入 Equatable 语义，同时使 context 的生命周期与 pending tool 解耦。
struct AgentLoopForkContext {
    /// 当前 assistant 轮次开始前的完整对话历史（父代理视角）。
    /// 用于构建 fork 子代理的初始消息前缀（拼在 buildForkedMessages 之前）。
    let parentMessages: [MessageParameter.Message]
    /// 当前 assistant 轮次的所有 content object（text + thinking + 所有 toolUse）。
    /// 传给 ForkMessageBuilder.buildForkedMessages(directive:assistantObjects:)。
    let assistantObjects: [MessageParameter.Message.Content.ContentObject]
    /// 父代理当前使用的系统提示文本（已渲染字符串）。
    /// fork 子代理使用此系统提示替代 WorkflowRoleDefinition.systemPrompt，
    /// 确保与父代理 byte-identical 的 system prompt（最大化 prompt cache 命中）。
    let parentSystemPromptText: String?
}

struct AgentLoopPendingTool: Equatable {
    let id: String
    let name: String
    var partialJson: String = ""

    /// S-F1: Set to `true` when this pending tool represents a fork-mode subagent call.
    /// Used by ToolConcurrencyBatchPlanner (S-F3) to mark fork subagents as concurrency-safe,
    /// enabling parallel execution of multiple fork children in the same batch.
    var isForkSubagent: Bool = false

    /// S-F3: Fork 执行上下文（仅 isForkSubagent == true 时非 nil）。
    /// 由 AgentLoopRoundExecutor.handleToolUseOutcome 在 batch planning 之前注入。
    /// 不参与 Equatable 比较（不影响测试 snapshot 比较语义）。
    var forkContext: AgentLoopForkContext? = nil

    var parsedInput: MessageResponse.Content.Input {
        guard let data = partialJson.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let dictionary = jsonObject as? [String: Any] else {
            return [:]
        }

        return dictionary.mapValues(Self.dynamicContent(from:))
    }

    private static func dynamicContent(from value: Any) -> MessageResponse.Content.DynamicContent {
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .integer(int)
        case let double as Double:
            return .double(double)
        case let array as [Any]:
            return .array(array.map(dynamicContent(from:)))
        case let dictionary as [String: Any]:
            return .dictionary(dictionary.mapValues(dynamicContent(from:)))
        default:
            return .string(String(describing: value))
        }
    }

    // S-F3: forkContext 含 MessageParameter.Message（非 Equatable），手动实现 ==
    static func == (lhs: AgentLoopPendingTool, rhs: AgentLoopPendingTool) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.partialJson == rhs.partialJson &&
        lhs.isForkSubagent == rhs.isForkSubagent
        // forkContext intentionally excluded — context is implementation detail, not stream state
    }
}

struct AgentLoopRoundStreamSnapshot: Equatable {
    var text: String = ""
    var thinkingContent: String = ""
    var thinkingSignature: String?
    var pendingTools: [AgentLoopPendingTool] = []
    var stopReason: String?
    var usage: MessageResponse.Usage?

    static func == (lhs: AgentLoopRoundStreamSnapshot, rhs: AgentLoopRoundStreamSnapshot) -> Bool {
        lhs.text == rhs.text &&
        lhs.thinkingContent == rhs.thinkingContent &&
        lhs.thinkingSignature == rhs.thinkingSignature &&
        lhs.pendingTools == rhs.pendingTools &&
        lhs.stopReason == rhs.stopReason &&
        lhs.usage?.inputTokens == rhs.usage?.inputTokens &&
        lhs.usage?.outputTokens == rhs.usage?.outputTokens
    }
}

enum AgentLoopRoundStreamSnapshotDelta: Equatable {
    case none
    case text(String)
    case thinking(String)
    case signature(String)
    case stopReason(String)
}

struct AgentLoopRoundStreamAssembler {
    private var text: String = ""
    private var thinkingContent: String = ""
    private var thinkingSignature: String?
    private var pendingTools: [Int: AgentLoopPendingTool] = [:]
    private var currentBlockIndex: Int?
    private var stopReason: String?
    private var usage: MessageResponse.Usage?

    var snapshot: AgentLoopRoundStreamSnapshot {
        AgentLoopRoundStreamSnapshot(
            text: text,
            thinkingContent: thinkingContent,
            thinkingSignature: thinkingSignature,
            pendingTools: pendingTools.sorted(by: { $0.key < $1.key }).map(\.value),
            stopReason: stopReason,
            usage: usage
        )
    }

    @discardableResult
    mutating func consume(_ event: MessageStreamResponse) -> AgentLoopRoundStreamSnapshotDelta {
        if event.type == "message_start", let usageFromEvent = event.message?.usage {
            usage = usageFromEvent
        }

        if let block = event.contentBlock {
            if block.type == "tool_use", let id = block.id, let name = block.name {
                let index = event.index ?? pendingTools.count
                pendingTools[index] = AgentLoopPendingTool(id: id, name: name)
                currentBlockIndex = index
            } else {
                currentBlockIndex = nil
            }
        }

        if let delta = event.delta {
            switch delta.type {
            case "text_delta":
                if let deltaText = delta.text {
                    text += deltaText
                    return .text(deltaText)
                }
            case "thinking_delta":
                if let deltaThinking = delta.thinking {
                    thinkingContent += deltaThinking
                    return .thinking(deltaThinking)
                }
            case "signature_delta":
                if let signature = delta.signature {
                    thinkingSignature = signature
                    return .signature(signature)
                }
            default:
                if let deltaText = delta.text {
                    text += deltaText
                    return .text(deltaText)
                }
            }

            if let json = delta.partialJson, let index = currentBlockIndex {
                pendingTools[index]?.partialJson += json
            }

            if let stopReason = delta.stopReason {
                self.stopReason = stopReason
                return .stopReason(stopReason)
            }
        }

        return .none
    }
}