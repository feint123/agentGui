import Foundation
import SwiftData

enum BackgroundTriggerSource: String, Codable, Equatable, Sendable {
    case scheduler
    case manual
}

enum BackgroundTaskRunStatus: String, Codable, Equatable, Sendable {
    case triggered
    case running
    case completed
    case failed
    case deferred
    case skipped
    case interrupted
}

enum BackgroundExecutionDecision: String, Codable, Equatable, Sendable {
    case pending
    case run
    case skip
    case `defer`
}

@Model
final class BackgroundAgentTaskRun {
    var id: UUID
    var taskID: UUID
    var schedulerIdentifier: String
    var triggerSource: BackgroundTriggerSource
    var scheduledWindowStart: Date?
    var scheduledWindowEnd: Date?
    var actualStartAt: Date?
    var finishedAt: Date?
    var status: BackgroundTaskRunStatus
    var decision: BackgroundExecutionDecision
    var deferReason: String?
    var skipReason: String?
    var resultSummary: String?
    var messageID: String?
    var agentSummaryJSON: String
    var businessEventDigestJSON: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        taskID: UUID,
        schedulerIdentifier: String,
        triggerSource: BackgroundTriggerSource = .scheduler,
        scheduledWindowStart: Date? = nil,
        scheduledWindowEnd: Date? = nil,
        actualStartAt: Date? = nil,
        finishedAt: Date? = nil,
        status: BackgroundTaskRunStatus = .triggered,
        decision: BackgroundExecutionDecision = .pending,
        deferReason: String? = nil,
        skipReason: String? = nil,
        resultSummary: String? = nil,
        messageID: String? = nil,
        agentSummaryJSON: String = "{}",
        businessEventDigestJSON: String = "[]",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.schedulerIdentifier = schedulerIdentifier
        self.triggerSource = triggerSource
        self.scheduledWindowStart = scheduledWindowStart
        self.scheduledWindowEnd = scheduledWindowEnd
        self.actualStartAt = actualStartAt
        self.finishedAt = finishedAt
        self.status = status
        self.decision = decision
        self.deferReason = deferReason
        self.skipReason = skipReason
        self.resultSummary = resultSummary
        self.messageID = messageID
        self.agentSummaryJSON = agentSummaryJSON
        self.businessEventDigestJSON = businessEventDigestJSON
        self.createdAt = createdAt
    }
}