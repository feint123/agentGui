//
//  ClaudeService.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - DynamicContent Helpers

extension MessageResponse.Content.DynamicContent {
    var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }
    var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    var arrayValue: [MessageResponse.Content.DynamicContent]? {
        guard case .array(let a) = self else { return nil }
        return a
    }
    var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }
}

// MARK: - Pending Tool Use (agentic loop helper)

private struct PendingToolUse {
    let id: String
    let name: String
    var partialJson: String = ""

    var parsedInput: MessageResponse.Content.Input {
        guard let data = partialJson.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: MessageResponse.Content.DynamicContent].self, from: data)) ?? [:]
    }
}

// MARK: - Claude Service

/// Claude API 服务，使用 SwiftAnthropic 与 Claude 交互
@Observable
@MainActor
final class ClaudeService {

    // MARK: - Observable State

    /// 是否正在流式生成
    var isStreaming: Bool = false

    /// 最近的错误信息
    var lastError: String?

    // MARK: - Private

    private var service: (any AnthropicService)?

    /// 每个 Session 对应一个持久化 bash session（key = sessionId）
    private var bashSessions: [String: BashSession] = [:]

    // MARK: - Configuration

    var isConfigured: Bool { service != nil }

    func configure(apiKey: String, baseURL: String = "") {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { service = nil; return }
        let basePath = baseURL.trimmingCharacters(in: .whitespaces)
        if basePath.isEmpty {
            service = AnthropicServiceFactory.service(apiKey: trimmed, betaHeaders: nil)
        } else {
            service = AnthropicServiceFactory.service(apiKey: trimmed, basePath: basePath, betaHeaders: nil)
        }
    }

    // MARK: - Messaging

    func sendMessage(
        text: String,
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws {
        guard let service else { throw ClaudeError.notConfigured }

        isStreaming = true
        lastError = nil
        defer { isStreaming = false }

        let settings = AppSettings.getOrCreate(in: modelContext)

        // 构建消息历史（仅文本内容）
        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        var apiMessages: [MessageParameter.Message] = []
        for msg in sortedMessages {
            guard let content = msg.textContent, !content.isEmpty else { continue }
            let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
            apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
        }
        apiMessages.append(MessageParameter.Message(role: .user, content: .text(text)))

        // 创建 assistant 消息占位符
        let assistantMessage = Message.agentMessage(text: "", session: session)
        assistantMessage.status = .pending
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        // 构建工具列表
        let tools = buildTools(modelId: modelId, settings: settings)

        do {
            try await runAgenticLoop(
                apiMessages: apiMessages,
                assistantMessage: assistantMessage,
                service: service,
                modelId: modelId,
                tools: tools,
                session: session,
                settings: settings,
                modelContext: modelContext
            )

            assistantMessage.status = .completed
            if assistantMessage.textContent?.isEmpty ?? true {
                assistantMessage.textContent = "(无响应)"
            }

            if session.title == "新对话" || session.title.isEmpty {
                session.title = String(text.prefix(40))
            }
        } catch {
            assistantMessage.status = .failed
            assistantMessage.textContent = "错误: \(error.localizedDescription)"
            lastError = error.localizedDescription
            throw ClaudeError.streamFailed(error)
        }

        session.updatedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Agentic Loop

    private func runAgenticLoop(
        apiMessages: [MessageParameter.Message],
        assistantMessage: Message,
        service: any AnthropicService,
        modelId: String,
        tools: [MessageParameter.Tool],
        session: Session,
        settings: AppSettings,
        modelContext: ModelContext
    ) async throws {
        var loopMessages = apiMessages
        var accumulatedText = ""
        var continueLoop = true

        while continueLoop {
            let params = MessageParameter(
                model: .other(modelId),
                messages: loopMessages,
                maxTokens: 8192,
                tools: tools.isEmpty ? nil : tools
            )
            let stream = try await service.streamMessage(params)

            var currentRoundText = ""
            // index → pending tool use
            var pendingTools: [Int: PendingToolUse] = [:]
            var currentBlockIndex: Int? = nil
            var stopReason: String? = nil

            for try await event in stream {
                // content_block_start
                if let block = event.contentBlock {
                    if block.type == "tool_use", let id = block.id, let name = block.name {
                        let idx = event.index ?? pendingTools.count
                        pendingTools[idx] = PendingToolUse(id: id, name: name)
                        currentBlockIndex = idx
                    } else if block.type == "text" {
                        currentBlockIndex = nil
                    }
                }

                // content_block_delta
                if let delta = event.delta {
                    if let text = delta.text {
                        currentRoundText += text
                        let joined = accumulatedText.isEmpty ? currentRoundText : accumulatedText + "\n\n" + currentRoundText
                        assistantMessage.textContent = joined
                    } else if let json = delta.partialJson, let idx = currentBlockIndex {
                        pendingTools[idx]?.partialJson += json
                    }
                    if let reason = delta.stopReason {
                        stopReason = reason
                    }
                }
            }

            // 累积本轮文本
            if !currentRoundText.isEmpty {
                if !accumulatedText.isEmpty { accumulatedText += "\n\n" }
                accumulatedText += currentRoundText
                assistantMessage.textContent = accumulatedText
            }

            // 处理工具调用
            if stopReason == "tool_use" && !pendingTools.isEmpty {
                let sorted = pendingTools.sorted { $0.key < $1.key }.map { $0.value }

                var assistantObjects: [MessageParameter.Message.Content.ContentObject] = []
                if !currentRoundText.isEmpty {
                    assistantObjects.append(.text(currentRoundText))
                }

                var toolResultObjects: [MessageParameter.Message.Content.ContentObject] = []

                for pending in sorted {
                    let input = pending.parsedInput
                    assistantObjects.append(.toolUse(pending.id, pending.name, input))

                    // 创建 ToolCall 记录
                    let record = makeToolCallRecord(
                        toolUseId: pending.id,
                        toolName: pending.name,
                        input: input,
                        message: assistantMessage
                    )
                    modelContext.insert(record)
                    try? modelContext.save()

                    // 执行工具
                    let result = await executeTool(
                        name: pending.name,
                        input: input,
                        settings: settings,
                        sessionId: session.sessionId
                    )
                    record.terminalOutput = result
                    record.status = .success
                    record.endTime = Date()
                    try? modelContext.save()

                    toolResultObjects.append(.toolResult(pending.id, result))
                }

                loopMessages.append(MessageParameter.Message(role: .assistant, content: .list(assistantObjects)))
                loopMessages.append(MessageParameter.Message(role: .user, content: .list(toolResultObjects)))

            } else {
                continueLoop = false
            }
        }
    }

    // MARK: - Tool List Builder

    private func buildTools(modelId: String, settings: AppSettings) -> [MessageParameter.Tool] {
        var tools: [MessageParameter.Tool] = []

        if settings.enableTextEditorTool {
            let isClaude3 = modelId.contains("3-") || modelId.contains("3.")
            let type = isClaude3 ? "text_editor_20250124" : "text_editor_20250728"
            let name = isClaude3 ? "str_replace_editor" : "str_replace_based_edit_tool"
            tools.append(.hosted(type: type, name: name))
        }

        if settings.enableBashTool {
            tools.append(.hosted(type: "bash_20250124", name: "bash"))
        }

        return tools
    }

    // MARK: - Tool Dispatch

    private func executeTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings,
        sessionId: String
    ) async -> String {
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            return executeTextEditorTool(input: input)
        case "bash":
            let wd = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
            let session = getBashSession(for: sessionId, workingDirectory: wd)
            return await executeBashTool(input: input, session: session, workingDirectory: wd)
        default:
            return "Error: unknown tool '\(name)'"
        }
    }

