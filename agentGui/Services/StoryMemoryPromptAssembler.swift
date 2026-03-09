import Foundation
import SwiftData

enum StoryPromptSection: String {
    case goal = "当前写作目标"
    case previousScene = "上一场景衔接"
    case activeCharacters = "活跃角色"
    case worldRules = "适用规则"
    case recentEvents = "相关事件"
    case unresolvedForeshadow = "未解决伏笔"
    case styleDirective = "风格指令"
}

@MainActor
final class StoryMemoryPromptAssembler {
    private let modelContext: ModelContext
    private let retrievalService: StoryMemoryRetrievalService

    init(modelContext: ModelContext, retrievalService: StoryMemoryRetrievalService) {
        self.modelContext = modelContext
        self.retrievalService = retrievalService
    }

    func buildWritingSlice(
        projectId: UUID,
        chapterNumber: Int,
        currentSceneGoal: String,
        activeCharacters: [String],
        promptBudget: Int
    ) throws -> String {
        let project = try fetchProject(id: projectId)
        let itemLimit = max(promptBudget, 1)
        let effectiveCharacters = resolveActiveCharacters(project: project, requested: activeCharacters, limit: itemLimit)
        let characterCards = try retrievalService.activeCharacterCards(projectId: projectId, names: effectiveCharacters)
        let recentEvents = Array(
            try retrievalService.recentEvents(projectId: projectId, involving: effectiveCharacters, limit: itemLimit)
                .prefix(itemLimit)
        )
        let foreshadows = Array(
            try retrievalService.unresolvedForeshadows(projectId: projectId, upToChapter: chapterNumber)
                .prefix(itemLimit)
        )
        let worldRules = Array(
            project.worldRules
                .filter { $0.establishedInChapter == 0 || $0.establishedInChapter <= chapterNumber }
                .sorted { lhs, rhs in
                    if lhs.establishedInChapter != rhs.establishedInChapter {
                        return lhs.establishedInChapter < rhs.establishedInChapter
                    }
                    return lhs.title < rhs.title
                }
                .prefix(itemLimit)
        )

        let sections = [
            renderSection(.goal, body: "- \(currentSceneGoal)"),
            renderSection(.previousScene, body: renderPreviousScene(project: project, before: chapterNumber)),
            renderSection(.activeCharacters, body: renderCharacterCards(characterCards)),
            renderSection(.worldRules, body: renderWorldRules(worldRules)),
            renderSection(.recentEvents, body: renderRecentEvents(recentEvents)),
            renderSection(.unresolvedForeshadow, body: renderForeshadows(foreshadows)),
            renderSection(.styleDirective, body: renderStyleDirective(project.styleProfile))
        ]

        return sections.joined(separator: "\n\n")
    }

    func buildWritingSlice(settings: AppSettings, session: Session, currentRequest: String) throws -> String? {
        guard settings.enableStoryMemory,
              let projectId = UUID(uuidString: session.activeWritingProjectId) else {
            return nil
        }

        let project = try fetchProject(id: projectId)
        let chapterNumber = inferCurrentChapter(project: project)
        let activeCharacters = inferActiveCharacters(from: currentRequest, project: project)

        return try buildWritingSlice(
            projectId: projectId,
            chapterNumber: chapterNumber,
            currentSceneGoal: currentRequest.isEmpty ? "继续当前写作任务" : currentRequest,
            activeCharacters: activeCharacters,
            promptBudget: settings.storyMemoryPromptBudget
        )
    }

