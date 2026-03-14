import Foundation

struct MemoryInfluenceTrace: Codable, Equatable, Sendable {
    var activatedMemoryIDs: [String] = []
    var rankedActionIDs: [String] = []
    var blockedActionIDs: [String] = []

    init(
        activatedMemoryIDs: [String] = [],
        rankedActionIDs: [String] = [],
        blockedActionIDs: [String] = []
    ) {
        self.activatedMemoryIDs = activatedMemoryIDs
        self.rankedActionIDs = rankedActionIDs
        self.blockedActionIDs = blockedActionIDs
    }
}