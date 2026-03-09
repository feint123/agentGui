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

struct StoryProjectOverviewSection: Equatable {
    let title: String
    let synopsis: String
    let styleSummary: String
    let createdAt: Date
    let updatedAt: Date
    let isArchived: Bool
}

struct StoryProjectStatsSection: Equatable {
    let characterCount: Int
    let chapterCount: Int
    let sceneCount: Int
    let locationCount: Int
    let worldRuleCount: Int
    let timelineEventCount: Int
    let unresolvedForeshadowCount: Int
    let openContinuityIssueCount: Int
}

struct StoryProjectSceneCard: Identifiable, Equatable {
    var id: String { "scene-\(sceneIndex)-\(title)" }
    let sceneIndex: Int
    let title: String
    let summary: String
    let povCharacterName: String
    let locationName: String
    let participantNames: [String]
    let hasPreviousSceneReference: Bool
    let hasTimelineEventReference: Bool
    let contentStatus: String
}

struct StoryProjectChapterSection: Identifiable, Equatable {
    var id: Int { number }
    let number: Int
    let title: String
    let outline: String
    let summary: String
    let toneDirective: String
    let isLocked: Bool
    let sceneCount: Int
    let scenes: [StoryProjectSceneCard]
}

struct StoryProjectCharacterCard: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let summary: String
    let traits: [String]
    let goals: [String]
    let speechStyle: String
    let arcStage: String
    let lastSeenChapter: Int
    let lastKnownLocation: String
    let relationshipSummary: [String]
}

struct StoryProjectLocationCard: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let summary: String
    let traits: [String]
    let relatedRules: [String]
    let occupants: [String]
}

struct StoryProjectWorldRuleCard: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let detail: String
    let scope: String
    let exceptions: [String]
    let establishedInChapter: Int
    let relatedEntities: [String]
    let mutablePolicy: String
}

struct StoryProjectWorldRuleSection: Identifiable, Equatable {
    var id: String { category }
    let category: String
    let rules: [StoryProjectWorldRuleCard]
}

struct StoryProjectTimelineCard: Identifiable, Equatable {
    var id: String { "timeline-\(chapterNumber)-\(sceneIndex)-\(title)" }
    let chapterNumber: Int
    let sceneIndex: Int
    let title: String
    let summary: String
    let participantNames: [String]
    let locationName: String
    let timeMarker: String
    let eventType: String
    let foreshadowTags: [String]
    let isResolved: Bool
    let isSuperseded: Bool
}

struct StoryProjectForeshadowCard: Identifiable, Equatable {
    var id: String { tag }
    let tag: String
    let detail: String
    let introducedInChapter: Int
    let resolvedInChapter: Int
    let relatedEventCount: Int
}

struct StoryProjectForeshadowGroup: Identifiable, Equatable {
    var id: String { status }
    let status: String
    let items: [StoryProjectForeshadowCard]
}

struct StoryProjectContinuityCard: Identifiable, Equatable {
    var id: String { "continuity-\(issueKind)-\(chapterNumber)-\(sceneIndex)" }
    let issueKind: String
    let severity: String
    let chapterNumber: Int
    let sceneIndex: Int
    let detail: String
}

struct StoryProjectContinuityGroup: Identifiable, Equatable {
    var id: String { status }
    let status: String
    let items: [StoryProjectContinuityCard]
}

struct StoryProjectStyleCard: Equatable {
    let authorPreferences: String
    let narrativeVoice: String
    let sentenceLengthMean: Double
    let dialogueRatio: Double
    let imageryDensity: Double
    let samplePassages: [String]
    let antiPatterns: [String]
}

struct StoryProjectInspectorSnapshot: Equatable {
    let overview: StoryProjectOverviewSection
    let stats: StoryProjectStatsSection
    let chapterSections: [StoryProjectChapterSection]
    let characterCards: [StoryProjectCharacterCard]
    let locationCards: [StoryProjectLocationCard]
    let worldRuleSections: [StoryProjectWorldRuleSection]
    let timelineEvents: [StoryProjectTimelineCard]
    let foreshadowGroups: [StoryProjectForeshadowGroup]
    let continuityGroups: [StoryProjectContinuityGroup]
    let styleCard: StoryProjectStyleCard?

