//
//  RepositoryProtocols.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation
import SwiftData

// MARK: - Agent Repository Protocol
/// Agent 仓库协议
@MainActor
protocol AgentRepositoryProtocol: Sendable {
    /// 获取所有 Agent 配置
    func fetchAll() async throws -> [AgentConfiguration]

    /// 按 ID 获取
    func fetch(byId id: UUID) async throws -> AgentConfiguration?

    /// 创建或更新
    func save(_ agent: AgentConfiguration) async throws

    /// 删除
    func delete(_ agent: AgentConfiguration) async throws

    /// 更新最后使用时间
    func updateLastUsed(id: UUID) async throws

    /// 获取默认 Agent
    func fetchDefault() async throws -> AgentConfiguration?
}

// MARK: - Session Repository Protocol
/// 会话仓库协议
@MainActor
protocol SessionRepositoryProtocol: Sendable {
    /// 获取所有会话
    func fetchAll() async throws -> [Session]

    /// 按 ID 获取
    func fetch(byId id: String) async throws -> Session?

    /// 按 Agent 获取会话列表
    func fetch(byAgentId agentId: UUID) async throws -> [Session]

    /// 创建会话
    func create(_ session: Session) async throws

    /// 更新会话
    func update(_ session: Session) async throws

    /// 删除会话
    func delete(_ session: Session) async throws

    /// 获取最近使用的会话
    func fetchRecent(limit: Int) async throws -> [Session]
}

// MARK: - Message Repository Protocol
/// 消息仓库协议
@MainActor
protocol MessageRepositoryProtocol: Sendable {
    /// 获取会话的所有消息
    func fetch(bySessionId sessionId: String) async throws -> [Message]

    /// 添加消息
    func add(_ message: Message) async throws

    /// 批量添加消息
    func add(_ messages: [Message]) async throws

    /// 更新消息状态
    func updateStatus(messageId: UUID, status: MessageStatus) async throws

    /// 删除会话的所有消息
    func deleteBySessionId(_ sessionId: String) async throws

    /// 获取消息数量
    func count(bySessionId sessionId: String) async throws -> Int
}

// MARK: - Repository Base
/// 仓库基类，提供通用的数据访问功能
@MainActor
class BaseRepository {
    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetch<T: PersistentModel>(byId id: UUID) -> T? where T: Identifiable, T.ID == UUID {
        let predicate = #Predicate<T> { $0.id == id }
        let descriptor = FetchDescriptor<T>(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }

    func save<T: PersistentModel>(_ model: T) throws {
        modelContext.insert(model)
        try modelContext.save()
    }

    func delete<T: PersistentModel>(_ model: T) throws {
        modelContext.delete(model)
        try modelContext.save()
    }
}
