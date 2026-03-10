import Foundation
import SwiftData

@MainActor
struct StoryMemoryStoreAdapter {
    let modelContext: ModelContext

    func semanticRecords(projectId: UUID) throws -> [MemoryRecord] {
        let retrieval = StoryMemoryRetrievalService(modelContext: modelContext)
        let characters = try fetchProject(id: projectId).characters
        let rules = try retrieval.worldRules(projectId: projectId)
        let locations = try retrieval.locations(projectId: projectId)
        let style = try retrieval.styleProfile(projectId: projectId)

        let characterRecords = characters.map { character in
            MemoryRecord(
                id: "story-character-\(character.id.uuidString)",
                layer: .semantic,
                kind: .semantic,
                domainProfile: "creative-writing",
                scope: .project(id: projectId.uuidString),
                title: character.name,
                summary: character.summary,
                payload: .structured([
                    "name": character.name,
                    "summary": character.summary,
                    "arcStage": character.arcStage,
                    "lastKnownLocation": character.lastKnownLocation
                ]),
                source: .storyMemory,
                sourceRefs: [],
                confidence: 1.0,
                verificationStatus: .verified,
                retentionPolicy: .projectBound,
                createdAt: Date(),
                updatedAt: Date(),
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["character"]
            )
        }

        let ruleRecords = rules.map { rule in
            MemoryRecord(
                id: "story-rule-\(rule.id.uuidString)",
                layer: .semantic,
                kind: .semantic,
                domainProfile: "creative-writing",
                scope: .project(id: projectId.uuidString),
                title: rule.title,
                summary: rule.detail,
                payload: .structured([
                    "category": rule.category,
                    "detail": rule.detail,
                    "scope": rule.scope
                ]),
                source: .storyMemory,
                sourceRefs: [],
                confidence: 1.0,
                verificationStatus: .verified,
                retentionPolicy: .projectBound,
                createdAt: Date(),
                updatedAt: Date(),
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["world-rule"]
            )
        }

        let locationRecords = locations.map { location in
            MemoryRecord(
                id: "story-location-\(location.id.uuidString)",
                layer: .semantic,
                kind: .semantic,
                domainProfile: "creative-writing",
                scope: .project(id: projectId.uuidString),
                title: location.name,
                summary: location.summary,
                payload: .structured([
                    "name": location.name,
                    "summary": location.summary
                ]),
                source: .storyMemory,
                sourceRefs: [],
                confidence: 1.0,
                verificationStatus: .verified,
                retentionPolicy: .projectBound,
                createdAt: Date(),
                updatedAt: Date(),
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["location"]
            )
        }

        let styleRecords: [MemoryRecord]
        if let style {
            styleRecords = [
                MemoryRecord(
                    id: "story-style-\(style.id.uuidString)",
                    layer: .semantic,
                    kind: .semantic,
                    domainProfile: "creative-writing",
                    scope: .project(id: projectId.uuidString),
                    title: "Style Profile",
                    summary: style.authorPreferences,
                    payload: .structured([
                        "authorPreferences": style.authorPreferences,
                        "narrativeVoice": style.narrativeVoice
                    ]),
                    source: .storyMemory,
                    sourceRefs: [],
                    confidence: 1.0,
                    verificationStatus: .verified,
                    retentionPolicy: .projectBound,
                    createdAt: Date(),
                    updatedAt: Date(),
                    lastAccessedAt: nil,
                    supersededBy: nil,
                    tags: ["style"]
                )
            ]
        } else {
            styleRecords = []
        }

        return characterRecords + ruleRecords + locationRecords + styleRecords
    }

    func episodicRecords(projectId: UUID) throws -> [MemoryRecord] {
        let retrieval = StoryMemoryRetrievalService(modelContext: modelContext)
        let project = try fetchProject(id: projectId)
        let scenes = try retrieval.scenes(projectId: projectId)
        let continuityIssues = try retrieval.continuityIssues(projectId: projectId)

        let eventRecords = project.timelineEvents.map { event in
            MemoryRecord(
                id: "story-event-\(event.id.uuidString)",
                layer: .episodic,
                kind: .episodic,
                domainProfile: "creative-writing",
                scope: .project(id: projectId.uuidString),
                title: event.title,
                summary: event.summary,
                payload: .structured([
                    "chapterNumber": String(event.chapterNumber),
                    "sceneIndex": String(event.sceneIndex),
                    "locationName": event.locationName
                ]),
                source: .storyMemory,
                sourceRefs: [],
                confidence: 1.0,
                verificationStatus: .verified,
                retentionPolicy: .projectBound,
                createdAt: Date(),
                updatedAt: Date(),
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["timeline-event"]
            )
        }

        let sceneRecords = scenes.map { scene in
            MemoryRecord(
                id: "story-scene-\(scene.id.uuidString)",
                layer: .episodic,
                kind: .episodic,
                domainProfile: "creative-writing",
                scope: .project(id: projectId.uuidString),
                title: scene.title,
                summary: scene.summary,
                payload: .structured([
                    "sceneIndex": String(scene.sceneIndex),
                    "povCharacterName": scene.povCharacterName,
                    "locationName": scene.locationName
                ]),
                source: .storyMemory,
                sourceRefs: [],
                confidence: 1.0,
                verificationStatus: .verified,
                retentionPolicy: .projectBound,
                createdAt: Date(),
                updatedAt: Date(),
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["scene"]
            )
        }

        let issueRecords = continuityIssues.map { issue in
            MemoryRecord(
                id: "story-continuity-\(issue.id.uuidString)",
                layer: .episodic,
                kind: .episodic,
                domainProfile: "creative-writing",
                scope: .project(id: projectId.uuidString),
                title: issue.issueKind,
                summary: issue.detail,
                payload: .structured([
                    "severity": issue.severity,
                    "resolutionStatus": issue.resolutionStatus,
                    "chapterNumber": String(issue.chapterNumber)
                ]),
                source: .storyMemory,
                sourceRefs: [],
                confidence: 1.0,
                verificationStatus: .verified,
                retentionPolicy: .projectBound,
                createdAt: Date(),
                updatedAt: Date(),
                lastAccessedAt: nil,
                supersededBy: nil,
                tags: ["continuity-issue"]
            )
        }

        return eventRecords + sceneRecords + issueRecords
    }

    private func fetchProject(id: UUID) throws -> WritingProject {
        let descriptor = FetchDescriptor<WritingProject>(predicate: #Predicate { $0.id == id })
        guard let project = try modelContext.fetch(descriptor).first else {
            throw StoryMemoryServiceError.projectNotFound(id)
        }
        return project
    }
}

extension StoryMemoryStoreAdapter: MemoryStoreAdapter {
    func records(for scope: MemoryScope) throws -> [MemoryRecord] {
        guard case let .project(id) = scope,
              let projectId = UUID(uuidString: id) else {
            return []
        }

        return try semanticRecords(projectId: projectId) + episodicRecords(projectId: projectId)
    }
}