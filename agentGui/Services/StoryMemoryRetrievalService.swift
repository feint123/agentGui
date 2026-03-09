import Foundation
import SwiftData

struct StoryCharacterCard {
    var name: String
    var summary: String
    var traits: [String]
    var goals: [String]
    var speechStyle: String
    var relationships: [String: String]
    var arcStage: String
    var lastSeenChapter: Int
    var lastKnownLocation: String
}

struct StoryForeshadowSlice {
    var tag: String
    var detail: String
    var introducedInChapter: Int
    var status: String
    var resolvedInChapter: Int
}

struct StoryTimelineEventSlice {
    var id: UUID
    var chapterNumber: Int
    var sceneIndex: Int
    var title: String
    var summary: String
    var participants: [String]
    var locationName: String
    var timeMarker: String
    var eventType: String
    var foreshadowTags: [String]
}

@MainActor
final class StoryMemoryRetrievalService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func activeCharacterCards(projectId: UUID, names: [String]) throws -> [StoryCharacterCard] {
        let project = try fetchProject(id: projectId)
        let requested = Set(names)

        return project.characters
            .filter { requested.contains($0.name) }
            .map {
                StoryCharacterCard(
                    name: $0.name,
                    summary: $0.summary,
                    traits: StoryMemoryJSONCodec.decode([String].self, from: $0.traitsJSON, fallback: []),
                    goals: StoryMemoryJSONCodec.decode([String].self, from: $0.goalsJSON, fallback: []),
                    speechStyle: $0.speechStyle,
                    relationships: StoryMemoryJSONCodec.decode([String: String].self, from: $0.relationshipMapJSON, fallback: [:]),
                    arcStage: $0.arcStage,
                    lastSeenChapter: $0.lastSeenChapter,
                    lastKnownLocation: $0.lastKnownLocation
                )
            }
    }

    func unresolvedForeshadows(projectId: UUID, upToChapter: Int) throws -> [StoryForeshadowSlice] {
        let project = try fetchProject(id: projectId)

        return project.foreshadowItems
            .filter {
                $0.introducedInChapter <= upToChapter &&
                $0.status != "resolved" &&
                ($0.resolvedInChapter == 0 || $0.resolvedInChapter > upToChapter)
            }
            .sorted { lhs, rhs in
                if lhs.introducedInChapter != rhs.introducedInChapter {
                    return lhs.introducedInChapter < rhs.introducedInChapter
                }
                return lhs.tag < rhs.tag
            }
            .map {
                StoryForeshadowSlice(
                    tag: $0.tag,
                    detail: $0.detail,
                    introducedInChapter: $0.introducedInChapter,
                    status: $0.status,
                    resolvedInChapter: $0.resolvedInChapter
                )
            }
    }

    func recentEvents(projectId: UUID, involving names: [String], limit: Int) throws -> [StoryTimelineEventSlice] {
        let project = try fetchProject(id: projectId)
        let requested = Set(names)

        return project.timelineEvents
            .filter {
                let participants = StoryMemoryJSONCodec.decode([String].self, from: $0.participantNamesJSON, fallback: [])
                return !requested.isDisjoint(with: participants)
            }
            .sorted { lhs, rhs in
                if lhs.chapterNumber != rhs.chapterNumber {
                    return lhs.chapterNumber > rhs.chapterNumber
                }
                return lhs.sceneIndex > rhs.sceneIndex
            }
            .prefix(limit)
            .map {
                StoryTimelineEventSlice(
                    id: $0.id,
                    chapterNumber: $0.chapterNumber,
                    sceneIndex: $0.sceneIndex,
                    title: $0.title,
                    summary: $0.summary,
                    participants: StoryMemoryJSONCodec.decode([String].self, from: $0.participantNamesJSON, fallback: []),
                    locationName: $0.locationName,
                    timeMarker: $0.timeMarker,
                    eventType: $0.eventType,
                    foreshadowTags: StoryMemoryJSONCodec.decode([String].self, from: $0.foreshadowTagsJSON, fallback: [])
                )
            }
    }

    func chapters(projectId: UUID) throws -> [StoryChapterRecord] {
        let project = try fetchProject(id: projectId)

        return project.chapters.sorted { lhs, rhs in
            if lhs.number != rhs.number {
                return lhs.number < rhs.number
            }
            return lhs.title < rhs.title
        }
    }

    func scenes(projectId: UUID, chapterNumber: Int? = nil) throws -> [StorySceneRecord] {
        let project = try fetchProject(id: projectId)

        let chapterList = project.chapters.filter { chapter in
            guard let chapterNumber else { return true }
            return chapter.number == chapterNumber
        }

        return chapterList
            .sorted { lhs, rhs in
                if lhs.number != rhs.number {
                    return lhs.number < rhs.number
                }
                return lhs.title < rhs.title
            }
            .flatMap { chapter in
                chapter.scenes.sorted { lhs, rhs in
                    if lhs.sceneIndex != rhs.sceneIndex {
                        return lhs.sceneIndex < rhs.sceneIndex
                    }
                    return lhs.title < rhs.title
                }
            }
    }

    func worldRules(projectId: UUID) throws -> [StoryWorldRule] {
        let project = try fetchProject(id: projectId)

        return project.worldRules.sorted { lhs, rhs in
            if lhs.title != rhs.title {
                return lhs.title < rhs.title
            }
            return lhs.category < rhs.category
        }
    }

    func locations(projectId: UUID) throws -> [StoryLocationProfile] {
        let project = try fetchProject(id: projectId)

        return project.locations.sorted { lhs, rhs in
            lhs.name < rhs.name
        }
    }

    func styleProfile(projectId: UUID) throws -> StoryStyleProfile? {
        let project = try fetchProject(id: projectId)
        return project.styleProfile
    }

    func continuityIssues(projectId: UUID, resolutionStatus: String? = nil) throws -> [StoryContinuityIssue] {
        let project = try fetchProject(id: projectId)

        return project.continuityIssues
            .filter { issue in
                guard let resolutionStatus else { return true }
                return issue.resolutionStatus == resolutionStatus
            }
            .sorted { lhs, rhs in
                let lhsRank = lhs.resolutionStatus == "resolved" ? 1 : 0
                let rhsRank = rhs.resolutionStatus == "resolved" ? 1 : 0
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                if lhs.chapterNumber != rhs.chapterNumber {
                    return lhs.chapterNumber < rhs.chapterNumber
                }
                if lhs.sceneIndex != rhs.sceneIndex {
                    return lhs.sceneIndex < rhs.sceneIndex
                }
                return lhs.issueKind < rhs.issueKind
            }
    }

    private func fetchProject(id: UUID) throws -> WritingProject {
        let descriptor = FetchDescriptor<WritingProject>(predicate: #Predicate { $0.id == id })
        guard let project = try modelContext.fetch(descriptor).first else {
            throw StoryMemoryServiceError.projectNotFound(id)
        }
        return project
    }
}