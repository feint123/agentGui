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
        makeEpisodeDeltaRecords(
            sessionId: sessionId,
            confirmedFacts: confirmedFacts,
            attemptedActions: attemptedActions,
            failedAttempts: failedAttempts,
            pendingQuestions: pendingQuestions,
            verificationEntries: verificationEntries,
            timestamp: timestamp
        )
    }

    func makeEpisodeDeltaRecords(
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
                payload: .structured([
                    "episode_type": "confirmed_fact",
                    "fact": fact
                ]),
                verificationStatus: .verified,
                timestamp: timestamp,
                tags: ["episode-delta"]
            )
        }

        let attempts = attemptedActions.enumerated().map { index, action in
            makeTextRecord(
                id: "task-attempt-\(sessionId)-\(index)",
                scope: scope,
                title: action,
                summary: action,
                payload: .structured([
                    "episode_type": "attempted_action",
                    "action": action
                ]),
                verificationStatus: .partial,
                timestamp: timestamp,
                tags: ["episode-delta"]
            )
        }

        let failures = failedAttempts.enumerated().map { index, failure in
            makeTextRecord(
                id: "task-failure-\(sessionId)-\(index)",
                scope: scope,
                title: failure.action,
                summary: failure.reason,
                payload: .structured([
                    "episode_type": "failed_attempt",
                    "action": failure.action,
                    "reason": failure.reason
                ]),
                verificationStatus: .failed,
                timestamp: timestamp,
                tags: ["episode-delta"]
            )
        }

        let pending = pendingQuestions.enumerated().map { index, question in
            makeTextRecord(
                id: "task-pending-\(sessionId)-\(index)",
                scope: scope,
                title: question,
                summary: question,
                payload: .structured([
                    "episode_type": "pending_question",
                    "question": question
                ]),
                verificationStatus: .unverified,
                timestamp: timestamp,
                tags: ["episode-delta"]
            )
        }

        let verification = verificationEntries.enumerated().map { index, entry in
            makeTextRecord(
                id: "task-verification-\(sessionId)-\(index)",
                scope: scope,
                title: entry.item,
                summary: entry.status,
                payload: .structured([
                    "episode_type": "verification_entry",
                    "item": entry.item,
                    "status": entry.status
                ]),
                verificationStatus: status(from: entry.status),
                timestamp: timestamp,
                tags: ["episode-delta"]
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