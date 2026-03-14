import Foundation

enum MemoryRetrievalPhase: String, Codable, Equatable, Sendable {
    case understanding
    case frontierResolution
    case modification
    case verification
    case recovery
    case summarization
}

enum MemoryRetrievalObjectType: String, Codable, Equatable, Hashable, Sendable {
    case fact
    case episode
    case procedure
    case counterexample
    case constraint
    case verificationDebt
    case preference
}

struct MemoryRetrievalIntent: Codable, Equatable, Sendable {
    var phase: MemoryRetrievalPhase
    var neededObjectTypes: Set<MemoryRetrievalObjectType>
    var reason: String
}