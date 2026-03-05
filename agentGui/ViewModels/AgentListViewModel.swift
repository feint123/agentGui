//
//  AgentListViewModel.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation
import SwiftData
import Observation

/// Agent 列表 ViewModel
/// 负责管理 Agent 列表的状态和操作
@Observable
@MainActor
final class AgentListViewModel: Sendable {

    // MARK: - Properties

    private let agentRepository: AgentRepositoryProtocol
    private let lifecycleService: AgentLifecycleService

    /// Agent 列表
    private(set) var agents: [AgentConfiguration] = []

    /// 加载状态
    private(set) var isLoading: Bool = false

    /// 错误信息
    private(set) var errorMessage: String?

    // MARK: - Computed Properties

    /// 是否正在连接
    var isConnecting: Bool {
        lifecycleService.isConnecting
    }

    /// 当前连接的 Agent ID
    var connectedAgentId: UUID? {
        lifecycleService.getCurrentAgent()?.id
    }

    /// 是否有 Agent 配置
    var hasAgents: Bool {
        !agents.isEmpty
    }

    // MARK: - Initialization

    init(
        agentRepository: AgentRepositoryProtocol,
        lifecycleService: AgentLifecycleService
    ) {
        self.agentRepository = agentRepository
        self.lifecycleService = lifecycleService
    }

    // MARK: - Data Loading

    /// 加载 Agent 列表
    func loadAgents() async {
        isLoading = true
        errorMessage = nil

        do {
            agents = try await agentRepository.fetchAll()
        } catch {
            errorMessage = "加载 Agent 列表失败: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// 刷新 Agent 列表
    func refresh() async {
        await loadAgents()
    }

    // MARK: - Agent Operations

    /// 添加新 Agent
    func addAgent(_ agent: AgentConfiguration) async throws {
        try await agentRepository.save(agent)
        await loadAgents()
    }

    /// 更新 Agent
    func updateAgent(_ agent: AgentConfiguration) async throws {
        try await agentRepository.save(agent)
        await loadAgents()
    }

    /// 删除 Agent
    func deleteAgent(_ agent: AgentConfiguration) async throws {
        // 如果是当前连接的 Agent，先断开连接
        if let currentAgent = lifecycleService.getCurrentAgent(),
           currentAgent.id == agent.id {
            await lifecycleService.disconnect()
        }

        try await agentRepository.delete(agent)
        await loadAgents()
    }

    /// 连接 Agent
    func connect(to agent: AgentConfiguration) async throws {
        try await lifecycleService.connect(agent: agent)
    }

    /// 断开连接
    func disconnect() async {
        await lifecycleService.disconnect()
    }

    // MARK: - Filtering

    /// 获取本地 Agent
    var localAgents: [AgentConfiguration] {
        agents.filter { $0.isLocal }
    }

    /// 获取远程 Agent
    var remoteAgents: [AgentConfiguration] {
        agents.filter { !$0.isLocal }
    }

    /// 按 Agent 类型分组
    func agentsByType() -> [AgentType: [AgentConfiguration]] {
        Dictionary(grouping: agents) { $0.agentType }
    }

    // MARK: - Validation

    /// 验证 Agent 配置
    func validateAgent(_ agent: AgentConfiguration) -> (isValid: Bool, error: String?) {
        // 验证名称
        if agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (false, "Agent 名称不能为空")
        }

        // 验证本地 Agent 的可执行文件路径
        if agent.isLocal {
            if agent.executablePath == nil || agent.executablePath!.isEmpty {
                return (false, "本地 Agent 需要指定可执行文件路径")
            }

            // TODO: 可以添加文件存在性检查
        }

        // 验证远程 Agent 的 URL
        if !agent.isLocal {
            if agent.remoteURL == nil || agent.remoteURL!.isEmpty {
                return (false, "远程 Agent 需要指定连接 URL")
            }

            // 验证 URL 格式
            if let urlString = agent.remoteURL,
               let url = URL(string: urlString) {
                if !url.isValidURL {
                    return (false, "URL 格式无效")
                }
            }
        }

        return (true, nil)
    }
}

// MARK: - URL Validation

private extension URL {
    var isValidURL: Bool {
        // 基本验证：检查 scheme 和 host
        guard scheme != nil, host != nil else {
            return false
        }
        return true
    }
}
