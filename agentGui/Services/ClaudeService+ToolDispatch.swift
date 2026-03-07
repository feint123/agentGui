//
//  ClaudeService+ToolDispatch.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - Tool Dispatch & Bash Session Management

extension ClaudeService {

    // MARK: Dispatch

    func executeTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings,
        session: Session
    ) async -> String {
        let sessionId = session.sessionId
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            return await executeTextEditorTool(input: input)
        case "bash":
            let wd = effectiveWorkingDirectory(session: session, settings: settings)
            let bashSess = getBashSession(for: sessionId, workingDirectory: wd)
            return await executeBashTool(input: input, session: bashSess, workingDirectory: wd)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return "Error: missing 'name' parameter"
            }
            if let content = skillService?.readSkillContent(name: skillName) {
                return content
            }
            return "Error: skill '\(skillName)' not found"
        case "update_todo_list":
            return executeUpdateTodoList(input: input, sessionId: sessionId)
        case "web_search":
            return await executeWebSearchTool(input: input)
        case "web_fetch":
            return await executeWebFetchTool(input: input)
        case "ask_user_question":
            return await executeAskUserQuestion(input: input)
        default:
            return "Error: unknown tool '\(name)'"
        }
    }

    // MARK: Update Todo List

    @discardableResult
    func executeUpdateTodoList(input: MessageResponse.Content.Input, sessionId: String) -> String {
        guard let itemsValue = input["items"] else {
            return "Error: missing 'items' parameter"
        }
        let anyValue = dynamicContentToAny(itemsValue)
        guard
            let arrayValue = anyValue as? [[String: Any]],
            let data = try? JSONSerialization.data(withJSONObject: arrayValue),
            let items = try? JSONDecoder().decode([TodoItem].self, from: data)
        else {
            return "Error: failed to parse 'items' array"
        }
        sessionTodoLists[sessionId] = items
        return "Todo list updated with \(items.count) items."
    }

    // MARK: Ask User Question

    func executeAskUserQuestion(input: MessageResponse.Content.Input) async -> String {
        // Parse the questions array from the DynamicContent input
        guard let questionsValue = input["questions"] else {
            return "{\"error\": \"missing 'questions' parameter\"}"
        }

        // DynamicContent is Decodable-only, so convert to Any via JSONSerialization
        let anyValue = dynamicContentToAny(questionsValue)
        guard
            let arrayValue = anyValue as? [[String: Any]],
            let data = try? JSONSerialization.data(withJSONObject: arrayValue),
            let questions = try? JSONDecoder().decode([AskUserQuestion].self, from: data)
        else {
            return "{\"error\": \"failed to parse questions\"}"
        }

        // Suspend the agentic loop. ClaudeService is @MainActor so self.pendingUserQuestion
        // can be set directly without a Task wrapper.
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            self.pendingUserQuestion = AskUserQuestionRequest(
                questions: questions,
                continuation: continuation
            )
        }
        // Clear pending state now that the user has responded
        self.pendingUserQuestion = nil
        return result
    }

    /// Recursively convert DynamicContent (Decodable-only) to a JSONSerialization-compatible Any.
    private func dynamicContentToAny(_ content: MessageResponse.Content.DynamicContent) -> Any {
        switch content {
        case .string(let s):  return s
        case .integer(let i): return i
        case .double(let d):  return d
        case .bool(let b):    return b
        case .null:           return NSNull()
        case .array(let arr): return arr.map { dynamicContentToAny($0) }
        case .dictionary(let dict):
            return dict.mapValues { dynamicContentToAny($0) }
        }
    }

    // MARK: Bash Session Management

    // MARK: - Effective Working Directory

    func effectiveWorkingDirectory(session: Session, settings: AppSettings) -> String? {
        if !settings.workingDirectory.isEmpty { return settings.workingDirectory }
        return nil
    }

    /// Convenience overload used by subagent loops that only have a sessionId string.
    /// Falls back to global settings working directory.
    func executeTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings,
        sessionId: String
    ) async -> String {
        let wd = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            return await executeTextEditorTool(input: input)
        case "bash":
            let bashSess = getBashSession(for: sessionId, workingDirectory: wd)
            return await executeBashTool(input: input, session: bashSess, workingDirectory: wd)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return "Error: missing 'name' parameter"
            }
            if let content = skillService?.readSkillContent(name: skillName) {
                return content
            }
            return "Error: skill '\(skillName)' not found"
        case "update_todo_list":
            return executeUpdateTodoList(input: input, sessionId: sessionId)
        case "web_search":
            return await executeWebSearchTool(input: input)
        case "web_fetch":
            return await executeWebFetchTool(input: input)
        case "ask_user_question":
            return await executeAskUserQuestion(input: input)
        default:
            return "Error: unknown tool '\(name)'"
        }
    }

    // MARK: Bash Session Management

    func getBashSession(for sessionId: String, workingDirectory: String?) -> BashSession {
        if let existing = bashSessions[sessionId] { return existing }
        let newSession = BashSession()
        Task { await newSession.start(workingDirectory: workingDirectory) }
        bashSessions[sessionId] = newSession
        return newSession
    }

    // MARK: Bash Tool

    func executeBashTool(
        input: MessageResponse.Content.Input,
        session: BashSession,
        workingDirectory: String?
    ) async -> String {
        if input["restart"]?.boolValue == true {
            await session.restart(workingDirectory: workingDirectory)
            return "Bash session restarted."
        }
        guard let command = input["command"]?.stringValue else {
            return "Error: missing 'command' parameter"
        }
        return await session.execute(command)
    }

    // MARK: ToolCall Record Factory

    func makeToolCallRecord(
        toolUseId: String,
        toolName: String,
        input: MessageResponse.Content.Input,
        message: Message?,
        agentRound: AgentRound? = nil
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
        case "ask_user_question":
            kind = .askUser
            title = "提问用户"
        case "run_subagent":
            kind = .subagent
            let agentName = input["agent_name"]?.stringValue ?? ""
            let definition = SubagentDefinition.find(named: agentName)
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

        if kind == .subagent {
            record.subagentAgentName = input["agent_name"]?.stringValue
            record.subagentTask = input["task"]?.stringValue
        }

        return record
    }
}