    // MARK: - Bash Session Management

    private func getBashSession(for sessionId: String, workingDirectory: String?) -> BashSession {
        if let existing = bashSessions[sessionId] { return existing }
        let newSession = BashSession()
        Task { await newSession.start(workingDirectory: workingDirectory) }
        bashSessions[sessionId] = newSession
        return newSession
    }

    // MARK: - Bash Tool

    private func executeBashTool(
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

    // MARK: - Text Editor Tool

    private func executeTextEditorTool(input: MessageResponse.Content.Input) -> String {
        guard let command = input["command"]?.stringValue else {
            return "Error: missing 'command' parameter"
        }
        guard let path = input["path"]?.stringValue else {
            return "Error: missing 'path' parameter"
        }

        switch command {
        case "view":
            let range = input["view_range"]?.arrayValue?.compactMap { $0.intValue }
            return textEditorView(path: path, viewRange: range)
        case "str_replace":
            guard let oldStr = input["old_str"]?.stringValue else { return "Error: missing 'old_str'" }
            let newStr = input["new_str"]?.stringValue ?? ""
            return textEditorStrReplace(path: path, oldStr: oldStr, newStr: newStr)
        case "create":
            guard let fileText = input["file_text"]?.stringValue else { return "Error: missing 'file_text'" }
            return textEditorCreate(path: path, fileText: fileText)
        case "insert":
            guard let line = input["insert_line"]?.intValue,
                  let newStr = input["new_str"]?.stringValue else { return "Error: missing parameters" }
            return textEditorInsert(path: path, insertLine: line, newStr: newStr)
        default:
            return "Error: unknown command '\(command)'"
        }
    }

    private func textEditorView(path: String, viewRange: [Int]?) -> String {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")
            let start: Int
            let end: Int
            if let r = viewRange, r.count >= 2 {
                start = max(1, r[0])
                end = min(lines.count, r[1])
            } else {
                start = 1
                end = lines.count
            }
            return lines[(start - 1)..<end]
                .enumerated()
                .map { "\(start + $0.offset)\t\($0.element)" }
                .joined(separator: "\n")
        } catch {
            return "Error reading '\(path)': \(error.localizedDescription)"
        }
    }

    private func textEditorStrReplace(path: String, oldStr: String, newStr: String) -> String {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let count = content.components(separatedBy: oldStr).count - 1
            if count == 0 { return "Error: old_str not found in '\(path)'" }
            if count > 1 { return "Error: old_str appears \(count) times (ambiguous). Add more context." }
            let updated = content.replacingOccurrences(of: oldStr, with: newStr, options: .literal)
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            return "Replaced text in '\(path)'."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func textEditorCreate(path: String, fileText: String) -> String {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            try fileText.write(toFile: path, atomically: true, encoding: .utf8)
            return "Created '\(path)'."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func textEditorInsert(path: String, insertLine: Int, newStr: String) -> String {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            let idx = max(0, min(insertLine, lines.count))
            lines.insert(contentsOf: newStr.components(separatedBy: "\n"), at: idx)
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return "Inserted text after line \(insertLine) in '\(path)'."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - ToolCall Record Factory

    private func makeToolCallRecord(
        toolUseId: String,
        toolName: String,
        input: MessageResponse.Content.Input,
        message: Message
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
            case "view":
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
        default:
            kind = .other
            title = toolName
        }

        let record = ToolCall(toolCallId: toolUseId, kind: kind, message: message)
        record.title = title
        record.filePath = path
        record.diffContent = diffContent
        record.startTime = Date()
        return record
    }
}

// MARK: - Errors

enum ClaudeError: LocalizedError {
    case notConfigured
    case streamFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先在设置中配置 Anthropic API 密钥"
        case .streamFailed(let error):
            return "请求失败: \(error.localizedDescription)"
        }
    }
}
