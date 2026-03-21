import Foundation

struct ChatComposerExecutionPresentation: Equatable {
    let isComposerDisabled: Bool
    let showsRunningBadge: Bool
    let queueBadgeText: String?
    let showsStopButton: Bool
    let showsSendButton: Bool
    let isSendDisabled: Bool

    static func resolve(
        usesExecutionProjectionUI: Bool,
        projection: SessionExecutionProjection,
        legacyIsStreaming: Bool,
        canSend: Bool
    ) -> Self {
        if usesExecutionProjectionUI {
            return Self(
                isComposerDisabled: !projection.canEditComposer,
                showsRunningBadge: projection.isRunning,
                queueBadgeText: projection.queuedCount > 0 ? "队列 \(projection.queuedCount)" : nil,
                showsStopButton: projection.isRunning,
                showsSendButton: true,
                isSendDisabled: !canSend || !projection.canSubmitNewJob
            )
        }

        return Self(
            isComposerDisabled: legacyIsStreaming,
            showsRunningBadge: false,
            queueBadgeText: nil,
            showsStopButton: legacyIsStreaming,
            showsSendButton: !legacyIsStreaming,
            isSendDisabled: !canSend
        )
    }
}