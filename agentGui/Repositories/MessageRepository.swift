//
//  MessageRepository.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation
import SwiftData

/// 消息数据仓库实现
@MainActor
final class MessageRepository: BaseRepository, MessageRepositoryProtocol {

    override init(modelContext: ModelContext) {
        super.init(modelContext: modelContext)
    }

    func fetch(bySessionId sessionId: String) async throws -> [Message] {
        let predicate = #Predicate<Message> { $0.session?.sessionId == sessionId }
        let descriptor = FetchDescriptor<Message>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sequence, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    func add(_ message: Message) async throws {
        try save(message)
    }

    func add(_ messages: [Message]) async throws {
        for message in messages {
            try save(message)
        }
    }

    func updateStatus(messageId: UUID, status: MessageStatus) async throws {
        let predicate = #Predicate<Message> { $0.id == messageId }
        let descriptor = FetchDescriptor<Message>(predicate: predicate)
        guard let message = try? modelContext.fetch(descriptor).first else {
            throw ClaudeError.streamFailed(NSError(domain: "agentGui", code: 404, userInfo: [NSLocalizedDescriptionKey: "消息未找到"]))
        }
        message.status = status
        try modelContext.save()
    }

    func deleteBySessionId(_ sessionId: String) async throws {
        let predicate = #Predicate<Message> { $0.session?.sessionId == sessionId }
        let descriptor = FetchDescriptor<Message>(predicate: predicate)
        let messages = try modelContext.fetch(descriptor)

        for message in messages {
            modelContext.delete(message)
        }

        try modelContext.save()
    }

    func count(bySessionId sessionId: String) async throws -> Int {
        let predicate = #Predicate<Message> { $0.session?.sessionId == sessionId }
        let descriptor = FetchDescriptor<Message>(predicate: predicate)
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// 获取会话的最后一条消息
    func fetchLastMessage(sessionId: String) async throws -> Message? {
        let messages = try await fetch(bySessionId: sessionId)
        return messages.last
    }
}
