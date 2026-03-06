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

    // MARK: - Internal Storage

    var service: (any AnthropicService)?

    /// 每个 Session 对应一个持久化 bash session（key = sessionId）
    var bashSessions: [String: BashSession] = [:]

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

        let enabledSkills = skillService?.enabledSkills(enabledNames: settings.enabledSkillNames) ?? []
        let systemPrompt = buildSkillSystemPrompt(enabledSkills)
        let tools = buildTools(modelId: modelId, settings: settings, enabledSkills: enabledSkills)

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

    // MARK: - Skill System Prompt

    private func buildSkillSystemPrompt(_ skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "" }
        var lines = [
            "## Available Skills",
            "Use the 'read_skill' tool to load a skill's full instructions when the user's request matches its purpose.",
            ""
        ]
        for skill in skills {
            let desc = skill.description.isEmpty ? "(no description)" : skill.description
            lines.append("- **\(skill.name)**: \(desc)")
        }
        return lines.joined(separator: "\n")
    }
}
