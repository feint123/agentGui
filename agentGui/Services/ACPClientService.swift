//
//  ClaudeService.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Ask User Question Request

/// 代表一道要提问给用户的题目中的一个选项
struct AskUserQuestionOption: Decodable {
    let label: String
    let description: String
}

/// 代表一道要提问给用户的题目
struct AskUserQuestion: Decodable {
    let question: String
    let header: String
    let options: [AskUserQuestionOption]
    let multiSelect: Bool
}

/// 挂起状态：当 Claude 调用 ask_user_question 时创建，用于暂停 agentic loop 直到用户回答
final class AskUserQuestionRequest: Identifiable {
    let id = UUID()
    let questions: [AskUserQuestion]
    private let continuation: CheckedContinuation<String, Never>
    private var resolved = false

    init(questions: [AskUserQuestion], continuation: CheckedContinuation<String, Never>) {
        self.questions = questions
        self.continuation = continuation
    }

    /// 由 UI 调用：传入每道题的已选 label 列表，恢复 agentic loop
    func submit(selections: [[String]]) {
        guard !resolved else { return }
        resolved = true
        let answers = zip(questions, selections).map { question, selected in
            [
                "question": question.question,
                "header": question.header,
                "selected": selected
            ] as [String: Any]
        }
        let payload: [String: Any] = ["answers": answers]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let result = String(data: data, encoding: .utf8) ?? "{\"answers\":[]}"
        continuation.resume(returning: result)
    }

    /// 用户取消（关闭 sheet），返回空答案以避免 agentic loop 永久挂起
    func cancel() {
        guard !resolved else { return }
        resolved = true
        continuation.resume(returning: "{\"answers\":[]}")
    }
}

// MARK: - Claude Service

/// Claude API 服务，使用 SwiftAnthropic 与 Claude 交互
@Observable
@MainActor
final class ClaudeService {

    // MARK: - Observable State

    var isStreaming: Bool = false
    var lastError: String?

    /// 当 Claude 调用 ask_user_question 时设置，触发 ChatView 弹出问题 sheet
    var pendingUserQuestion: AskUserQuestionRequest?

    /// 当前请求的输入 token 数（来自 message_start 事件）
    var currentInputTokens: Int = 0

    /// 当前正在使用的模型 ID（用于计算上下文窗口大小）
    var currentModelId: String = ""

    // MARK: - Context Window Helpers

    /// 根据模型 ID 返回上下文窗口大小（tokens）
    func contextWindowSize(for modelId: String) -> Int {
        // Claude 3.5 Haiku / all Claude 4 series: 200k
        return 200_000
    }

    /// 当前上下文使用率（0.0 ~ 1.0）
    var contextUsageRatio: Double {
        let windowSize = contextWindowSize(for: currentModelId)
        guard windowSize > 0, currentInputTokens > 0 else { return 0 }
        return Double(currentInputTokens) / Double(windowSize)
    }

    // MARK: - Internal Storage

    var service: (any AnthropicService)?

    /// 每个 Session 对应一个持久化 bash session（key = sessionId）
    var bashSessions: [String: BashSession] = [:]

    /// 每个 Session 的 TodoList（key = sessionId）
    var sessionTodoLists: [String: [TodoItem]] = [:]

    /// Skill service reference for tool dispatch and system prompt
    var skillService: SkillService?

    // MARK: - Configuration

    var isConfigured: Bool { service != nil }

