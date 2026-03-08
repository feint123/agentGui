//
//  WorkflowArtifactRecord.swift
//  agentGui
//
//  SwiftData model for persisting structured workflow artifacts (plans, reports, summaries).
//  Each artifact has a version number so reviewers always see the latest patch,
//  and older versions are retained for debugging/replay.
//

import SwiftData
import Foundation

@Model
final class WorkflowArtifactRecord {

    // MARK: - Identity

    /// Stable logical id shared across versions (e.g. "plan-<workflowId>").
    var artifactId: String
    var workflowId: UUID

    // MARK: - Classification

    var kindRaw: String
    var title: String
    var producer: String

    // MARK: - Versioning

    /// Monotonically increasing. v1 is the first draft; each update bumps this.
    var version: Int
    var statusRaw: String

    // MARK: - Content

    /// The artifact content stored as a JSON string. Schema depends on kind.
    var contentJson: String

    // MARK: - Timestamps

    var createdAt: Date
    var updatedAt: Date

    // MARK: - Relationship back to owner

    var workflow: WorkflowInstance?

    // MARK: - Init

    init(
        artifactId: String,
        workflowId: UUID,
        kind: WorkflowArtifactKind,
        title: String,
        producer: String,
        version: Int = 1,
        contentJson: String,
        status: ArtifactStatus = .draft
    ) {
        self.artifactId = artifactId
        self.workflowId = workflowId
        self.kindRaw = kind.rawValue
        self.title = title
        self.producer = producer
        self.version = version
        self.contentJson = contentJson
        self.statusRaw = status.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Computed Properties

extension WorkflowArtifactRecord {

    var kind: WorkflowArtifactKind {
        WorkflowArtifactKind(rawValue: kindRaw) ?? .finalAnswer
    }

    var status: ArtifactStatus {
        get { ArtifactStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue; updatedAt = Date() }
    }

    /// Attempt to decode the content as a pretty-printed JSON string for display.
    var formattedContent: String {
        guard let data = contentJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8)
        else { return contentJson }
        return str
    }
}
