import Foundation

struct MemoryBridgeEdge: Codable, Equatable, Sendable, Identifiable {
    var id: String {
        "\(sourceRecordID)->\(targetRecordID):\(relationship)"
    }

    var sourceRecordID: String
    var targetRecordID: String
    var relationship: String
}