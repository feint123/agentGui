//
//  WorkflowInstance.swift
//  agentGui
//
//  SwiftData model that represents a running (or completed) workflow.
//  Each instance tracks status, budget consumption, and owns the related
//  message, artifact, and activation records via cascade relationships.
//

import SwiftData
import Foundation

@Model
final class WorkflowInstance {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    // MARK: - Identity

    var id: UUID
    /// The Session this workflow belongs to.
    var sessionId: String
    /// Identifies the WorkflowDefinition template used (e.g. "code_change").
    var definitionId: String

    // MARK: - State

    /// Serialised WorkflowStatus raw value.
    var statusRaw: String
    var userTask: String
    var startedAt: Date
    var updatedAt: Date

    /// Serialised WorkflowBudget — stored as JSON for schema flexibility.
    var budgetJson: String
    /// Serialised WorkflowPolicies.
    var policiesJson: String

    // MARK: - Relationships

    @Relationship(deleteRule: .cascade)
    var messages: [WorkflowMessageRecord] = []

    @Relationship(deleteRule: .cascade)
    var artifacts: [WorkflowArtifactRecord] = []

    @Relationship(deleteRule: .cascade)
    var activations: [WorkflowActivationRecord] = []

    // MARK: - Init

    init(
        id: UUID = UUID(),
        sessionId: String,
        definitionId: String,
        userTask: String,
        budget: WorkflowBudget = .default,
        policies: WorkflowPolicies = .default
    ) {
        self.id = id
        self.sessionId = sessionId
        self.definitionId = definitionId
        self.statusRaw = WorkflowStatus.pending.rawValue
        self.userTask = userTask
        self.startedAt = Date()
        self.updatedAt = Date()
        let encoder = JSONEncoder()
        self.budgetJson = (try? String(data: encoder.encode(budget), encoding: .utf8)) ?? "{}"
        self.policiesJson = (try? String(data: encoder.encode(policies), encoding: .utf8)) ?? "{}"
    }
}

// MARK: - Computed Properties

extension WorkflowInstance {

    var status: WorkflowStatus {
        get { WorkflowStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue; updatedAt = Date() }
    }

    var budget: WorkflowBudget {
        guard let data = budgetJson.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WorkflowBudget.self, from: data)
        else { return .default }
        return decoded
    }

    var policies: WorkflowPolicies {
        guard let data = policiesJson.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WorkflowPolicies.self, from: data)
        else { return .default }
        return decoded
    }

    /// Activations sorted chronologically.
    var sortedActivations: [WorkflowActivationRecord] {
        activations.sorted { $0.startedAt < $1.startedAt }
    }

    /// Messages sorted chronologically.
    var sortedMessages: [WorkflowMessageRecord] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Latest version of each artifact (by kind, keeping highest version).
    var latestArtifacts: [WorkflowArtifactRecord] {
        var best: [String: WorkflowArtifactRecord] = [:]
        for a in artifacts {
            if let existing = best[a.kindRaw] {
                if a.version > existing.version { best[a.kindRaw] = a }
            } else {
                best[a.kindRaw] = a
            }
        }
        return Array(best.values).sorted { $0.kindRaw < $1.kindRaw }
    }
}
