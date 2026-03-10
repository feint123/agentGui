import Foundation

struct TaskMemoryRecordFactory {
    func makeRecords(
        sessionId: String,
        confirmedFacts: [String],
        attemptedActions: [String],
        failedAttempts: [FailedAttempt],
        pendingQuestions: [String],
        verificationEntries: [VerificationEntry],
        timestamp: Date
    ) -> [MemoryRecord] {
        let scope = MemoryScope.session(id: sessionId)

        let confirmed = confirmedFacts.enumerated().map { index, fact in
            makeTextRecord(
                id: "task-confirmed-\(sessionId)-\(index)",
                scope: scope,
                title: fact,
                summary: fact,
                payload: .text(fact),
                verificationStatus: .verified,
                timestamp: timestamp,
                tags: ["confirmed-fact"]
            )
        }

        let attempts = attemptedActions.enumerated().map { index, action in
            makeTextRecord(
                id: "task-attempt-\(sessionId)-\(index)",
                scope: scope,
                title: action,
                summary: action,
                payload: .text(action),
                verificationStatus: .partial,
                timestamp: timestamp,
                tags: ["attempt"]
            )
        }

        let failures = failedAttempts.enumerated().map { index, failure in
            makeTextRecord(
                id: "task-failure-\(sessionId)-\(index)",
                scope: scope,
                title: failure.action,
                summary: failure.reason,
                payload: .structured([
                    "action": failure.action,
                    "reason": failure.reason
                ]),
                verificationStatus: .failed,
                timestamp: timestamp,
                tags: ["failed-attempt"]
            )
        }

        let pending = pendingQuestions.enumerated().map { index, question in
            makeTextRecord(
                id: "task-pending-\(sessionId)-\(index)",
                scope: scope,
                title: question,
                summary: question,
                payload: .text(question),
                verificationStatus: .unverified,
                timestamp: timestamp,
                tags: ["pending"]
            )
        }

        let verification = verificationEntries.enumerated().map { index, entry in
            makeTextRecord(
                id: "task-verification-\(sessionId)-\(index)",
                scope: scope,
                title: entry.item,
                summary: entry.status,
                payload: .structured([
                    "item": entry.item,
                    "status": entry.status
                ]),
                verificationStatus: status(from: entry.status),
                timestamp: timestamp,
                tags: ["verification-entry"]
            )
        }

        return confirmed + attempts + failures + pending + verification
    }

    private func makeTextRecord(
        id: String,
        scope: MemoryScope,
        title: String,
        summary: String,
        payload: MemoryRecord.Payload,
        verificationStatus: MemoryRecord.VerificationStatus,
        timestamp: Date,
        tags: [String]
    ) -> MemoryRecord {
        MemoryRecord(
            id: id,
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            scope: scope,
            title: title,
            summary: summary,
            payload: payload,
            source: .taskMemory,
            sourceRefs: [],
            confidence: verificationStatus == .verified ? 1.0 : 0.8,
            verificationStatus: verificationStatus,
            retentionPolicy: .sessionBound,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastAccessedAt: nil,
            supersededBy: nil,
            tags: tags
        )
    }

    private func status(from rawValue: String) -> MemoryRecord.VerificationStatus {
        MemoryRecord.VerificationStatus(rawValue: rawValue) ?? .partial
    }
}