    var title: String { overview.title }
    var synopsis: String { overview.synopsis }
    var styleSummary: String { overview.styleSummary }
    var characterNames: [String] { characterCards.map(\.name) }
    var chapterTitles: [String] { chapterSections.map { "第 \($0.number) 章 · \($0.title)" } }
    var timelineTitles: [String] { timelineEvents.map { "Ch\($0.chapterNumber) Sc\($0.sceneIndex) · \($0.title)" } }
    var unresolvedForeshadowTags: [String] {
        foreshadowGroups
            .filter { $0.status != "resolved" }
            .flatMap { $0.items.map(\.tag) }
    }
    var openContinuityIssues: [String] {
        continuityGroups
            .filter { $0.status != "resolved" }
            .flatMap { $0.items.map { "\($0.issueKind) · \($0.detail)" } }
    }
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
        let chapterSections = project.chapters
            .sorted { $0.number < $1.number }
            .map { chapter in
                let scenes = chapter.scenes
                    .sorted { $0.sceneIndex < $1.sceneIndex }
                    .map { scene in
                        StoryProjectSceneCard(
                            sceneIndex: scene.sceneIndex,
                            title: displayText(scene.title),
                            summary: displayText(scene.summary),
                            povCharacterName: displayText(scene.povCharacterName),
                            locationName: displayText(scene.locationName),
                            participantNames: decodedStringArray(from: scene.characterNamesJSON),
                            hasPreviousSceneReference: !scene.previousSceneId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            hasTimelineEventReference: !scene.timelineEventId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            contentStatus: scene.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无正文" : "有正文"
                        )
                    }

                return StoryProjectChapterSection(
                    number: chapter.number,
                    title: displayText(chapter.title),
                    outline: displayText(chapter.outline),
                    summary: displayText(chapter.summary),
                    toneDirective: displayText(chapter.toneDirective),
                    isLocked: chapter.isLocked,
                    sceneCount: scenes.count,
                    scenes: scenes
                )
            }

        let characterCards = project.characters
            .sorted { $0.name < $1.name }
            .map { character in
                StoryProjectCharacterCard(
                    name: displayText(character.name),
                    summary: displayText(character.summary, fallback: "基础档案未完善"),
                    traits: decodedStringArray(from: character.traitsJSON),
                    goals: decodedStringArray(from: character.goalsJSON),
                    speechStyle: displayText(character.speechStyle),
                    arcStage: displayText(character.arcStage),
                    lastSeenChapter: character.lastSeenChapter,
                    lastKnownLocation: displayText(character.lastKnownLocation),
                    relationshipSummary: decodedRelationshipSummary(from: character.relationshipMapJSON)
                )
            }

        let locationCards = project.locations
            .sorted { $0.name < $1.name }
            .map { location in
                StoryProjectLocationCard(
                    name: displayText(location.name),
                    summary: displayText(location.summary),
                    traits: decodedStringArray(from: location.traitsJSON),
                    relatedRules: decodedStringArray(from: location.relatedRulesJSON),
                    occupants: decodedStringArray(from: location.occupantNamesJSON)
                )
            }

