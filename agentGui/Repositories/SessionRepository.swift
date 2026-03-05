//
//  SessionRepository.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation
import SwiftData

/// 会话数据仓库实现
@MainActor
final class SessionRepository: BaseRepository, SessionRepositoryProtocol {

    override init(modelContext: ModelContext) {
        super.init(modelContext: modelContext)
    }

    func fetchAll() async throws -> [Session] {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func fetch(byId id: String) async throws -> Session? {
        let predicate = #Predicate<Session> { $0.sessionId == id }
        let descriptor = FetchDescriptor<Session>(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }

    func create(_ session: Session) async throws {
        modelContext.insert(session)
        try modelContext.save()
    }

    func update(_ session: Session) async throws {
        session.updatedAt = Date()
        try modelContext.save()
    }

    func delete(_ session: Session) async throws {
        modelContext.delete(session)
        try modelContext.save()
    }

    func fetchRecent(limit: Int) async throws -> [Session] {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let results = try modelContext.fetch(descriptor)
        return Array(results.prefix(limit))
    }

    /// 获取活跃会话
    func fetchActive() async throws -> [Session] {
        let predicate = #Predicate<Session> { $0.isActive == true }
        let descriptor = FetchDescriptor<Session>(predicate: predicate)
        return try modelContext.fetch(descriptor)
    }
}