    private func fetchProject(id: UUID) throws -> WritingProject {
        let descriptor = FetchDescriptor<WritingProject>(predicate: #Predicate { $0.id == id })
        guard let project = try modelContext.fetch(descriptor).first else {
            throw StoryMemoryServiceError.projectNotFound(id)
        }
        return project
    }

    private func inferCurrentChapter(project: WritingProject) -> Int {
        let chapterMax = project.chapters.map(\.number).max() ?? 0
        let eventMax = project.timelineEvents.map(\.chapterNumber).max() ?? 0
        return max(chapterMax, eventMax)
    }

    private func inferActiveCharacters(from request: String, project: WritingProject) -> [String] {
        let matches = project.characters
            .map(\.name)
            .filter { !request.isEmpty && request.contains($0) }
        if !matches.isEmpty {
            return matches
        }

        return project.characters
            .sorted {
                if $0.lastSeenChapter != $1.lastSeenChapter {
                    return $0.lastSeenChapter > $1.lastSeenChapter
                }
                return $0.name < $1.name
            }
            .prefix(2)
            .map(\.name)
    }

    private func resolveActiveCharacters(project: WritingProject, requested: [String], limit: Int) -> [String] {
        let names = requested.isEmpty ? inferActiveCharacters(from: "", project: project) : requested
        return Array(names.prefix(limit))
    }

    private func renderSection(_ section: StoryPromptSection, body: String) -> String {
        "## \(section.rawValue)\n\(body)"
    }

    private func renderPreviousScene(project: WritingProject, before chapterNumber: Int) -> String {
        let orderedScenes = project.chapters
            .sorted { $0.number < $1.number }
            .flatMap { chapter in
                chapter.scenes
                    .sorted { $0.sceneIndex < $1.sceneIndex }
                    .map { (chapter.number, $0) }
            }
            .filter { number, _ in number < chapterNumber }

        guard let (number, scene) = orderedScenes.last else {
            return "- 暂无上一场景记录"
        }

        let summary = scene.summary.isEmpty ? scene.title : scene.summary
        return "- 第\(number)章第\(scene.sceneIndex)场：\(summary)"
    }

    private func renderCharacterCards(_ cards: [StoryCharacterCard]) -> String {
        guard !cards.isEmpty else { return "- 暂无活跃角色数据" }
        return cards.map {
            var line = "- \($0.name)：\($0.summary)"
            if !$0.arcStage.isEmpty {
                line += "；弧线阶段：\($0.arcStage)"
            }
            if !$0.lastKnownLocation.isEmpty {
                line += "；最近位置：\($0.lastKnownLocation)"
            }
            if !$0.goals.isEmpty {
                line += "；目标：\($0.goals.joined(separator: "、"))"
            }
            return line
        }.joined(separator: "\n")
    }

    private func renderWorldRules(_ rules: [StoryWorldRule]) -> String {
        guard !rules.isEmpty else { return "- 当前无适用规则" }
        return rules.map {
            var line = "- \($0.title)：\($0.detail)"
            if !$0.scope.isEmpty {
                line += "；范围：\($0.scope)"
            }
            return line
        }.joined(separator: "\n")
    }

    private func renderRecentEvents(_ events: [StoryTimelineEventSlice]) -> String {
        guard !events.isEmpty else { return "- 当前无相关事件" }
        return events.map {
            "- 第\($0.chapterNumber)章第\($0.sceneIndex)场：\($0.title)；\($0.summary.isEmpty ? $0.locationName : $0.summary)"
        }.joined(separator: "\n")
    }

    private func renderForeshadows(_ foreshadows: [StoryForeshadowSlice]) -> String {
        guard !foreshadows.isEmpty else { return "- 当前无未解决伏笔" }
        return foreshadows.map {
            "- \($0.tag)：\($0.detail)"
        }.joined(separator: "\n")
    }

    private func renderStyleDirective(_ style: StoryStyleProfile?) -> String {
        guard let style else { return "- 沿用现有叙事风格" }

        var parts: [String] = []
        if !style.authorPreferences.isEmpty {
            parts.append(style.authorPreferences)
        }
        if !style.narrativeVoice.isEmpty {
            parts.append("叙事声音：\(style.narrativeVoice)")
        }
        let antiPatterns = StoryMemoryJSONCodec.decode([String].self, from: style.antiPatternsJSON, fallback: [])
        if !antiPatterns.isEmpty {
            parts.append("避免：\(antiPatterns.joined(separator: "、"))")
        }
        let samples = StoryMemoryJSONCodec.decode([String].self, from: style.samplePassagesJSON, fallback: [])
        if let firstSample = samples.first, !firstSample.isEmpty {
            parts.append("参考句感：\(firstSample)")
        }

        return parts.isEmpty ? "- 沿用现有叙事风格" : "- " + parts.joined(separator: "；")
    }
}