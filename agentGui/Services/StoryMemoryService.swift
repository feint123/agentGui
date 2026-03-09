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

struct StoryChapterDraft {
    var chapterNumber: Int
    var title: String
    var outline: String
    var summary: String
    var toneDirective: String
    var isLocked: Bool

    init(
        chapterNumber: Int,
        title: String,
        outline: String = "",
        summary: String = "",
        toneDirective: String = "",
        isLocked: Bool = false
    ) {
        self.chapterNumber = chapterNumber
        self.title = title
        self.outline = outline
        self.summary = summary
        self.toneDirective = toneDirective
        self.isLocked = isLocked
    }
}

struct StorySceneDraft {
    var chapterNumber: Int
    var sceneIndex: Int
    var title: String
    var content: String
    var povCharacterName: String
    var locationName: String
    var characterNames: [String]
    var summary: String
    var previousSceneId: UUID?
    var timelineEventId: UUID?

    init(
        chapterNumber: Int,
        sceneIndex: Int,
        title: String,
        content: String = "",
        povCharacterName: String = "",
        locationName: String = "",
        characterNames: [String] = [],
        summary: String = "",
        previousSceneId: UUID? = nil,
        timelineEventId: UUID? = nil
    ) {
        self.chapterNumber = chapterNumber
        self.sceneIndex = sceneIndex
        self.title = title
        self.content = content
        self.povCharacterName = povCharacterName
        self.locationName = locationName
        self.characterNames = characterNames
        self.summary = summary
        self.previousSceneId = previousSceneId
        self.timelineEventId = timelineEventId
    }
}

struct StoryWorldRuleDraft {
    var title: String
    var category: String
    var detail: String
    var scope: String
    var exceptions: [String]
    var establishedInChapter: Int
    var relatedEntities: [String]
    var mutablePolicy: String

    init(
        title: String,
        category: String = "",
        detail: String = "",
        scope: String = "",
        exceptions: [String] = [],
        establishedInChapter: Int = 0,
        relatedEntities: [String] = [],
        mutablePolicy: String = "immutable"
    ) {
        self.title = title
        self.category = category
        self.detail = detail
        self.scope = scope
        self.exceptions = exceptions
        self.establishedInChapter = establishedInChapter
        self.relatedEntities = relatedEntities
        self.mutablePolicy = mutablePolicy
    }
}

struct StoryLocationDraft {
    var name: String
    var summary: String
    var traits: [String]
    var relatedRules: [String]
    var occupantNames: [String]

    init(
        name: String,
        summary: String = "",
        traits: [String] = [],
        relatedRules: [String] = [],
        occupantNames: [String] = []
    ) {
        self.name = name
        self.summary = summary
        self.traits = traits
        self.relatedRules = relatedRules
        self.occupantNames = occupantNames
    }
}

struct StoryForeshadowDraft {
    var tag: String
    var introducedInChapter: Int
    var detail: String
    var relatedEventIds: [UUID]
    var status: String
    var resolvedInChapter: Int

    init(
        tag: String,
        introducedInChapter: Int = 0,
        detail: String = "",
        relatedEventIds: [UUID] = [],
        status: String = "open",
        resolvedInChapter: Int = 0
    ) {
        self.tag = tag
        self.introducedInChapter = introducedInChapter
        self.detail = detail
        self.relatedEventIds = relatedEventIds
        self.status = status
        self.resolvedInChapter = resolvedInChapter
    }
}

struct StoryStyleProfileDraft {
    var authorPreferences: String
    var narrativeVoice: String
    var sentenceLengthMean: Double
    var dialogueRatio: Double
    var imageryDensity: Double
    var samplePassages: [String]
    var antiPatterns: [String]

    init(
        authorPreferences: String = "",
        narrativeVoice: String = "",
        sentenceLengthMean: Double = 0,
        dialogueRatio: Double = 0,
        imageryDensity: Double = 0,
        samplePassages: [String] = [],
        antiPatterns: [String] = []
    ) {
        self.authorPreferences = authorPreferences
        self.narrativeVoice = narrativeVoice
        self.sentenceLengthMean = sentenceLengthMean
        self.dialogueRatio = dialogueRatio
        self.imageryDensity = imageryDensity
        self.samplePassages = samplePassages
        self.antiPatterns = antiPatterns
    }
}

