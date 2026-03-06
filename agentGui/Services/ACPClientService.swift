//
//  ClaudeService.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Claude Service

/// Claude API 服务，使用 SwiftAnthropic 与 Claude 交互
@Observable
@MainActor
final class ClaudeService {

    // MARK: - Observable State

    var isStreaming: Bool = false
    var lastError: String?

    // MARK: - Internal Storage

    var service: (any AnthropicService)?

    /// 每个 Session 对应一个持久化 bash session（key = sessionId）
    var bashSessions: [String: BashSession] = [:]

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
}
