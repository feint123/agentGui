//
//  AgentRepository.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation
import SwiftData

/// Agent 数据仓库实现
@MainActor
final class AgentRepository: BaseRepository, AgentRepositoryProtocol {

    override init(modelContext: ModelContext) {
        super.init(modelContext: modelContext)
    }

    func fetchAll() async throws -> [AgentConfiguration] {
        let descriptor = FetchDescriptor<AgentConfiguration>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    func fetch(byId id: UUID) async throws -> AgentConfiguration? {
        let predicate = #Predicate<AgentConfiguration> { $0.id == id }
        let descriptor = FetchDescriptor<AgentConfiguration>(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }

    func save(_ agent: AgentConfiguration) async throws {
        if let existing = try? await fetch(byId: agent.id) {
            // 更新现有对象
            existing.name = agent.name
            existing.agentType = agent.agentType
            existing.connectionType = agent.connectionType
            existing.executablePath = agent.executablePath
            existing.arguments = agent.arguments
            existing.remoteURL = agent.remoteURL
            existing.authToken = agent.authToken
            existing.defaultWorkingDirectory = agent.defaultWorkingDirectory
            existing.environmentVariables = agent.environmentVariables
            existing.autoConnect = agent.autoConnect
            try modelContext.save()
        } else {
            // 创建新对象
            modelContext.insert(agent)
            try modelContext.save()
        }
    }

    func delete(_ agent: AgentConfiguration) async throws {
        modelContext.delete(agent)
        try modelContext.save()
    }

    func updateLastUsed(id: UUID) async throws {
        guard let agent = try? await fetch(byId: id) else {
            throw AgentClientError.agentNotFound(path: id.uuidString)
        }
        agent.lastUsedAt = Date()
        try modelContext.save()
    }

    func fetchDefault() async throws -> AgentConfiguration? {
        let settings = AppSettings.getOrCreate(in: modelContext)
        guard let defaultId = settings.defaultAgentId else {
            return try? await fetchAll().first
        }
        return try? await fetch(byId: defaultId)
    }
}
