import Foundation
import SwiftData

struct StoryCharacterDraft {
    var name: String
    var summary: String
    var traits: [String]
    var goals: [String]
    var speechStyle: String
    var relationships: [String: String]
    var arcStage: String
    var lastSeenChapter: Int
    var lastKnownLocation: String

    init(
        name: String,
        summary: String = "",
        traits: [String] = [],
        goals: [String] = [],
        speechStyle: String = "",
        relationships: [String: String] = [:],
        arcStage: String = "",
        lastSeenChapter: Int = 0,
        lastKnownLocation: String = ""
    ) {
        self.name = name
        self.summary = summary
        self.traits = traits
        self.goals = goals
        self.speechStyle = speechStyle
        self.relationships = relationships
        self.arcStage = arcStage
        self.lastSeenChapter = lastSeenChapter
        self.lastKnownLocation = lastKnownLocation
    }
}

struct StoryTimelineEventDraft {
    var chapterNumber: Int
    var sceneIndex: Int
    var title: String
    var summary: String
    var participants: [String]
    var locationName: String
    var timeMarker: String
    var eventType: String
    var foreshadowTags: [String]

    init(
        chapterNumber: Int,
        sceneIndex: Int,
        title: String,
        summary: String = "",
        participants: [String] = [],
        locationName: String = "",
        timeMarker: String = "",
        eventType: String = "",
        foreshadowTags: [String] = []
    ) {
        self.chapterNumber = chapterNumber
        self.sceneIndex = sceneIndex
        self.title = title
        self.summary = summary
        self.participants = participants
        self.locationName = locationName
        self.timeMarker = timeMarker
        self.eventType = eventType
        self.foreshadowTags = foreshadowTags
    }
}

enum StoryMemoryServiceError: Error {
    case projectNotFound(UUID)
}

@MainActor
final class StoryMemoryService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func createProject(title: String, synopsis: String) throws -> WritingProject {
        let project = WritingProject(title: title, synopsis: synopsis)
        modelContext.insert(project)
        try modelContext.save()
        return project
    }

    func attachProject(to session: Session, projectId: UUID) throws {
        _ = try fetchProject(id: projectId)
        session.activeWritingProjectId = projectId.uuidString
        session.updatedAt = Date()
        try modelContext.save()
    }

    @discardableResult
    func upsertCharacter(projectId: UUID, payload: StoryCharacterDraft) throws -> StoryCharacterProfile {
        let project = try fetchProject(id: projectId)

        let character: StoryCharacterProfile
        if let existing = project.characters.first(where: { $0.name == payload.name }) {
            character = existing
        } else {
            let created = StoryCharacterProfile(name: payload.name)
            created.project = project
            project.characters.append(created)
            character = created
        }

        character.summary = payload.summary
        character.traitsJSON = StoryMemoryJSONCodec.encode(payload.traits)
        character.goalsJSON = StoryMemoryJSONCodec.encode(payload.goals)
        character.speechStyle = payload.speechStyle
        character.relationshipMapJSON = StoryMemoryJSONCodec.encode(payload.relationships)
        character.arcStage = payload.arcStage
        character.lastSeenChapter = payload.lastSeenChapter
        character.lastKnownLocation = payload.lastKnownLocation
        project.updatedAt = Date()

        try modelContext.save()
        return character
    }

    @discardableResult
    func appendTimelineEvent(projectId: UUID, payload: StoryTimelineEventDraft) throws -> StoryTimelineEvent {
        let project = try fetchProject(id: projectId)
        let event = StoryTimelineEvent(
            chapterNumber: payload.chapterNumber,
            sceneIndex: payload.sceneIndex,
            title: payload.title,
            summary: payload.summary,
            participantNamesJSON: StoryMemoryJSONCodec.encode(payload.participants),
            locationName: payload.locationName,
            timeMarker: payload.timeMarker,
            eventType: payload.eventType,
            foreshadowTagsJSON: StoryMemoryJSONCodec.encode(payload.foreshadowTags)
        )
        event.project = project
        project.timelineEvents.append(event)
        project.updatedAt = Date()

        try modelContext.save()
        return event
    }

    private func fetchProject(id: UUID) throws -> WritingProject {
        let descriptor = FetchDescriptor<WritingProject>(predicate: #Predicate { $0.id == id })
        guard let project = try modelContext.fetch(descriptor).first else {
            throw StoryMemoryServiceError.projectNotFound(id)
        }
        return project
    }
}

enum StoryMemoryJSONCodec {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String, fallback: T) -> T {
        guard let data = string.data(using: .utf8), let value = try? JSONDecoder().decode(type, from: data) else {
            return fallback
        }
        return value
    }
}