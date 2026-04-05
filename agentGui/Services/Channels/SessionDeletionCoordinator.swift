import Foundation
import SwiftData

@MainActor
struct SessionDeletionCoordinator {
    // R-B2: 可选的检查点 GC 服务注入，nil 时不执行 checkpoint purge（向后兼容）
    private let checkpointGCService: CheckpointGCService?

    init(checkpointGCService: CheckpointGCService? = nil) {
        self.checkpointGCService = checkpointGCService
    }

    func delete(_ session: Session, modelContext: ModelContext) async throws {
        guard SessionInteractionPolicy(session: session).canDelete else {
            throw SessionDeletionCoordinatorError.readOnlySession(session.sessionId)
        }
        let sessionID = session.sessionId
        pruneChannelResources(for: session, modelContext: modelContext)
        modelContext.delete(session)
        try modelContext.save()

        // R-B2: 清理检查点和备份文件
        if let gc = checkpointGCService {
            await gc.purgeSession(sessionID: sessionID, modelContext: modelContext)
        }
    }

    func deleteAllSessions(
        modelContext: ModelContext,
        sessions explicitSessions: [Session]? = nil,
        batchSize: Int = 50
    ) async {
        let sessions = explicitSessions ?? ((try? modelContext.fetch(FetchDescriptor<Session>())) ?? [])
        let effectiveBatchSize = max(1, batchSize)
        var pendingDeletes = 0
        var purgedIDs: [String] = []

        for session in sessions {
            guard SessionInteractionPolicy(session: session).canDelete else { continue }
            let sid = session.sessionId
            pruneChannelResources(for: session, modelContext: modelContext)
            modelContext.delete(session)
            purgedIDs.append(sid)
            pendingDeletes += 1

            if pendingDeletes == effectiveBatchSize {
                try? modelContext.save()
                pendingDeletes = 0
                await Task.yield()
            }
        }

        if pendingDeletes > 0 {
            try? modelContext.save()
        }

        // R-B2: 批量 purge
        if let gc = checkpointGCService {
            for sid in purgedIDs {
                await gc.purgeSession(sessionID: sid, modelContext: modelContext)
            }
        }
    }

    private func pruneChannelResources(for session: Session, modelContext: ModelContext) {
        let sessionID = session.sessionId
        let messageIDs = Set(session.messages.map(\.id))
        let conversationIDs = Set(session.remoteConversationBindings.map(\.externalConversationID))

        let remoteBindings = (try? modelContext.fetch(FetchDescriptor<RemoteConversationBinding>())) ?? []
        for binding in remoteBindings where binding.session === session || binding.sessionID == sessionID {
            modelContext.delete(binding)
        }

        let projectionBindings = (try? modelContext.fetch(FetchDescriptor<SessionProjectionBinding>())) ?? []
        for binding in projectionBindings where binding.session === session || binding.sessionID == sessionID {
            modelContext.delete(binding)
        }

        let deliveries = (try? modelContext.fetch(FetchDescriptor<ChannelProjectionDelivery>())) ?? []
        for delivery in deliveries where delivery.session === session || delivery.sessionID == sessionID {
            modelContext.delete(delivery)
        }

        let receipts = (try? modelContext.fetch(FetchDescriptor<RemoteMessageReceipt>())) ?? []
        for receipt in receipts where shouldDeleteReceipt(
            receipt,
            messageIDs: messageIDs,
            conversationIDs: conversationIDs
        ) {
            modelContext.delete(receipt)
        }
    }

    private func shouldDeleteReceipt(
        _ receipt: RemoteMessageReceipt,
        messageIDs: Set<UUID>,
        conversationIDs: Set<String>
    ) -> Bool {
        if let messageID = receipt.messageID, messageIDs.contains(messageID) {
            return true
        }
        return conversationIDs.contains(receipt.externalConversationID)
    }
}

enum SessionDeletionCoordinatorError: Error, Equatable {
    case readOnlySession(String)
}