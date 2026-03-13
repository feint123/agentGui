import Foundation

struct MemoryLifecycleAuditEntry: Equatable, Sendable {
    var recordID: String
    var from: MemoryLifecycleTier
    var to: MemoryLifecycleTier
    var reason: String
}

struct MemoryLifecycleRebalanceResult: Equatable, Sendable {
    var updatedRecords: [MemoryRecord]
    var auditEntries: [MemoryLifecycleAuditEntry]
}

struct MemoryLifecycleManager {
    private let budgeter: MemoryWorkingSetBudgeter

    init(budgeter: MemoryWorkingSetBudgeter = MemoryWorkingSetBudgeter()) {
        self.budgeter = budgeter
    }

    func rebalance(records: [MemoryRecord], budget: MemoryWorkingSetBudgeter.Budget? = nil) -> MemoryLifecycleRebalanceResult {
        let activeBudget = budget ?? budgeter.defaultBudget(for: records)
        let sorted = records.sorted { lhs, rhs in
            let lhsScore = score(for: lhs)
            let rhsScore = score(for: rhs)
            if lhsScore == rhsScore {
                return (lhs.lastAccessedAt ?? .distantPast) > (rhs.lastAccessedAt ?? .distantPast)
            }
            return lhsScore > rhsScore
        }

        var updated: [MemoryRecord] = []
        var audit: [MemoryLifecycleAuditEntry] = []

        for (index, record) in sorted.enumerated() {
            let newTier: MemoryLifecycleTier
            if index < activeBudget.maxHotCount && record.verificationStatus == .verified {
                newTier = .hot
            } else if record.verificationStatus != .verified {
                // Low-trust memories should fall out of the working set aggressively.
                newTier = .cold
            } else if index < activeBudget.maxWarmCount {
                newTier = .warm
            } else {
                newTier = .cold
            }

            let previousTier = record.lifecycleTier
            let rewritten = record.replacing(lifecycleTier: newTier)
            updated.append(rewritten)
            if previousTier != newTier {
                audit.append(MemoryLifecycleAuditEntry(recordID: record.id, from: previousTier, to: newTier, reason: "working-set rebalance"))
            }
        }

        return MemoryLifecycleRebalanceResult(updatedRecords: updated, auditEntries: audit)
    }

    private func score(for record: MemoryRecord) -> Double {
        let verificationBoost = record.verificationStatus == .verified ? 1.0 : 0.0
        let recency = record.lastAccessedAt?.timeIntervalSince1970 ?? record.updatedAt.timeIntervalSince1970
        return (record.confidence * 10) + verificationBoost + (recency / 10_000)
    }
}