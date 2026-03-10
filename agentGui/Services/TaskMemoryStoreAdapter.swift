import Foundation

struct TaskMemoryStoreAdapter {
    let service: TaskMemoryService

    init(service: TaskMemoryService = .shared) {
        self.service = service
    }

    func load(sessionId: String) -> TaskMemory? {
        service.load(sessionId: sessionId)
    }

    func project(memory: TaskMemory) -> [MemoryRecord] {
        let scope = MemoryScope.session(id: memory.sessionId)
        let timestamp = memory.lastUpdated

        let facts = memory.confirmedFacts.enumerated().map { index, fact in
            MemoryRecord(
                id: "task-fact-\(memory.sessionId)-\(index)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: scope,
                title: fact,
                summary: fact,
                payload: .text(fact),
                source: .taskMemory,
                sourceRefs: [],
                confidence: 1.0,
                verificationStatus: .verified,
                retentionPolicy: .sessionBound,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["confirmed-fact"]
            )
        }

        let attempts = memory.attemptedActions.enumerated().map { index, action in
            MemoryRecord(
                id: "task-attempt-\(memory.sessionId)-\(index)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: scope,
                title: action,
                summary: action,
                payload: .text(action),
                source: .taskMemory,
                sourceRefs: [],
                confidence: 0.8,
                verificationStatus: .partial,
                retentionPolicy: .sessionBound,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["attempt"]
            )
        }

        let failures = memory.failedAttempts.enumerated().map { index, attempt in
            MemoryRecord(
                id: "task-failure-\(memory.sessionId)-\(index)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: scope,
                title: attempt.action,
                summary: attempt.reason,
                payload: .structured([
                    "action": attempt.action,
                    "reason": attempt.reason
                ]),
                source: .taskMemory,
                sourceRefs: [],
                confidence: 0.9,
                verificationStatus: .failed,
                retentionPolicy: .sessionBound,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["failed-attempt"]
            )
        }

        let pending = memory.pendingQuestions.enumerated().map { index, question in
            MemoryRecord(
                id: "task-pending-\(memory.sessionId)-\(index)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: scope,
                title: question,
                summary: question,
                payload: .text(question),
                source: .taskMemory,
                sourceRefs: [],
                confidence: 0.5,
                verificationStatus: .unverified,
                retentionPolicy: .sessionBound,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["pending"]
            )
        }

        return facts + attempts + failures + pending
    }
}

extension TaskMemoryStoreAdapter: MemoryStoreAdapter {
    func records(for scope: MemoryScope) throws -> [MemoryRecord] {
        guard case let .session(id) = scope, let memory = load(sessionId: id) else {
            return []
        }

        return project(memory: memory)
    }
}