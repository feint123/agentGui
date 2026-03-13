//
//  ClaudeService+ToolCallRecord.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

extension ClaudeService {

    // MARK: - ToolCall Record Factory

    func makeToolCallRecord(
        toolUseId: String,
        toolName: String,
        input: MessageResponse.Content.Input,
        message: Message?,
        agentRound: AgentRound? = nil,
        executionContext: ToolContext = .mainAgent
    ) -> ToolCall {
        let path = input["path"]?.stringValue
        let fileName = path.map { ($0 as NSString).lastPathComponent } ?? ""

        let kind: ToolKind
        let title: String
        var diffContent: String? = nil

        switch toolName {
        case "str_replace_based_edit_tool", "str_replace_editor":
            let cmd = input["command"]?.stringValue ?? "?"
            switch cmd {
            case "view", "read", "open":
                kind = .read
                title = "查看 \(fileName)"
            case "str_replace":
                kind = .edit
                title = "编辑 \(fileName)"
                let old = input["old_str"]?.stringValue ?? ""
                let new = input["new_str"]?.stringValue ?? ""
                diffContent = "--- 原文\n\(old)\n+++ 新文\n\(new)"
            case "create":
                kind = .edit
                title = "创建 \(fileName)"
            case "write":
                kind = .edit
                title = "写入 \(fileName)"
            case "insert":
                kind = .edit
                title = "插入 \(fileName)"
            default:
                kind = .other
                title = cmd
            }
        case "bash":
            kind = .execute
            if input["restart"]?.boolValue == true {
                title = "重启 bash session"
            } else {
                title = String((input["command"]?.stringValue ?? "").prefix(80))
            }
        case "code_execution":
            kind = .execute
            let code = input["code"]?.stringValue ?? ""
            title = "执行代码: \(String(code.prefix(60)))"
        case "read_skill":
            kind = .other
            let skillName = input["name"]?.stringValue ?? ""
            title = "加载技能: \(skillName)"
        case "read_tool_payload":
            kind = .read
            let payloadRef = input["payload_ref"]?.stringValue ?? ""
            title = "读取载荷: \(String(payloadRef.prefix(24)))"
        case "ask_user_question":
            kind = .askUser
            title = "提问用户"
        case "run_subagent":
            kind = .subagent
            let agentName = input["agent_name"]?.stringValue ?? ""
            let definition = AgentCatalog.shared.find(named: agentName)
            title = "子代理: \(definition?.displayName ?? agentName)"
        case "update_todo_list":
            kind = .todo
            let itemCount = input["items"]?.arrayValue?.count ?? 0
            title = "更新任务列表 (\(itemCount)项)"
        case "web_search":
            kind = .search
            let query = input["query"]?.stringValue ?? ""
            title = "搜索: \(String(query.prefix(60)))"
        case "web_fetch":
            kind = .fetch
            let fetchUrl = input["url"]?.stringValue ?? ""
            title = "获取: \(String(fetchUrl.prefix(60)))"
        default:
            kind = .other
            title = toolName
        }

        let record = ToolCall(toolCallId: toolUseId, kind: kind, message: message, agentRound: agentRound)
        record.title = title
        record.filePath = path
        record.diffContent = diffContent
        record.startTime = Date()
        if let definition = DefaultToolRegistry().definition(for: toolName) {
            record.toolDefinitionID = definition.id
            record.toolSchemaVersion = definition.schemaVersion
        }
        record.toolExposureSource = "context:\(executionContext.rawValue)"
        record.toolExecutionContext = executionContext.rawValue

        if toolName == "bash", let metadata = bashTaskRecordMetadata(from: input, defaultTaskId: toolUseId) {
            record.terminalTaskId = metadata.taskId
            record.terminalTaskStatus = metadata.initialStatus.rawValue
            record.terminalExecutionMode = metadata.executionMode.rawValue
        }

        if kind == .subagent {
            record.subagentAgentName = input["agent_name"]?.stringValue
            record.subagentTask = input["task"]?.stringValue
        }

        return record
    }

    private func bashTaskRecordMetadata(
        from input: MessageResponse.Content.Input,
        defaultTaskId: String
    ) -> (taskId: String, executionMode: TerminalExecutionMode, initialStatus: TerminalTaskStatus)? {
        guard let request = try? normalizeBashToolRequest(input: input), !request.restart else {
            return nil
        }

        let taskId = request.taskId ?? defaultTaskId
        let status: TerminalTaskStatus
        if request.signal != nil {
            status = .runningForeground
        } else {
            switch request.executionMode {
            case .background:
                status = .launching
            case .interactive, .foreground, .auto:
                status = .launching
            }
        }

        return (taskId: taskId, executionMode: request.executionMode, initialStatus: status)
    }
}
