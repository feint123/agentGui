//
//  SessionService.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation
import SwiftData
import Combine

/// 会话服务
/// 管理与 Agent 的交互会话
@MainActor
final class SessionService: ObservableObject {

    // MARK: - Properties

    private let acpClientService: ACPClientService
    private let sessionRepository: SessionRepositoryProtocol
    private let messageRepository: MessageRepositoryProtocol
    private let modelContext: ModelContext

    /// 当前活跃会话
    @Published private(set) var currentSession: Session?

    /// 流式更新回调
    var onUpdate: ((SessionUpdate) -> Void)?

    // MARK: - Initialization

    init(
        acpClientService: ACPClientService,
        sessionRepository: SessionRepositoryProtocol,
        messageRepository: MessageRepositoryProtocol,
        modelContext: ModelContext
    ) {
        self.acpClientService = acpClientService
        self.sessionRepository = sessionRepository
        self.messageRepository = messageRepository
        self.modelContext = modelContext
    }

    // MARK: - Session Management

    /// 创建新会话
    func createSession(workingDirectory: String) async throws -> Session {
        // 通过 ACP 创建会话
        let acpSession = try await acpClientService.createSession(
            workingDirectory: workingDirectory
        )

        // 保存到数据库
        try await sessionRepository.create(acpSession)

        // 设置为当前会话
        currentSession = acpSession

        // 开始监听更新
        startListening(for: acpSession.sessionId)

        return acpSession
    }

    /// 加载已有会话
    func loadSession(sessionId: String) async throws -> Session {
        guard let session = try await sessionRepository.fetch(byId: sessionId) else {
            throw AgentClientError.sessionCreationFailed
        }

        currentSession = session
        startListening(for: sessionId)

        return session
    }

    /// 关闭会话
    func closeSession() async throws {
        guard let session = currentSession else {
            return
        }

        try await acpClientService.closeSession(sessionId: session.sessionId)

        session.isActive = false
        try await sessionRepository.update(session)

        currentSession = nil
    }

    /// 切换会话
    func switchTo(sessionId: String) async throws {
        // 关闭当前会话
        if currentSession != nil {
            try await closeSession()
        }

        // 加载新会话
        _ = try await loadSession(sessionId: sessionId)
    }

    // MARK: - Messaging

    /// 发送提示
    func sendPrompt(_ text: String, sessionId: String) async throws {
        guard let session = currentSession else {
            throw AgentClientError.sessionCreationFailed
        }

        // 创建用户消息
        let userMessage = Message.userMessage(text: text, session: session)
        try await messageRepository.add(userMessage)

        // 创建占位的助手消息（用于流式更新）
        let assistantMessage = Message.agentMessage(text: "", session: session)
        assistantMessage.status = .pending
        try await messageRepository.add(assistantMessage)

        // 发送到 Agent
        _ = try await acpClientService.sendPrompt(
            text: text,
            sessionId: sessionId
        )

        // 更新助手消息状态
        assistantMessage.status = .completed

        // TODO: 解析响应并更新消息内容
    }

    /// 取消当前操作
    func cancel(sessionId: String) async throws {
        try await acpClientService.cancelSession(sessionId: sessionId)
    }

    // MARK: - Session Mode

    /// 设置会话模式
    func setMode(_ modeId: String, sessionId: String) async throws {
        try await acpClientService.setMode(sessionId: sessionId, modeId: modeId)
    }

    // MARK: - Messages

    /// 获取会话消息
    func getMessages(sessionId: String) async throws -> [Message] {
        try await messageRepository.fetch(bySessionId: sessionId)
    }

    // MARK: - Streaming Updates

    /// 开始监听会话更新
    private func startListening(for sessionId: String) {
        Task {
            for await update in await acpClientService.subscribeToUpdates(sessionId: sessionId) {
                await MainActor.run {
                    onUpdate?(update)
                    handleSessionUpdate(update, sessionId: sessionId)
                }
            }
        }
    }

    /// 处理会话更新
    private func handleSessionUpdate(_ update: SessionUpdate, sessionId: String) {
        switch update {
        case .messageChunk(let chunk):
            handleMessageChunk(chunk, sessionId: sessionId)
        case .toolCall(let event):
            handleToolCall(event, sessionId: sessionId)
        case .modeChanged(let mode):
            handleModeChanged(mode, sessionId: sessionId)
        case .error(let error):
            handleError(error, sessionId: sessionId)
        }
    }

    private func handleMessageChunk(_ chunk: String, sessionId: String) {
        // TODO: 更新最后一条助手消息的内容
    }

    private func handleToolCall(_ event: ToolCallEvent, sessionId: String) {
        // TODO: 创建或更新 ToolCall 记录
    }

    private func handleModeChanged(_ mode: SessionMode, sessionId: String) {
        // TODO: 更新会话模式
    }

    private func handleError(_ error: Error, sessionId: String) {
        // TODO: 处理错误，更新 UI
    }

    // MARK: - Recent Sessions

    /// 获取最近的会话
    func getRecentSessions(limit: Int = 10) async throws -> [Session] {
        try await sessionRepository.fetchRecent(limit: limit)
    }
}
