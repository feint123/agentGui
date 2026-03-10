import Foundation

struct MemorySweepReport: Codable, Equatable, Sendable {
    var runAt: Date
    var archivedCount: Int
    var revalidationCount: Int
    var skippedCount: Int
    var totalProcessed: Int

    init(
        runAt: Date = Date(),
        archivedCount: Int,
        revalidationCount: Int,
        skippedCount: Int = 0
    ) {
        self.runAt = runAt
        self.archivedCount = archivedCount
        self.revalidationCount = revalidationCount
        self.skippedCount = skippedCount
        self.totalProcessed = archivedCount + revalidationCount + skippedCount
    }
}