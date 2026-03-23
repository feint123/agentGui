import Foundation

struct ChatComposerACPWarmupPolicy {
    static func shouldWarmup(
        slashQuery: String?,
        resolvedExecutionProviderID: ConversationExecutionProviderID,
        hasRemoteACPCommands: Bool,
        isWarmupInFlight: Bool
    ) -> Bool {
        guard slashQuery != nil else {
            return false
        }

        guard resolvedExecutionProviderID != .builtInAgent else {
            return false
        }

        guard !hasRemoteACPCommands else {
            return false
        }

        return !isWarmupInFlight
    }
}