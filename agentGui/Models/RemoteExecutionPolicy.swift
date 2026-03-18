import Foundation

struct RemoteExecutionPolicy: Codable, Equatable, Sendable {
    var allowFileWrite: Bool
    var allowBash: Bool
    var allowNetworkTools: Bool
    var maxRounds: Int

    init(
        allowFileWrite: Bool = false,
        allowBash: Bool = false,
        allowNetworkTools: Bool = false,
        maxRounds: Int = 64
    ) {
        self.allowFileWrite = allowFileWrite
        self.allowBash = allowBash
        self.allowNetworkTools = allowNetworkTools
        self.maxRounds = maxRounds
    }
}