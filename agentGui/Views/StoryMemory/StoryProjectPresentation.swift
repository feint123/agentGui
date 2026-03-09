import Foundation

struct StoryProjectSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let synopsis: String
    let updatedAt: Date
    let characterCount: Int
    let unresolvedForeshadowCount: Int
    let openContinuityIssueCount: Int
    let isActive: Bool
}

struct StoryProjectInspectorSnapshot: Equatable {
    let title: String
    let synopsis: String
    let styleSummary: String
    let characterNames: [String]
    let chapterTitles: [String]
    let timelineTitles: [String]
    let unresolvedForeshadowTags: [String]
    let openContinuityIssues: [String]
}

enum StoryProjectPresentation {
    static func summaries(projects: [WritingProject], activeProjectId: UUID?) -> [StoryProjectSummary] {
        projects
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
            .map { project in
                StoryProjectSummary(
                    id: project.id,
                    title: project.title,
                    synopsis: project.synopsis,
                    updatedAt: project.updatedAt,
                    characterCount: project.characters.count,
                    unresolvedForeshadowCount: project.foreshadowItems.filter { $0.status != "resolved" }.count,
                    openContinuityIssueCount: project.continuityIssues.filter { $0.resolutionStatus != "resolved" }.count,
                    isActive: project.id == activeProjectId
                )
            }
    }

    static func inspectorSnapshot(for project: WritingProject) -> StoryProjectInspectorSnapshot {
        let characterNames = project.characters
            .map(\ .name)
            .sorted()

        let chapterTitles = project.chapters
            .sorted { $0.number < $1.number }
            .map { "第 \($0.number) 章 · \($0.title)" }

        let timelineTitles = project.timelineEvents
            .sorted { lhs, rhs in
                if lhs.chapterNumber != rhs.chapterNumber {
                    return lhs.chapterNumber < rhs.chapterNumber
                }
                return lhs.sceneIndex < rhs.sceneIndex
            }
            .map { "Ch\($0.chapterNumber) Sc\($0.sceneIndex) · \($0.title)" }

        let unresolvedForeshadowTags = project.foreshadowItems
            .filter { $0.status != "resolved" }
            .sorted { lhs, rhs in
                if lhs.introducedInChapter != rhs.introducedInChapter {
                    return lhs.introducedInChapter < rhs.introducedInChapter
                }
                return lhs.tag < rhs.tag
            }
            .map(\ .tag)

        let openContinuityIssues = project.continuityIssues
            .filter { $0.resolutionStatus != "resolved" }
            .sorted { lhs, rhs in
                if lhs.chapterNumber != rhs.chapterNumber {
                    return lhs.chapterNumber > rhs.chapterNumber
                }
                return lhs.sceneIndex > rhs.sceneIndex
            }
            .map { "\($0.issueKind) · \($0.detail)" }

        let styleSummary = [project.styleProfile?.narrativeVoice, project.styleProfile?.authorPreferences]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")

        return StoryProjectInspectorSnapshot(
            title: project.title,
            synopsis: project.synopsis,
            styleSummary: styleSummary,
            characterNames: characterNames,
            chapterTitles: chapterTitles,
            timelineTitles: timelineTitles,
            unresolvedForeshadowTags: unresolvedForeshadowTags,
            openContinuityIssues: openContinuityIssues
        )
    }
}