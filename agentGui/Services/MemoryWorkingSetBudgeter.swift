import Foundation

struct MemoryWorkingSetBudgeter {
    struct Budget: Equatable, Sendable {
        var maxHotCount: Int
        var maxWarmCount: Int
    }

    func defaultBudget(for records: [MemoryRecord]) -> Budget {
        Budget(maxHotCount: max(1, min(8, records.count)), maxWarmCount: max(2, min(32, records.count)))
    }
}