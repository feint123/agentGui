import Foundation
import SwiftAnthropic

struct AgentLoopPendingTool: Equatable {
    let id: String
    let name: String
    var partialJson: String = ""

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