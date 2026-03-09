//
//  ClaudeService+StoryMemoryTools.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

extension ClaudeService {

    // MARK: - Story Memory Tools

    func executeStoryMemoryCreateProject(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let title = input["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing required parameter 'title'"
        }

        let synopsis = input["synopsis"]?.stringValue ?? ""
        let attachToSession = input["attach_to_session"]?.boolValue ?? true
        let service = StoryMemoryService(modelContext: modelContext)

        do {
            let project = try service.createProject(title: title, synopsis: synopsis)
            if attachToSession {
                try service.attachProject(to: session, projectId: project.id)
            }
            return """
            Writing project '\(project.title)' created.
            Project ID: \(project.id.uuidString)
            Attached to current session: \(attachToSession ? "yes" : "no")
            Synopsis: \(synopsis.isEmpty ? "none" : synopsis)
            """
        } catch {
            return "Error: failed to create story project — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryCreateProject(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryCreateProject(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryAttachProject(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = parseUUIDParameter("project_id", from: input) else {
            return "Error: missing or invalid 'project_id' parameter"
        }

        let service = StoryMemoryService(modelContext: modelContext)
        do {
            try service.attachProject(to: session, projectId: projectId)
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            return "Attached writing project '\(project.title)' to the current session."
        } catch {
            return "Error: failed to attach story project — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryAttachProject(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryAttachProject(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryUpsertCharacter(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }
        guard let name = input["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing required parameter 'name'"
        }

        let draft = StoryCharacterDraft(
            name: name,
            summary: input["summary"]?.stringValue ?? "",
            traits: decodeStringArray(input["traits"]),
            goals: decodeStringArray(input["goals"]),
            speechStyle: input["speech_style"]?.stringValue ?? "",
            relationships: decodeStringDictionary(input["relationships"]),
            arcStage: input["arc_stage"]?.stringValue ?? "",
            lastSeenChapter: input["last_seen_chapter"]?.intValue ?? 0,
            lastKnownLocation: input["last_known_location"]?.stringValue ?? ""
        )

        let service = StoryMemoryService(modelContext: modelContext)
        do {
            let character = try service.upsertCharacter(projectId: projectId, payload: draft)
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            let tracked = [
                !character.summary.isEmpty ? "summary" : nil,
                !character.speechStyle.isEmpty ? "speech_style" : nil,
                !draft.goals.isEmpty ? "goals" : nil,
                !draft.traits.isEmpty ? "traits" : nil,
                !character.arcStage.isEmpty ? "arc_stage" : nil,
                !character.lastKnownLocation.isEmpty ? "last_known_location" : nil
            ].compactMap { $0 }

            return """
            Character '\(character.name)' updated in project \(project.title).
            Tracked fields: \(tracked.isEmpty ? "name only" : tracked.joined(separator: ", ")).
            Last seen chapter: \(character.lastSeenChapter)
            Last known location: \(character.lastKnownLocation.isEmpty ? "unknown" : character.lastKnownLocation)
            """
        } catch {
            return "Error: failed to update character memory — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryUpsertCharacter(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryUpsertCharacter(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryAppendEvent(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }
        guard let chapterNumber = input["chapter_number"]?.intValue else {
            return "Error: missing required parameter 'chapter_number'"
        }
        guard let sceneIndex = input["scene_index"]?.intValue else {
            return "Error: missing required parameter 'scene_index'"
        }
        guard let title = input["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing required parameter 'title'"
        }

        let draft = StoryTimelineEventDraft(
            chapterNumber: chapterNumber,
            sceneIndex: sceneIndex,
            title: title,
            summary: input["summary"]?.stringValue ?? "",
            participants: decodeStringArray(input["participants"]),
            locationName: input["location_name"]?.stringValue ?? "",
            timeMarker: input["time_marker"]?.stringValue ?? "",
            eventType: input["event_type"]?.stringValue ?? "",
            foreshadowTags: decodeStringArray(input["foreshadow_tags"])
        )

        let service = StoryMemoryService(modelContext: modelContext)
        do {
            let event = try service.appendTimelineEvent(projectId: projectId, payload: draft)
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            return """
            Timeline event '\(event.title)' appended to project \(project.title).
            Position: Chapter \(event.chapterNumber), Scene \(event.sceneIndex)
            Participants: \(decodeJSONStringArray(event.participantNamesJSON).isEmpty ? "none" : decodeJSONStringArray(event.participantNamesJSON).joined(separator: ", "))
            Location: \(event.locationName.isEmpty ? "unspecified" : event.locationName)
            """
        } catch {
            return "Error: failed to append timeline event — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryAppendEvent(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryAppendEvent(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryQuery(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }
        guard let queryKind = input["query_kind"]?.stringValue else {
            return "Error: missing required parameter 'query_kind'"
        }

        let retrieval = StoryMemoryRetrievalService(modelContext: modelContext)
        do {
            switch queryKind {
            case "characters":
                let names = decodeStringArray(input["names"])
                let cards = try retrieval.activeCharacterCards(projectId: projectId, names: names)
                let lines = cards.map {
                    "- \($0.name) | \($0.summary.isEmpty ? "无摘要" : $0.summary) | 目标: \($0.goals.isEmpty ? "无" : $0.goals.joined(separator: ", "))"
                }
                return "活跃角色 (\(cards.count)):\n\(lines.isEmpty ? "- none" : lines.joined(separator: "\n"))"
            case "events":
                let names = decodeStringArray(input["involving"])
                let limit = max(1, input["limit"]?.intValue ?? 5)
                let events = try retrieval.recentEvents(projectId: projectId, involving: names, limit: limit)
                let lines = events.map {
                    "- Ch\($0.chapterNumber) Sc\($0.sceneIndex) | \($0.title) | \($0.locationName.isEmpty ? "未指定地点" : $0.locationName)"
                }
                return "相关事件 (\(events.count)):\n\(lines.isEmpty ? "- none" : lines.joined(separator: "\n"))"
            case "foreshadows":
                let upToChapter = max(0, input["up_to_chapter"]?.intValue ?? .max)
                let items = try retrieval.unresolvedForeshadows(projectId: projectId, upToChapter: upToChapter)
                let lines = items.map {
                    "- \($0.tag) | introduced: Ch\($0.introducedInChapter) | \($0.detail.isEmpty ? "无详情" : $0.detail)"
                }
                return "未解决伏笔 (\(items.count)):\n\(lines.isEmpty ? "- none" : lines.joined(separator: "\n"))"
            default:
                return "Error: unsupported 'query_kind' value '\(queryKind)'. Use characters | events | foreshadows"
            }
        } catch {
            return "Error: failed to query story memory — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryQuery(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryQuery(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryVerifyContinuity(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }
        guard let chapterNumber = input["chapter_number"]?.intValue else {
            return "Error: missing required parameter 'chapter_number'"
        }
        guard let sceneIndex = input["scene_index"]?.intValue else {
            return "Error: missing required parameter 'scene_index'"
        }
        guard let title = input["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing required parameter 'title'"
        }

        do {
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            let retrieval = StoryMemoryRetrievalService(modelContext: modelContext)
            let continuity = StoryContinuityService()

            let draft = StorySceneDraftInput(
                chapterNumber: chapterNumber,
                sceneIndex: sceneIndex,
                title: title,
                summary: input["summary"]?.stringValue ?? "",
                locationName: input["location_name"]?.stringValue ?? "",
                povCharacterName: input["pov_character_name"]?.stringValue ?? "",
                characterNames: decodeStringArray(input["character_names"]),
                referencedForeshadowTags: decodeStringArray(input["referenced_foreshadow_tags"]),
                text: input["text"]?.stringValue ?? ""
            )

            let activeNames = Array(Set(draft.characterNames + [draft.povCharacterName]).filter { !$0.isEmpty })
            let cards = try retrieval.activeCharacterCards(projectId: projectId, names: activeNames)
            let previousScene = latestStoryScene(in: project)
            let resolvedTags = project.foreshadowItems.compactMap { item in
                (item.status == "resolved" || item.resolvedInChapter > 0) ? item.tag : nil
            }

            let warnings = continuity.evaluateSceneDraft(
                draft: draft,
                previousScene: previousScene,
                activeCharacterCards: cards,
                worldRules: project.worldRules,
                resolvedForeshadowTags: resolvedTags
            )

            if warnings.isEmpty {
                return "Continuity warnings: none."
            }

            for warning in warnings {
                let issue = StoryContinuityIssue(
                    issueKind: warning.kind.rawValue,
                    chapterNumber: draft.chapterNumber,
                    sceneIndex: draft.sceneIndex,
                    detail: warning.message
                )
                issue.project = project
                project.continuityIssues.append(issue)
            }
            try modelContext.save()

            let lines = warnings.map { "- \($0.kind.rawValue): \($0.message)" }
            return "Continuity warnings (\(warnings.count)):\n\(lines.joined(separator: "\n"))"
        } catch {
            return "Error: failed to verify story continuity — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryVerifyContinuity(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryVerifyContinuity(input: input, session: session, modelContext: modelContext)
    }

    // MARK: - Helper Methods

    private func fetchSession(sessionId: String, modelContext: ModelContext) -> Session? {
        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.sessionId == sessionId })
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchStoryProject(id: UUID, modelContext: ModelContext) throws -> WritingProject {
        let descriptor = FetchDescriptor<WritingProject>(predicate: #Predicate { $0.id == id })
        guard let project = try modelContext.fetch(descriptor).first else {
            throw StoryMemoryServiceError.projectNotFound(id)
        }
        return project
    }

    private func parseUUIDParameter(_ key: String, from input: MessageResponse.Content.Input) -> UUID? {
        guard let rawValue = input[key]?.stringValue else { return nil }
        return UUID(uuidString: rawValue)
    }

    private func resolveStoryProjectId(input: MessageResponse.Content.Input, session: Session) -> UUID? {
        if let projectId = parseUUIDParameter("project_id", from: input) {
            return projectId
        }
        return UUID(uuidString: session.activeWritingProjectId)
    }

    private func decodeStringArray(_ value: MessageResponse.Content.DynamicContent?) -> [String] {
        guard let value else { return [] }
        let any = dynamicContentToAny(value)
        guard let array = any as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: array),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private func decodeStringDictionary(_ value: MessageResponse.Content.DynamicContent?) -> [String: String] {
        guard let value else { return [:] }
        let any = dynamicContentToAny(value)
        guard let dictionary = any as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func decodeJSONStringArray(_ value: String) -> [String] {
        StoryMemoryJSONCodec.decode([String].self, from: value, fallback: [])
    }

    private func latestStoryScene(in project: WritingProject) -> StorySceneContinuitySnapshot? {
        project.chapters
            .sorted { lhs, rhs in
                if lhs.number != rhs.number {
                    return lhs.number < rhs.number
                }
                return lhs.title < rhs.title
            }
            .flatMap { chapter in
                chapter.scenes.map { scene in
                    StorySceneContinuitySnapshot(
                        chapterNumber: chapter.number,
                        sceneIndex: scene.sceneIndex,
                        locationName: scene.locationName,
                        summary: scene.summary
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.chapterNumber != rhs.chapterNumber {
                    return lhs.chapterNumber < rhs.chapterNumber
                }
                return lhs.sceneIndex < rhs.sceneIndex
            }
            .last
    }
}
