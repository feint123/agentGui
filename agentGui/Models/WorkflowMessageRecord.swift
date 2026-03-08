//
//  WorkflowMessageRecord.swift
//  agentGui
//
//  SwiftData model for persisting inter-agent messages within a workflow.
//  These are the formal communication objects that the WorkflowRuntime
//  delivers between roles via mailboxes.
//

import SwiftData
import Foundation

@Model
final class WorkflowMessageRecord {

    // MARK: - Identity

    var id: UUID
    var workflowId: UUID

    // MARK: - Routing

    var sender: String
    /// JSON-encoded [String] — recipients list.
    var recipientsJson: String
    var kindRaw: String

    // MARK: - Content

    var subject: String
    var body: String
    /// JSON-encoded [String] — artifact ids referenced by this message.
    var artifactRefsJson: String

    // MARK: - Threading

    /// The id of the message this is a reply to, if any.
    var replyToId: UUID?

    // MARK: - Timestamps

    var createdAt: Date

    // MARK: - Relationship back to owner

    var workflow: WorkflowInstance?

    // MARK: - Init

    init(
        id: UUID = UUID(),
        workflowId: UUID,
        sender: String,
        recipients: [String],
        kind: WorkflowMessageKind,
        subject: String,
        body: String,
        artifactRefs: [String] = [],
        replyToId: UUID? = nil
    ) {
        self.id = id
        self.workflowId = workflowId
        self.sender = sender
        self.kindRaw = kind.rawValue
        self.subject = subject
        self.body = body
        self.replyToId = replyToId
        self.createdAt = Date()
        let encoder = JSONEncoder()
        self.recipientsJson = (try? String(data: encoder.encode(recipients), encoding: .utf8)) ?? "[]"
        self.artifactRefsJson = (try? String(data: encoder.encode(artifactRefs), encoding: .utf8)) ?? "[]"
    }
}

// MARK: - Computed Properties

extension WorkflowMessageRecord {

    var kind: WorkflowMessageKind {
        WorkflowMessageKind(rawValue: kindRaw) ?? .statusUpdate
    }

    var recipients: [String] {
        guard let data = recipientsJson.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    var artifactRefs: [String] {
        guard let data = artifactRefsJson.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }
}
