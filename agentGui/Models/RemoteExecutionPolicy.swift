import Foundation

struct RemoteExecutionPolicy: Codable, Equatable, Sendable {
    var maxRounds: Int

    init(
        maxRounds: Int = 64
    ) {
        self.maxRounds = maxRounds
    }
}