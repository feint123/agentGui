import Foundation

enum BackgroundTaskResultDeliveryMode: String, Codable, CaseIterable {
    case sessionMessages
    case summaryOnly
}

struct BackgroundTaskExecutionPolicy: Codable, Equatable, Sendable {
    var maxTurns: Int
    var maxExecutionSeconds: TimeInterval
    var maxConsecutiveFailures: Int
    var resultDeliveryMode: BackgroundTaskResultDeliveryMode
    var appendUserVisibleMessage: Bool

    init(
        maxTurns: Int = 12,
        maxExecutionSeconds: TimeInterval = 300,
        maxConsecutiveFailures: Int = 3,
        resultDeliveryMode: BackgroundTaskResultDeliveryMode = .sessionMessages,
        appendUserVisibleMessage: Bool = true
    ) {
        self.maxTurns = maxTurns
        self.maxExecutionSeconds = maxExecutionSeconds
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.resultDeliveryMode = resultDeliveryMode
        self.appendUserVisibleMessage = appendUserVisibleMessage
    }
}