struct StoryContinuityIssueUpdateDraft {
    var resolutionStatus: String
    var resolutionNote: String

    init(resolutionStatus: String, resolutionNote: String = "") {
        self.resolutionStatus = resolutionStatus
        self.resolutionNote = resolutionNote
    }
}

enum StoryMemoryServiceError: Error, LocalizedError {
    case projectNotFound(UUID)
    case chapterNotFound(projectId: UUID, chapterNumber: Int)
    case continuityIssueNotFound(UUID)
    case invalidParameter(String)

    var errorDescription: String? {
        switch self {
        case let .projectNotFound(id):
            return "story project not found: \(id.uuidString)"
        case let .chapterNotFound(_, chapterNumber):
            return "chapter not found: \(chapterNumber)"
        case let .continuityIssueNotFound(id):
            return "continuity issue not found: \(id.uuidString)"
        case let .invalidParameter(message):
            return message
        }
    }
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

    @discardableResult
    func upsertChapter(projectId: UUID, payload: StoryChapterDraft) throws -> StoryChapterRecord {
        guard payload.chapterNumber > 0 else {
            throw StoryMemoryServiceError.invalidParameter("chapter_number must be a positive integer")
        }

        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw StoryMemoryServiceError.invalidParameter("title must not be empty")
        }

        let project = try fetchProject(id: projectId)
        let chapter: StoryChapterRecord
        if let existing = project.chapters.first(where: { $0.number == payload.chapterNumber }) {
            chapter = existing
        } else {
            let created = StoryChapterRecord(number: payload.chapterNumber, title: title)
            created.project = project
            project.chapters.append(created)
            chapter = created
        }

        chapter.title = title
        chapter.outline = payload.outline
        chapter.summary = payload.summary
        chapter.toneDirective = payload.toneDirective
        chapter.isLocked = payload.isLocked
        project.updatedAt = Date()

