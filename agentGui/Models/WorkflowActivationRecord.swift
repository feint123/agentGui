//
//  WorkflowActivationRecord.swift
//  agentGui
//
//  SwiftData model for recording a single agent role activation within a workflow.
//  Each time the scheduler wakes up an agent, one record is created. This provides
//  a full audit trail and enables UI timeline visualisation.
//

import SwiftData
import Foundation

@Model
final class WorkflowActivationRecord {

    // MARK: - Identity

    var id: UUID
    var workflowId: UUID

    // MARK: - Role

    var role: String
    var roleDisplayName: String

    // MARK: - Trigger

    /// The WorkflowMessageRecord id that triggered this activation, if any.
    var triggerMessageId: UUID?
    /// Human-readable description of why this role was activated.
    var triggerReason: String

    // MARK: - Execution

    var startedAt: Date
    var completedAt: Date?
    var turnsUsed: Int
    var resultKindRaw: String
    var resultSummary: String

    // MARK: - Relationship back to owner

    var workflow: WorkflowInstance?

    // MARK: - Init

    init(
        id: UUID = UUID(),
        workflowId: UUID,
        role: String,
        roleDisplayName: String,
        triggerMessageId: UUID? = nil,
        triggerReason: String = ""
    ) {
        self.id = id
        self.workflowId = workflowId
        self.role = role
        self.roleDisplayName = roleDisplayName
        self.triggerMessageId = triggerMessageId
        self.triggerReason = triggerReason
        self.startedAt = Date()
        self.completedAt = nil
        self.turnsUsed = 0
        self.resultKindRaw = ActivationResultKind.success.rawValue
        self.resultSummary = ""
    }
}

// MARK: - Computed Properties

extension WorkflowActivationRecord {

    var resultKind: ActivationResultKind {
        get { ActivationResultKind(rawValue: resultKindRaw) ?? .success }
        set { resultKindRaw = newValue.rawValue }
    }

    var duration: TimeInterval? {
        guard let completed = completedAt else { return nil }
        return completed.timeIntervalSince(startedAt)
    }

    var isCompleted: Bool { completedAt != nil }

    func markCompleted(
        turnsUsed: Int,
        result: ActivationResultKind,
        summary: String
    ) {
        self.completedAt = Date()
        self.turnsUsed = turnsUsed
        self.resultKind = result
        self.resultSummary = summary
    }
}