        let worldRuleSections = Dictionary(grouping: project.worldRules) { rule in
            let category = rule.category.trimmingCharacters(in: .whitespacesAndNewlines)
            return category.isEmpty ? "未分类" : category
        }
        .map { category, rules in
            StoryProjectWorldRuleSection(
                category: category,
                rules: rules
                    .sorted { $0.title < $1.title }
                    .map { rule in
                        StoryProjectWorldRuleCard(
                            title: displayText(rule.title),
                            detail: displayText(rule.detail),
                            scope: displayText(rule.scope),
                            exceptions: decodedStringArray(from: rule.exceptionsJSON),
                            establishedInChapter: rule.establishedInChapter,
                            relatedEntities: decodedStringArray(from: rule.relatedEntitiesJSON),
                            mutablePolicy: displayMutablePolicy(rule.mutablePolicy)
                        )
                    }
            )
        }
        .sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return lhs.category < rhs.category
            }
            return lhs.rules.first?.title ?? "" < rhs.rules.first?.title ?? ""
        }

        let timelineEvents = project.timelineEvents
            .sorted { lhs, rhs in
                if lhs.chapterNumber != rhs.chapterNumber {
                    return lhs.chapterNumber < rhs.chapterNumber
                }
                return lhs.sceneIndex < rhs.sceneIndex
            }
            .map { event in
                StoryProjectTimelineCard(
                    chapterNumber: event.chapterNumber,
                    sceneIndex: event.sceneIndex,
                    title: displayText(event.title),
                    summary: displayText(event.summary),
                    participantNames: decodedStringArray(from: event.participantNamesJSON),
                    locationName: displayText(event.locationName),
                    timeMarker: displayText(event.timeMarker),
                    eventType: displayText(event.eventType),
                    foreshadowTags: decodedStringArray(from: event.foreshadowTagsJSON),
                    isResolved: event.isResolved,
                    isSuperseded: !event.supersededByEventId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

        let foreshadowGroups = Dictionary(grouping: project.foreshadowItems) { item in
            let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines)
            return status.isEmpty ? "open" : status
        }
        .map { status, items in
            StoryProjectForeshadowGroup(
                status: status,
                items: items
                    .sorted { lhs, rhs in
                        if lhs.introducedInChapter != rhs.introducedInChapter {
                            return lhs.introducedInChapter < rhs.introducedInChapter
                        }
                        return lhs.tag < rhs.tag
                    }
                    .map { item in
                        StoryProjectForeshadowCard(
                            tag: displayText(item.tag),
                            detail: displayText(item.detail),
                            introducedInChapter: item.introducedInChapter,
                            resolvedInChapter: item.resolvedInChapter,
                            relatedEventCount: decodedStringArray(from: item.relatedEventIdsJSON).count
                        )
                    }
            )
        }
        .sorted { lhs, rhs in
            let lhsRank = foreshadowStatusRank(lhs.status)
            let rhsRank = foreshadowStatusRank(rhs.status)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.status < rhs.status
        }

        let continuityGroups = Dictionary(grouping: project.continuityIssues) { issue in
            let status = issue.resolutionStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            return status.isEmpty ? "open" : status
        }
        .map { status, issues in
            StoryProjectContinuityGroup(
                status: status,
                items: issues
                    .sorted { lhs, rhs in
                        let lhsSeverity = continuitySeverityRank(lhs.severity)
                        let rhsSeverity = continuitySeverityRank(rhs.severity)
                        if lhsSeverity != rhsSeverity {
                            return lhsSeverity < rhsSeverity
                        }
                        if lhs.chapterNumber != rhs.chapterNumber {
                            return lhs.chapterNumber > rhs.chapterNumber
                        }
                        return lhs.sceneIndex > rhs.sceneIndex
                    }
                    .map { issue in
                        StoryProjectContinuityCard(
                            issueKind: displayText(issue.issueKind),
                            severity: normalizedStatus(issue.severity, fallback: "warning"),
                            chapterNumber: issue.chapterNumber,
                            sceneIndex: issue.sceneIndex,
                            detail: displayText(issue.detail)
                        )
                    }
            )
        }
        .sorted { lhs, rhs in
            let lhsRank = continuityStatusRank(lhs.status)
            let rhsRank = continuityStatusRank(rhs.status)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.status < rhs.status
        }

        let styleSummary = [project.styleProfile?.narrativeVoice, project.styleProfile?.authorPreferences]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " · ")

        let styleCard = project.styleProfile.map { profile in
            StoryProjectStyleCard(
                authorPreferences: displayText(profile.authorPreferences),
                narrativeVoice: displayText(profile.narrativeVoice),
                sentenceLengthMean: profile.sentenceLengthMean,
                dialogueRatio: profile.dialogueRatio,
                imageryDensity: profile.imageryDensity,
                samplePassages: decodedStringArray(from: profile.samplePassagesJSON),
                antiPatterns: decodedStringArray(from: profile.antiPatternsJSON)
            )
        }

        return StoryProjectInspectorSnapshot(
            overview: StoryProjectOverviewSection(
                title: project.title,
                synopsis: project.synopsis,
                styleSummary: styleSummary,
                createdAt: project.createdAt,
                updatedAt: project.updatedAt,
                isArchived: project.isArchived
            ),
            stats: StoryProjectStatsSection(
                characterCount: project.characters.count,
                chapterCount: project.chapters.count,
                sceneCount: chapterSections.reduce(0) { $0 + $1.sceneCount },
                locationCount: project.locations.count,
                worldRuleCount: project.worldRules.count,
                timelineEventCount: project.timelineEvents.count,
                unresolvedForeshadowCount: project.foreshadowItems.filter { normalizedStatus($0.status, fallback: "open") != "resolved" }.count,
                openContinuityIssueCount: project.continuityIssues.filter { normalizedStatus($0.resolutionStatus, fallback: "open") == "open" }.count
            ),
            chapterSections: chapterSections,
            characterCards: characterCards,
            locationCards: locationCards,
            worldRuleSections: worldRuleSections,
            timelineEvents: timelineEvents,
            foreshadowGroups: foreshadowGroups,
            continuityGroups: continuityGroups,
            styleCard: styleCard
        )
    }

    private static func decodedStringArray(from json: String) -> [String] {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return [] }
        guard let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func decodedRelationshipSummary(from json: String) -> [String] {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return [] }
        guard let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [] }
        return map
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
    }

    private static func displayText(_ value: String, fallback: String = "暂无") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func normalizedStatus(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func displayMutablePolicy(_ value: String) -> String {
        switch normalizedStatus(value, fallback: "immutable") {
        case "immutable":
            return "不可变"
        case "mutable":
            return "可变"
        case "conditional":
            return "条件可变"
        default:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func foreshadowStatusRank(_ value: String) -> Int {
        switch normalizedStatus(value, fallback: "open") {
        case "open":
            return 0
        case "planned":
            return 1
        case "payoff":
            return 2
        case "resolved":
            return 3
        default:
            return 4
        }
    }

    private static func continuityStatusRank(_ value: String) -> Int {
        switch normalizedStatus(value, fallback: "open") {
        case "open":
            return 0
        case "accepted":
            return 1
        case "wont_fix":
            return 2
        case "resolved":
            return 3
        default:
            return 4
        }
    }

    private static func continuitySeverityRank(_ value: String) -> Int {
        switch normalizedStatus(value, fallback: "warning") {
        case "critical", "error", "high":
            return 0
        case "warning", "medium":
            return 1
        case "info", "low":
            return 2
        default:
            return 3
        }
    }
}