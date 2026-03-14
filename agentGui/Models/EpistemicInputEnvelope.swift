import Foundation

struct EpistemicInputEnvelope: Codable, Equatable, Sendable {
    var sessionID: String
    var roundIndex: Int
    var userAgentMessages: [String]
    var toolObservations: [String]
    var events: [AtomicEpistemicEvent]

    init(
        sessionID: String,
        roundIndex: Int,
        userAgentMessages: [String] = [],
        toolObservations: [String] = [],
        events: [AtomicEpistemicEvent] = []
    ) {
        self.sessionID = sessionID
        self.roundIndex = roundIndex
        self.userAgentMessages = userAgentMessages
        self.toolObservations = toolObservations
        self.events = events
    }
}