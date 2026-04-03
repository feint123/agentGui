// agentGui/Services/SubagentGovernance/SubagentLaunchResult.swift
import Foundation

/// S-C2：子代理执行结果的两种路径。
///
/// - `sync`: 同步执行完成，直接返回 `AgentMessage`（现有路径）。
/// - `async`: 后台启动成功，立即返回占位响应（agentID + 描述）。
enum SubagentLaunchResult: Sendable {
    case sync(message: AgentMessage)
    case async(agentID: UUID, description: String)

    /// 转换为工具调用结果文本，直接写入父代理的 tool_result 消息。
    var toolResultText: String {
        switch self {
        case .sync(let message):
            return message.toExecutionResult().text
        case .async(let agentID, let description):
            return """
            {"status":"async_launched","agent_id":"\(agentID.uuidString)",\
            "description":"\(description.jsonEscaped)","poll_after":30}
            """
        }
    }

    /// 是否为后台异步路径。
    var isAsync: Bool {
        if case .async = self { return true }
        return false
    }

    /// 提取同步路径的 AgentMessage（仅用于测试；async 路径返回 nil）。
    var syncMessage: AgentMessage? {
        guard case .sync(let msg) = self else { return nil }
        return msg
    }
}

// MARK: - String JSON Escape Helper

private extension String {
    /// 简单 JSON 字符串转义（双引号、反斜杠、换行均转义）。
    var jsonEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
