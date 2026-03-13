import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryLifecycleManagerTests {
    @Test func lifecycleManagerDemotesColdRecordsAndProtectsHotVerifiedRecords() throws {
        let manager = MemoryLifecycleManager(budgeter: MemoryWorkingSetBudgeter())
        let records = [
            MemoryRecord.fixture(
                id: "verified-hot",
                layer: .task,
                kind: .working,
                title: "Verified hot fact",
                verificationStatus: .verified,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                lastAccessedAt: Date(timeIntervalSince1970: 1_000)
            ),
            MemoryRecord.fixture(
                id: "old-cold",
                layer: .semantic,
                kind: .semantic,
                title: "Old preference",
                verificationStatus: .unverified,
                updatedAt: Date(timeIntervalSince1970: 10),
                lastAccessedAt: Date(timeIntervalSince1970: 10)
            )
        ]

        let result = manager.rebalance(records: records, budget: .init(maxHotCount: 1, maxWarmCount: 2))

        #expect(result.updatedRecords.contains { $0.id == "verified-hot" && $0.lifecycleTier == MemoryLifecycleTier.hot })
        #expect(result.updatedRecords.contains { $0.id == "old-cold" && $0.lifecycleTier == MemoryLifecycleTier.cold })
        #expect(result.auditEntries.isEmpty == false)
    }
}