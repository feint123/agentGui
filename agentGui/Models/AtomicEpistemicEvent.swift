import Foundation

enum AtomicEpistemicEventKind: String, Codable, Equatable, Sendable {
    case goalDeclared
    case claimRaised
    case actionProposed
    case observationReceived
    case constraintDeclared
    case claimResolved
}

struct AtomicEpistemicEvent: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: AtomicEpistemicEventKind
    var summary: String
    var sourceRefs: [String]

    init(
        id: String = UUID().uuidString,
        kind: AtomicEpistemicEventKind,
        summary: String,
        sourceRefs: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.sourceRefs = sourceRefs
    }
}