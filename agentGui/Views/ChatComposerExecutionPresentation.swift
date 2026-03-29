import Foundation

struct ChatComposerExecutionPresentation: Equatable {
    let isComposerDisabled: Bool
    let showsRunningBadge: Bool
    let queueBadgeText: String?
    let statusBadgeText: String?
    let showsStopButton: Bool
    let showsSendButton: Bool
    let isSendDisabled: Bool

    static func shouldUseExecutionProjectionUI(for projection: SessionExecutionProjection) -> Bool {
        projection.isRunning ||
        projection.queuedCount > 0 ||
        projection.activityState != .idle ||
        projection.presentationState != .foreground ||
        projection.needsAttention ||
        projection.canEditComposer == false ||
        projection.canSubmitNewJob == false
    }

    static func resolve(
        usesExecutionProjectionUI: Bool,
        projection: SessionExecutionProjection,
        canSend: Bool
    ) -> Self {
        if usesExecutionProjectionUI {
            let statusBadgeText: String?
            if projection.needsAttention {
                statusBadgeText = "等待处理"
            } else if projection.presentationState == .background,
                      projection.activityState == .running {
                statusBadgeText = "后台运行"
            } else {
                statusBadgeText = nil
            }

            return Self(
                isComposerDisabled: !projection.canEditComposer,
                showsRunningBadge: projection.isRunning || projection.activityState == .blocked,
                queueBadgeText: projection.queuedCount > 0 ? "队列 \(projection.queuedCount)" : nil,
                statusBadgeText: statusBadgeText,
                showsStopButton: projection.isRunning,
                showsSendButton: true,
                isSendDisabled: !canSend || !projection.canSubmitNewJob
            )
        }

        return Self(
            isComposerDisabled: false,
            showsRunningBadge: false,
            queueBadgeText: nil,
            statusBadgeText: nil,
            showsStopButton: false,
            showsSendButton: true,
            isSendDisabled: !canSend
        )
    }
}