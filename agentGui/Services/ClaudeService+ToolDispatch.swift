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
        sessionId: String
    ) async -> String {
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            return await executeTextEditorTool(input: input)
        case "bash":
            let wd = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
            let session = getBashSession(for: sessionId, workingDirectory: wd)
            return await executeBashTool(input: input, session: session, workingDirectory: wd)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return "Error: missing 'name' parameter"
            }
            if let content = skillService?.readSkillContent(name: skillName) {
                return content
            }
            return "Error: skill '\(skillName)' not found"
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
        message: Message,
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
        default:
            kind = .other
            title = toolName
        }

        let record = ToolCall(toolCallId: toolUseId, kind: kind, message: message, agentRound: agentRound)
        record.title = title
        record.filePath = path
        record.diffContent = diffContent
        record.startTime = Date()
        return record
    }
}