        try modelContext.save()
        return chapter
    }

    @discardableResult
    func upsertScene(projectId: UUID, payload: StorySceneDraft) throws -> StorySceneRecord {
        guard payload.chapterNumber > 0 else {
            throw StoryMemoryServiceError.invalidParameter("chapter_number must be a positive integer")
        }
        guard payload.sceneIndex > 0 else {
            throw StoryMemoryServiceError.invalidParameter("scene_index must be a positive integer")
        }

        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw StoryMemoryServiceError.invalidParameter("title must not be empty")
        }

        let project = try fetchProject(id: projectId)
        guard let chapter = project.chapters.first(where: { $0.number == payload.chapterNumber }) else {
            throw StoryMemoryServiceError.chapterNotFound(projectId: projectId, chapterNumber: payload.chapterNumber)
        }

        let scene: StorySceneRecord
        if let existing = chapter.scenes.first(where: { $0.sceneIndex == payload.sceneIndex }) {
            scene = existing
        } else {
            let created = StorySceneRecord(title: title, sceneIndex: payload.sceneIndex)
            created.chapter = chapter
            chapter.scenes.append(created)
            scene = created
        }

        scene.title = title
        scene.content = payload.content
        scene.povCharacterName = payload.povCharacterName
        scene.locationName = payload.locationName
        scene.characterNamesJSON = StoryMemoryJSONCodec.encode(payload.characterNames)
        scene.summary = payload.summary
        scene.previousSceneId = payload.previousSceneId?.uuidString ?? ""
        scene.timelineEventId = payload.timelineEventId?.uuidString ?? ""
        project.updatedAt = Date()

        try modelContext.save()
        return scene
    }

    @discardableResult
    func upsertWorldRule(projectId: UUID, payload: StoryWorldRuleDraft) throws -> StoryWorldRule {
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw StoryMemoryServiceError.invalidParameter("title must not be empty")
        }

        let project = try fetchProject(id: projectId)
        let rule: StoryWorldRule
        if let existing = project.worldRules.first(where: { $0.title == title }) {
            rule = existing
        } else {
            let created = StoryWorldRule(title: title)
            created.project = project
            project.worldRules.append(created)
            rule = created
        }

        rule.title = title
        rule.category = payload.category
        rule.detail = payload.detail
        rule.scope = payload.scope
        rule.exceptionsJSON = StoryMemoryJSONCodec.encode(payload.exceptions)
        rule.establishedInChapter = payload.establishedInChapter
        rule.relatedEntitiesJSON = StoryMemoryJSONCodec.encode(payload.relatedEntities)
        rule.mutablePolicy = payload.mutablePolicy
        project.updatedAt = Date()

        try modelContext.save()
        return rule
    }

    @discardableResult
    func upsertLocation(projectId: UUID, payload: StoryLocationDraft) throws -> StoryLocationProfile {
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw StoryMemoryServiceError.invalidParameter("name must not be empty")
        }

        let project = try fetchProject(id: projectId)
        let location: StoryLocationProfile
        if let existing = project.locations.first(where: { $0.name == name }) {
            location = existing
        } else {
            let created = StoryLocationProfile(name: name)
            created.project = project
            project.locations.append(created)
            location = created
        }

        location.name = name
        location.summary = payload.summary
        location.traitsJSON = StoryMemoryJSONCodec.encode(payload.traits)
        location.relatedRulesJSON = StoryMemoryJSONCodec.encode(payload.relatedRules)
        location.occupantNamesJSON = StoryMemoryJSONCodec.encode(payload.occupantNames)
        project.updatedAt = Date()

        try modelContext.save()
        return location
    }

    @discardableResult
    func upsertForeshadow(projectId: UUID, payload: StoryForeshadowDraft) throws -> StoryForeshadowItem {
        let tag = payload.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else {
            throw StoryMemoryServiceError.invalidParameter("tag must not be empty")
        }

        let project = try fetchProject(id: projectId)
        let foreshadow: StoryForeshadowItem
        if let existing = project.foreshadowItems.first(where: { $0.tag == tag }) {
            foreshadow = existing
        } else {
            let created = StoryForeshadowItem(tag: tag)
            created.project = project
            project.foreshadowItems.append(created)
            foreshadow = created
        }

        foreshadow.tag = tag
        foreshadow.introducedInChapter = payload.introducedInChapter
        foreshadow.detail = payload.detail
        foreshadow.relatedEventIdsJSON = StoryMemoryJSONCodec.encode(payload.relatedEventIds)
        foreshadow.status = payload.resolvedInChapter > 0 && payload.status.isEmpty ? "resolved" : payload.status
        foreshadow.resolvedInChapter = payload.resolvedInChapter
        if foreshadow.resolvedInChapter > 0 && foreshadow.status == "open" {
            foreshadow.status = "resolved"
        }
        project.updatedAt = Date()

        try modelContext.save()
        return foreshadow
    }

    @discardableResult
    func upsertStyleProfile(projectId: UUID, payload: StoryStyleProfileDraft) throws -> StoryStyleProfile {
        let project = try fetchProject(id: projectId)
        let style: StoryStyleProfile
        if let existing = project.styleProfile {
            style = existing
        } else {
            let created = StoryStyleProfile()
            created.project = project
            project.styleProfile = created
            style = created
        }

        style.authorPreferences = payload.authorPreferences
        style.narrativeVoice = payload.narrativeVoice
        style.sentenceLengthMean = payload.sentenceLengthMean
        style.dialogueRatio = payload.dialogueRatio
        style.imageryDensity = payload.imageryDensity
        style.samplePassagesJSON = StoryMemoryJSONCodec.encode(payload.samplePassages)
        style.antiPatternsJSON = StoryMemoryJSONCodec.encode(payload.antiPatterns)
        project.updatedAt = Date()

        try modelContext.save()
        return style
    }

    @discardableResult
    func updateContinuityIssue(projectId: UUID, issueId: UUID, payload: StoryContinuityIssueUpdateDraft) throws -> StoryContinuityIssue {
        let status = payload.resolutionStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty else {
            throw StoryMemoryServiceError.invalidParameter("resolution_status must not be empty")
        }

        let project = try fetchProject(id: projectId)
        guard let issue = project.continuityIssues.first(where: { $0.id == issueId }) else {
            throw StoryMemoryServiceError.continuityIssueNotFound(issueId)
        }

        issue.resolutionStatus = status
        let note = payload.resolutionNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            if issue.detail.isEmpty {
                issue.detail = "resolution_note: \(note)"
            } else if !issue.detail.contains("resolution_note:") {
                issue.detail += "\nresolution_note: \(note)"
            }
        }
        project.updatedAt = Date()

        try modelContext.save()
        return issue
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