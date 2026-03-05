//
//  ClaudeService.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

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

    // MARK: - Configuration

    /// 服务是否已配置 API Key
    var isConfigured: Bool { service != nil }

    /// 使用 API Key 和可选的 Base URL 初始化服务
    func configure(apiKey: String, baseURL: String = "") {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            service = nil
            return
        }
        let basePath = baseURL.trimmingCharacters(in: .whitespaces)
        if basePath.isEmpty {
            service = AnthropicServiceFactory.service(apiKey: trimmed, betaHeaders: nil)
        } else {
            service = AnthropicServiceFactory.service(apiKey: trimmed, basePath: basePath, betaHeaders: nil)
        }
    }

    // MARK: - Messaging

    /// 发送消息并流式接收 Claude 响应
    /// - Parameters:
    ///   - text: 用户输入的文本
    ///   - session: 当前对话会话
    ///   - modelId: 使用的模型 ID
    ///   - modelContext: SwiftData 上下文
    func sendMessage(
        text: String,
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws {
        guard let service else {
            throw ClaudeError.notConfigured
        }

        isStreaming = true
        lastError = nil
        defer { isStreaming = false }

        // 构建消息历史
        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        var apiMessages: [MessageParameter.Message] = []

        for msg in sortedMessages {
            guard let content = msg.textContent, !content.isEmpty else { continue }
            let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
            apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
        }

        // 添加当前用户消息
        apiMessages.append(MessageParameter.Message(role: .user, content: .text(text)))

        let parameters = MessageParameter(
            model: .other(modelId),
            messages: apiMessages,
            maxTokens: 8192
        )

        // 创建助手消息占位符（流式更新时实时修改）
        let assistantMessage = Message.agentMessage(text: "", session: session)
        assistantMessage.status = .pending
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        do {
            let stream = try await service.streamMessage(parameters)
            var fullText = ""

            for try await event in stream {
                if let deltaText = event.delta?.text {
                    fullText += deltaText
                    assistantMessage.textContent = fullText
                }
            }

            assistantMessage.status = .completed
            if assistantMessage.textContent?.isEmpty ?? true {
                assistantMessage.textContent = "(无响应)"
            }

            // 根据第一条用户消息自动设置会话标题
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
