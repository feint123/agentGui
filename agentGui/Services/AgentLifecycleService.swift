//
//  AgentLifecycleService.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation
import SwiftData
import Observation

/// Agent 生命周期管理服务
/// 负责管理 Agent 的连接、断开、状态追踪等完整生命周期
@Observable
@MainActor
final class AgentLifecycleService: Sendable {

    // MARK: - Properties

    private let acpClientService: ACPClientService
    private let agentRepository: AgentRepositoryProtocol
    private var currentAgentId: UUID?

    /// 当前连接状态
    private(set) var connectionState: AgentConnectionState = .disconnected

    /// 当前连接的 Agent 信息
    private(set) var currentAgent: AgentConfiguration?

    /// 连接错误信息（如果有）
    private(set) var connectionError: String?

    // MARK: - Initialization

    init(
        acpClientService: ACPClientService,
        agentRepository: AgentRepositoryProtocol
    ) {
        self.acpClientService = acpClientService
        self.agentRepository = agentRepository
    }

    // MARK: - Connection Management

    /// 连接 Agent
    func connect(agent: AgentConfiguration) async throws {
        guard connectionState == .disconnected else {
            throw AgentClientError.connectionFailed(underlying: NSError(
                domain: "agentGui",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "已有活跃连接，请先断开"]
            ))
        }

        connectionState = .connecting
        connectionError = nil
        currentAgent = agent

        do {
            try await acpClientService.connect(agent: agent)

            // 获取 Agent 信息
            if let agentInfo = await acpClientService.getAgentInfo() {
                connectionState = .connected(agentInfo: agentInfo)
            } else {
                connectionState = .connected(agentInfo: AgentInfo(
                    name: agent.name,
                    version: "未知"
                ))
            }

            currentAgentId = agent.id

            // 更新最后使用时间
            try? await agentRepository.updateLastUsed(id: agent.id)

        } catch {
            connectionError = error.localizedDescription
            connectionState = .error(error.localizedDescription)
            currentAgent = nil
            throw error
        }
    }

    /// 断开连接
    func disconnect() async {
        await acpClientService.disconnect()

        connectionState = .disconnected
        connectionError = nil
        currentAgent = nil
        currentAgentId = nil
    }

    /// 重新连接
    func reconnect() async throws {
        guard let agent = currentAgent else {
            throw AgentClientError.connectionFailed(underlying: NSError(
                domain: "agentGui",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "没有可重连的 Agent"]
            ))
        }

        try await connect(agent: agent)
    }

    // MARK: - State Queries

    /// 是否已连接
    var isConnected: Bool {
        connectionState.isConnected
    }

    /// 是否正在连接
    var isConnecting: Bool {
        connectionState == .connecting
    }

    /// 获取当前 Agent 信息
    func getCurrentAgent() -> AgentConfiguration? {
        currentAgent
    }

    /// 获取活跃会话列表
    func getActiveSessions() -> [String] {
        Task {
            await acpClientService.getActiveSessions()
        }
        return []
    }

    // MARK: - Auto Connect

    /// 尝试自动连接默认 Agent
    func autoConnect() async throws {
        guard let defaultAgent = try? await agentRepository.fetchDefault() else {
            return // 没有配置默认 Agent，静默返回
        }

        guard defaultAgent.autoConnect else {
            return // Agent 未启用自动连接
        }

        try await connect(agent: defaultAgent)
    }

    // MARK: - Connection State Sync

    /// 从 ACPClientService 同步连接状态
    func syncConnectionState() async {
        let acpState = await acpClientService.getConnectionState()

        switch acpState {
        case .disconnected:
            connectionState = .disconnected
        case .connecting:
            connectionState = .connecting
        case .connected(let agentInfo):
            connectionState = .connected(agentInfo: agentInfo)
        case .error(let message):
            connectionState = .error(message)
            connectionError = message
        }
    }
}
