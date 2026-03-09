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

    /// 每个 Session 对应一个 bash task registry（key = sessionId）
    var bashTaskRegistries: [String: BashTaskRegistry] = [:]

    /// 每个 Session 的 TodoList（key = sessionId）
    var sessionTodoLists: [String: [TodoItem]] = [:]

    /// 每个 Session 的完成验证记录（key = sessionId）
    var sessionVerifications: [String: CompletionVerification] = [:]

    /// Skill service reference for tool dispatch and system prompt
    var skillService: SkillService?

    /// Workflow runtime — injected from the app root after creation.
    var workflowRuntime: WorkflowRuntime?

    /// Workspace context snapshot captured at the start of each send, used by start_workflow.
    var currentWorkspaceContext: WorkflowWorkspaceContext = .empty

    /// The Session currently being processed, used by start_workflow.
    var currentSession: Session?

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

    func applyConnectionSettings(_ settings: AppSettings) {
        configure(apiKey: settings.apiKey, baseURL: settings.baseURL)
        resetBashSessions()
    }

    func resetBashSessions() {
        let existingSessions = Array(bashSessions.values)
        bashSessions.removeAll()
        bashTaskRegistries.removeAll()
        for session in existingSessions {
            Task {
                await session.terminate()
            }
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

        let isFirstMessage = session.title == "新对话" || session.title.isEmpty

        try await resumeSend(
            apiMessages: apiMessages,
            service: service,
            session: session,
            modelId: modelId,
            modelContext: modelContext
        )

        if isFirstMessage {
            Task { await generateTitle(for: session, firstMessage: text, modelContext: modelContext) }
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
        let systemPrompt = buildSystemPrompt(skills: enabledSkills, workingDirectory: settings.workingDirectory, settings: settings)
        let tools = buildTools(modelId: modelId, settings: settings, enabledSkills: enabledSkills)

        // Capture workspace context snapshot for start_workflow tool
        currentSession = session
        currentWorkspaceContext = WorkflowWorkspaceContext(
            workingDirectory: settings.workingDirectory,
            selectedFilePath: nil,
            selectedText: nil,
            availableSkills: enabledSkills.map { WorkflowSkillInfo(name: $0.name, description: $0.description) }
        )

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

    // MARK: - Title Generation

    func generateTitle(for session: Session, firstMessage: String, modelContext: ModelContext) async {
        guard let service else { return }
        let prompt = "用不超过10个字概括这个对话主题（只输出标题，不加引号）：\(firstMessage)"
        let messages: [MessageParameter.Message] = [
            MessageParameter.Message(role: .user, content: .text(prompt))
        ]
        let parameters = MessageParameter(
            model: .other("claude-haiku-4-5"),
            messages: messages,
            maxTokens: 64
        )
        do {
            let response = try await service.createMessage(parameters)
            if case .text(let title, _) = response.content.first, !title.isEmpty {
                session.title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                try? modelContext.save()
            }
        } catch {
            // Title generation is best-effort; fall back to truncated first message
            session.title = String(firstMessage.prefix(30))
            try? modelContext.save()
        }
    }

    // MARK: - System Prompt Builder

    private func buildSystemPrompt(skills: [Skill], workingDirectory: String, settings: AppSettings) -> String {
        var parts: [String] = []

        // Long-term memory — read from ~/.agentgui/memory.md on every call so it's always fresh
        let memory = ConfigDirectoryManager.shared.readMemory()
        if !memory.isEmpty {
            parts.append("## Long-term Memory\n\(memory)")
        }

        if !workingDirectory.isEmpty {
            parts.append("## Working Directory\nThe current working directory for all file and bash tool operations is: \(workingDirectory)")
        }

        if settings.enableStoryMemory,
           let session = currentSession,
           !session.activeWritingProjectId.isEmpty {
            parts.append("## Story Memory\nProject-scoped story memory is enabled for this session. Keep continuity consistent with active characters, world rules, unresolved foreshadowing, and style directives. Use structured story memory tools when available instead of collapsing these facts into generic notes.")
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
        - Use `planner` for very large or ambiguous tasks where you need a structured plan before starting.
        """)

        parts.append("""
        ## Planning Protocol

        For **complex tasks** — defined as tasks requiring 3+ distinct steps, touching multiple \
        files or systems, or combining research with implementation — follow this workflow:

        ### 1. PLAN
        Call `create_execution_plan` at the very start to produce a structured plan artifact.
        - Break the work into 5–15 concrete, verb-first steps.
        - List key assumptions and success criteria.
        - For very large or ambiguous tasks, delegate planning to `run_subagent` (agent_name: "planner") \
          and use its JSON output as the basis for your `create_execution_plan` call.

        ### 2. EXECUTE
        Work through the plan steps in order.
        - Keep `update_todo_list` in sync: mark steps `in_progress` when started, `done` when complete.
        - If an assumption proves wrong, note it and adapt — do not silently abandon the plan.

        ### 3. VERIFY
        Before giving the final response, call `verify_completion` to explicitly state:
        - What was tested or confirmed (e.g. "build succeeded", "output matched expected value").
        - What was NOT verified and why (e.g. "UI not tested — no test harness available").

        ### 4. SUMMARIZE
        End with a concise summary of what was done, what changed, and any recommended follow-up.

        **Simple tasks** (e.g. single-file edits, direct Q&A, quick lookups) do NOT need a plan. \
        Use your judgment — the goal is clarity and accountability, not ceremony.
        """)

        let workflowCatalog = ClaudeService.availableWorkflows
            .map { "- `\($0.id)`: \($0.description)" }
            .joined(separator: "\n")
        parts.append("""
        ## Workflow Orchestration

        Use `start_workflow` when the task requires a sustained multi-agent pipeline that goes \
        beyond what a single subagent or a few tool calls can achieve.

        **USE `start_workflow` for:**
        - Implementing or refactoring code across multiple files where you need to plan, \
          explore the codebase, write code, review it, and verify the result
        - Large-scale tasks that benefit from the plan → explore → code → review → execute pipeline

        **DO NOT use `start_workflow` for:**
        - Simple Q&A, quick lookups, or single-file edits
        - Tasks you can complete directly with bash/editor/subagent tools in a few calls
        - Anything already handled adequately by `run_subagent`

        When you call `start_workflow`, the workflow runs to completion before you receive the result. \
        Craft the `task` parameter as a complete, self-contained description of the goal, including \
        file paths, constraints, and any relevant context.

        Available workflows:
        \(workflowCatalog)
        """)

        return parts.joined(separator: "\n\n")
    }
}
