//
//  RepositoryProtocols.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation
import SwiftData

// MARK: - Session Repository Protocol
/// 会话仓库协议
@MainActor
protocol SessionRepositoryProtocol: Sendable {
    func fetchAll() async throws -> [Session]
    func fetch(byId id: String) async throws -> Session?
    func create(_ session: Session) async throws
    func update(_ session: Session) async throws
    func delete(_ session: Session) async throws
    func fetchRecent(limit: Int) async throws -> [Session]
}

// MARK: - Message Repository Protocol
/// 消息仓库协议
@MainActor
protocol MessageRepositoryProtocol: Sendable {
    func fetch(bySessionId sessionId: String) async throws -> [Message]
    func add(_ message: Message) async throws
    func add(_ messages: [Message]) async throws
    func updateStatus(messageId: UUID, status: MessageStatus) async throws
    func deleteBySessionId(_ sessionId: String) async throws
    func count(bySessionId sessionId: String) async throws -> Int
}

// MARK: - Repository Base
/// 仓库基类
@MainActor
class BaseRepository {
    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
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
