import Foundation

enum BackgroundTaskTrustTier: String, Codable, CaseIterable {
    case observeOnly
    case maintain
    case actLimited
}

struct BackgroundTaskToolGrantPolicy: Codable, Equatable, Sendable {
    var trustTier: BackgroundTaskTrustTier
    var allowFileWrite: Bool
    var allowBash: Bool
    var allowMemoryMutation: Bool
    var allowNetworkAccess: Bool

    init(
        trustTier: BackgroundTaskTrustTier = .observeOnly,
        allowFileWrite: Bool = false,
        allowBash: Bool = false,
        allowMemoryMutation: Bool = false,
        allowNetworkAccess: Bool = false
    ) {
        self.trustTier = trustTier
        self.allowFileWrite = allowFileWrite
        self.allowBash = allowBash
        self.allowMemoryMutation = allowMemoryMutation
        self.allowNetworkAccess = allowNetworkAccess
    }
}

struct BackgroundTaskEffectiveToolGrantPolicy: Equatable, Sendable {
    var allowFileWrite: Bool
    var allowBash: Bool
    var allowMemoryMutation: Bool
    var allowNetworkAccess: Bool
}

extension BackgroundTaskToolGrantPolicy {
    func effectivePolicy(backgroundNetworkToolsEnabled: Bool) -> BackgroundTaskEffectiveToolGrantPolicy {
        switch trustTier {
        case .observeOnly:
            return BackgroundTaskEffectiveToolGrantPolicy(
                allowFileWrite: false,
                allowBash: false,
                allowMemoryMutation: false,
                allowNetworkAccess: allowNetworkAccess && backgroundNetworkToolsEnabled
            )
        case .maintain:
            return BackgroundTaskEffectiveToolGrantPolicy(
                allowFileWrite: false,
                allowBash: false,
                allowMemoryMutation: allowMemoryMutation,
                allowNetworkAccess: allowNetworkAccess && backgroundNetworkToolsEnabled
            )
        case .actLimited:
            return BackgroundTaskEffectiveToolGrantPolicy(
                allowFileWrite: allowFileWrite,
                allowBash: allowBash,
                allowMemoryMutation: allowMemoryMutation,
                allowNetworkAccess: allowNetworkAccess && backgroundNetworkToolsEnabled
            )
        }
    }
}