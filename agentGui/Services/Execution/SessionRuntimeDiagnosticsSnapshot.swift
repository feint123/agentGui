import Foundation

struct SessionRuntimeDiagnosticsSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let sessionID: String
    let activityText: String
    let providerText: String
    let queuedCount: Int
    let isCancelling: Bool
    let lastActionText: String

    init(snapshot: SessionRuntimeSnapshot) {
        self.id = snapshot.sessionID
        self.sessionID = snapshot.sessionID
        self.activityText = Self.activityText(for: snapshot)
        self.providerText = Self.providerText(
            for: snapshot.runningProviderReference ?? snapshot.lastKnownProviderReference
        )
        self.queuedCount = snapshot.queuedJobIDs.count
        self.isCancelling = snapshot.isCancelling
        self.lastActionText = Self.lastActionText(for: snapshot.lastAction)
    }

    private static func activityText(for snapshot: SessionRuntimeSnapshot) -> String {
        if snapshot.isCancelling {
            return "取消中"
        }
        if snapshot.isRunning {
            return "运行中"
        }
        if snapshot.queuedJobIDs.isEmpty == false {
            return "排队中"
        }
        return "空闲"
    }

    private static func providerText(for reference: ExecutionProviderReference?) -> String {
        guard let reference else {
            return "Unknown"
        }

        switch reference {
        case .builtIn:
            return "Built-in"
        case let .externalACP(profileID):
            return "External ACP \(profileID.uuidString.prefix(8))"
        }
    }

    private static func lastActionText(for action: SessionRuntimeSnapshot.Action) -> String {
        switch action {
        case .idle:
            return "idle"
        case .enqueued:
            return "enqueued"
        case .recovered:
            return "recovered"
        case .started:
            return "started"
        case .cancelRequested:
            return "cancel requested"
        case let .finished(outcome):
            return "finished: \(outcome.rawValue)"
        case .pruned:
            return "pruned"
        }
    }
}