    func configure(apiKey: String, baseURL: String = "") {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { service = nil; return }
        let basePath = baseURL.trimmingCharacters(in: .whitespaces)
        if basePath.isEmpty {
            service = AnthropicServiceFactory.service(apiKey: trimmed, betaHeaders: nil)
        } else {
            service = AnthropicServiceFactory.service(apiKey: trimmed, basePath: basePath, betaHeaders: nil, debugEnabled: false)
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

        // 构建消息历史（仅文本内容）+ 新用户消息
        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        var apiMessages: [MessageParameter.Message] = []
        for msg in sortedMessages {
            guard let content = msg.textContent, !content.isEmpty else { continue }
            let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
            apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
        }
        apiMessages.append(MessageParameter.Message(role: .user, content: .text(text)))

        try await resumeSend(
            apiMessages: apiMessages,
            service: service,
            session: session,
            modelId: modelId,
            modelContext: modelContext
        )

        if session.title == "新对话" || session.title.isEmpty {
            session.title = String(text.prefix(40))
        }
    }

    /// 删除最后一条 agent 消息并重新发送
    func regenerate(
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws {
        guard let service else { throw ClaudeError.notConfigured }

        isStreaming = true
        lastError = nil
        defer { isStreaming = false }

        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        let lastUserSeq = sortedMessages.last(where: { $0.direction == .user })?.sequence ?? -1

        // 先构建 API 消息历史（仅保留 user 及之前）
        var apiMessages: [MessageParameter.Message] = []
        for msg in sortedMessages where msg.sequence <= lastUserSeq {
            guard let content = msg.textContent, !content.isEmpty else { continue }
            let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
            apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
        }
        guard !apiMessages.isEmpty else { return }

        // 删除最后的 agent 消息
        for msg in sortedMessages where msg.sequence > lastUserSeq {
            modelContext.delete(msg)
        }
        try? modelContext.save()

        try await resumeSend(
            apiMessages: apiMessages,
            service: service,
            session: session,
            modelId: modelId,
            modelContext: modelContext
        )
    }

    /// 编辑用户消息文本并重新发送（删除该消息之后的所有消息）
    func editAndResend(
        message: Message,
        newText: String,
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws {
        guard let service else { throw ClaudeError.notConfigured }

        isStreaming = true
        lastError = nil
        defer { isStreaming = false }

        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        message.textContent = newText

        // 先构建 API 消息历史（含被编辑的消息）
        var apiMessages: [MessageParameter.Message] = []
        for msg in sortedMessages where msg.sequence <= message.sequence {
            guard let content = msg.textContent, !content.isEmpty else { continue }
            let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
            apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
        }
        guard !apiMessages.isEmpty else { return }

        // 删除被编辑消息之后的所有消息
        for msg in sortedMessages where msg.sequence > message.sequence {
            modelContext.delete(msg)
        }
        try? modelContext.save()

        try await resumeSend(
            apiMessages: apiMessages,
            service: service,
            session: session,
            modelId: modelId,
            modelContext: modelContext
        )
    }

    // MARK: - Private Resume Helper

    private func resumeSend(
        apiMessages: [MessageParameter.Message],
        service: any AnthropicService,
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let enabledSkills = skillService?.enabledSkills(enabledNames: settings.enabledSkillNames) ?? []
        let systemPrompt = buildSystemPrompt(skills: enabledSkills, workingDirectory: settings.workingDirectory)
        let tools = buildTools(modelId: modelId, settings: settings, enabledSkills: enabledSkills)

        // 创建 assistant 消息占位符
        let assistantMessage = Message.agentMessage(text: "", session: session)
        assistantMessage.status = .pending
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        do {
            try await runAgenticLoop(
                apiMessages: apiMessages,
                assistantMessage: assistantMessage,
                service: service,
                modelId: modelId,
                tools: tools,
                systemPrompt: systemPrompt,
                session: session,
                settings: settings,
                modelContext: modelContext
            )
            assistantMessage.status = .completed
            if assistantMessage.textContent?.isEmpty ?? true {
                assistantMessage.textContent = "(无响应)"
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

    // MARK: - System Prompt Builder

    private func buildSystemPrompt(skills: [Skill], workingDirectory: String) -> String {
        var parts: [String] = []

        // Long-term memory — read from ~/.agentgui/memory.md on every call so it's always fresh
        let memory = ConfigDirectoryManager.shared.readMemory()
        if !memory.isEmpty {
            parts.append("## Long-term Memory\n\(memory)")
        }

        if !workingDirectory.isEmpty {
            parts.append("## Working Directory\nThe current working directory for all file and bash tool operations is: \(workingDirectory)")
        }

        if !skills.isEmpty {
            var lines = [
                "## Available Skills",
                "Use the 'read_skill' tool to load a skill's full instructions when the user's request matches its purpose.",
                ""
            ]
            for skill in skills {
                let desc = skill.description.isEmpty ? "(no description)" : skill.description
                lines.append("- **\(skill.name)**: \(desc)")
            }
            parts.append(lines.joined(separator: "\n"))
        }

        parts.append("""
        ## Subagent Orchestration

        You have access to specialized subagents via the `run_subagent` tool. Follow these rules strictly:

        **Use `explorer` FIRST whenever the task involves:**
        - Researching a topic, technology, product, or capability ("explore X", "research Y", "what can Z do", "Z 的能力")
        - Writing a report, analysis, comparison, or summary that requires gathering information
        - Finding documentation, APIs, changelogs, news, or any external reference
        - Answering factual questions about things that may have changed since your training cutoff

        **Workflow for research/report tasks (MANDATORY):**
        1. Call `run_subagent` with `agent_name: "explorer"` to gather all needed information.
        2. Wait for the explorer's result.
        3. Synthesize the findings into the final response for the user.
        Do NOT attempt to answer research questions from memory alone when `explorer` can gather live, accurate data.

        **Other delegation rules:**
        - Use `coder` for implementing or modifying code files.
        - Use `reviewer` for code quality/security audits.
        - Use `executor` for running shell commands, builds, or tests.
        - Use `summarizer` for distilling long documents into concise summaries.
        """)

        return parts.joined(separator: "\n\n")
    }
}
