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

    func executeStoryMemoryUpsertChapter(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }
        guard let chapterNumber = input["chapter_number"]?.intValue, chapterNumber > 0 else {
            return "Error: missing or invalid 'chapter_number' parameter"
        }
        guard let title = input["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing required parameter 'title'"
        }

        do {
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            let existed = project.chapters.contains { $0.number == chapterNumber }
            let service = StoryMemoryService(modelContext: modelContext)
            let chapter = try service.upsertChapter(
                projectId: projectId,
                payload: StoryChapterDraft(
                    chapterNumber: chapterNumber,
                    title: title,
                    outline: input["outline"]?.stringValue ?? "",
                    summary: input["summary"]?.stringValue ?? "",
                    toneDirective: input["tone_directive"]?.stringValue ?? "",
                    isLocked: input["is_locked"]?.boolValue ?? false
                )
            )

            let fields = changedFields([
                ("outline", !chapter.outline.isEmpty),
                ("summary", !chapter.summary.isEmpty),
                ("tone_directive", !chapter.toneDirective.isEmpty),
                ("is_locked", true)
            ])

            return """
            Story chapter \(existed ? "updated" : "created").
            Project: \(project.title)
            Locator: chapter \(chapter.number)
            Title: \(chapter.title)
            Changed fields: \(fields)
            """
        } catch {
            return "Error: failed to upsert story chapter — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryUpsertChapter(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryUpsertChapter(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryUpsertScene(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }
        guard let chapterNumber = input["chapter_number"]?.intValue, chapterNumber > 0 else {
            return "Error: missing or invalid 'chapter_number' parameter"
        }
        guard let sceneIndex = input["scene_index"]?.intValue, sceneIndex > 0 else {
            return "Error: missing or invalid 'scene_index' parameter"
        }
        guard let title = input["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing required parameter 'title'"
        }

        do {
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            let existed = project.chapters
                .first(where: { $0.number == chapterNumber })?
                .scenes.contains(where: { $0.sceneIndex == sceneIndex }) ?? false
            let service = StoryMemoryService(modelContext: modelContext)
            let scene = try service.upsertScene(
                projectId: projectId,
                payload: StorySceneDraft(
                    chapterNumber: chapterNumber,
                    sceneIndex: sceneIndex,
                    title: title,
                    content: input["content"]?.stringValue ?? "",
                    povCharacterName: input["pov_character_name"]?.stringValue ?? "",
                    locationName: input["location_name"]?.stringValue ?? "",
                    characterNames: decodeStringArray(input["character_names"]),
                    summary: input["summary"]?.stringValue ?? "",
                    previousSceneId: parseUUIDParameter("previous_scene_id", from: input),
                    timelineEventId: parseUUIDParameter("timeline_event_id", from: input)
                )
            )

            let fields = changedFields([
                ("content", !scene.content.isEmpty),
                ("pov_character_name", !scene.povCharacterName.isEmpty),
                ("location_name", !scene.locationName.isEmpty),
                ("character_names", !decodeJSONStringArray(scene.characterNamesJSON).isEmpty),
                ("summary", !scene.summary.isEmpty)
            ])

            return """
            Story scene \(existed ? "updated" : "created").
            Project: \(project.title)
            Locator: chapter \(chapterNumber), scene \(sceneIndex)
            Title: \(scene.title)
            Changed fields: \(fields)
            """
        } catch {
            return "Error: failed to upsert story scene — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryUpsertScene(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryUpsertScene(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryUpsertWorldRule(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }
        guard let title = input["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing required parameter 'title'"
        }

        do {
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            let existed = project.worldRules.contains { $0.title == title }
            let service = StoryMemoryService(modelContext: modelContext)
            let rule = try service.upsertWorldRule(
                projectId: projectId,
                payload: StoryWorldRuleDraft(
                    title: title,
                    category: input["category"]?.stringValue ?? "",
                    detail: input["detail"]?.stringValue ?? "",
                    scope: input["scope"]?.stringValue ?? "",
                    exceptions: decodeStringArray(input["exceptions"]),
                    establishedInChapter: input["established_in_chapter"]?.intValue ?? 0,
                    relatedEntities: decodeStringArray(input["related_entities"]),
                    mutablePolicy: input["mutable_policy"]?.stringValue ?? "immutable"
                )
            )

            let fields = changedFields([
                ("category", !rule.category.isEmpty),
                ("detail", !rule.detail.isEmpty),
                ("scope", !rule.scope.isEmpty),
                ("exceptions", !decodeJSONStringArray(rule.exceptionsJSON).isEmpty),
                ("related_entities", !decodeJSONStringArray(rule.relatedEntitiesJSON).isEmpty),
                ("mutable_policy", !rule.mutablePolicy.isEmpty)
            ])

            return """
            Story world rule \(existed ? "updated" : "created").
            Project: \(project.title)
            Locator: \(rule.title)
            Changed fields: \(fields)
            """
        } catch {
            return "Error: failed to upsert world rule — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryUpsertWorldRule(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryUpsertWorldRule(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryUpsertLocation(
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

        do {
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            let existed = project.locations.contains { $0.name == name }
            let service = StoryMemoryService(modelContext: modelContext)
            let location = try service.upsertLocation(
                projectId: projectId,
                payload: StoryLocationDraft(
                    name: name,
                    summary: input["summary"]?.stringValue ?? "",
                    traits: decodeStringArray(input["traits"]),
                    relatedRules: decodeStringArray(input["related_rules"]),
                    occupantNames: decodeStringArray(input["occupant_names"])
                )
            )

            let fields = changedFields([
                ("summary", !location.summary.isEmpty),
                ("traits", !decodeJSONStringArray(location.traitsJSON).isEmpty),
                ("related_rules", !decodeJSONStringArray(location.relatedRulesJSON).isEmpty),
                ("occupant_names", !decodeJSONStringArray(location.occupantNamesJSON).isEmpty)
            ])

            return """
            Story location \(existed ? "updated" : "created").
            Project: \(project.title)
            Locator: \(location.name)
            Changed fields: \(fields)
            """
        } catch {
            return "Error: failed to upsert location — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryUpsertLocation(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryUpsertLocation(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryUpsertForeshadow(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }
        guard let tag = input["tag"]?.stringValue, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing required parameter 'tag'"
        }

        do {
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            let existed = project.foreshadowItems.contains { $0.tag == tag }
            let service = StoryMemoryService(modelContext: modelContext)
            let foreshadow = try service.upsertForeshadow(
                projectId: projectId,
                payload: StoryForeshadowDraft(
                    tag: tag,
                    introducedInChapter: input["introduced_in_chapter"]?.intValue ?? 0,
                    detail: input["detail"]?.stringValue ?? "",
                    relatedEventIds: decodeUUIDArray(input["related_event_ids"]),
                    status: input["status"]?.stringValue ?? "open",
                    resolvedInChapter: input["resolved_in_chapter"]?.intValue ?? 0
                )
            )

            let fields = changedFields([
                ("introduced_in_chapter", foreshadow.introducedInChapter > 0),
                ("detail", !foreshadow.detail.isEmpty),
                ("related_event_ids", !decodeUUIDJSONStringArray(foreshadow.relatedEventIdsJSON).isEmpty),
                ("status", !foreshadow.status.isEmpty),
                ("resolved_in_chapter", foreshadow.resolvedInChapter > 0)
            ])

            return """
            Story foreshadow \(existed ? "updated" : "created").
            Project: \(project.title)
            Locator: \(foreshadow.tag)
            Status: \(foreshadow.status)
            Changed fields: \(fields)
            """
        } catch {
            return "Error: failed to upsert foreshadow — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryUpsertForeshadow(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryUpsertForeshadow(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryUpsertStyleProfile(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }

        do {
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            let existed = project.styleProfile != nil
            let service = StoryMemoryService(modelContext: modelContext)
            let style = try service.upsertStyleProfile(
                projectId: projectId,
                payload: StoryStyleProfileDraft(
                    authorPreferences: input["author_preferences"]?.stringValue ?? "",
                    narrativeVoice: input["narrative_voice"]?.stringValue ?? "",
                    sentenceLengthMean: parseDoubleParameter("sentence_length_mean", from: input) ?? 0,
                    dialogueRatio: parseDoubleParameter("dialogue_ratio", from: input) ?? 0,
                    imageryDensity: parseDoubleParameter("imagery_density", from: input) ?? 0,
                    samplePassages: decodeStringArray(input["sample_passages"]),
                    antiPatterns: decodeStringArray(input["anti_patterns"])
                )
            )

            let fields = changedFields([
                ("author_preferences", !style.authorPreferences.isEmpty),
                ("narrative_voice", !style.narrativeVoice.isEmpty),
                ("sentence_length_mean", style.sentenceLengthMean > 0),
                ("dialogue_ratio", style.dialogueRatio > 0),
                ("imagery_density", style.imageryDensity > 0),
                ("sample_passages", !decodeJSONStringArray(style.samplePassagesJSON).isEmpty),
                ("anti_patterns", !decodeJSONStringArray(style.antiPatternsJSON).isEmpty)
            ])

            return """
            Story style profile \(existed ? "updated" : "created").
            Project: \(project.title)
            Narrative voice: \(style.narrativeVoice.isEmpty ? "unspecified" : style.narrativeVoice)
            Changed fields: \(fields)
            """
        } catch {
            return "Error: failed to upsert style profile — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryUpsertStyleProfile(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryUpsertStyleProfile(input: input, session: session, modelContext: modelContext)
    }

    func executeStoryMemoryUpdateContinuityIssue(
        input: MessageResponse.Content.Input,
        session: Session,
        modelContext: ModelContext
    ) -> String {
        guard let projectId = resolveStoryProjectId(input: input, session: session) else {
            return "Error: missing story project context. Provide 'project_id' or attach a project to the current session."
        }
        guard let issueId = parseUUIDParameter("issue_id", from: input) else {
            return "Error: missing or invalid 'issue_id' parameter"
        }
        guard let resolutionStatus = input["resolution_status"]?.stringValue,
              ["open", "accepted", "resolved", "wont_fix"].contains(resolutionStatus) else {
            return "Error: missing or invalid 'resolution_status' parameter"
        }

        let resolutionNote = input["resolution_note"]?.stringValue ?? ""
        let service = StoryMemoryService(modelContext: modelContext)
        do {
            let issue = try service.updateContinuityIssue(
                projectId: projectId,
                issueId: issueId,
                payload: StoryContinuityIssueUpdateDraft(
                    resolutionStatus: resolutionStatus,
                    resolutionNote: resolutionNote
                )
            )
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            return """
            Story continuity issue updated.
            Project: \(project.title)
            Issue ID: \(issue.id.uuidString)
            Resolution status: \(issue.resolutionStatus)
            Resolution note: \(resolutionNote.isEmpty ? "none" : resolutionNote)
            """
        } catch {
            return "Error: failed to update continuity issue — \(error.localizedDescription)"
        }
    }

    func executeStoryMemoryUpdateContinuityIssue(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let session = fetchSession(sessionId: sessionId, modelContext: modelContext) else {
            return "Error: no active session found for story memory"
        }
        return executeStoryMemoryUpdateContinuityIssue(input: input, session: session, modelContext: modelContext)
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
            let project = try fetchStoryProject(id: projectId, modelContext: modelContext)
            switch queryKind {
            case "characters":
                let names = decodeStringArray(input["names"])
                let cards = try retrieval.activeCharacterCards(projectId: projectId, names: names)
                let lines = cards.map {
                    "- \($0.name) | \($0.summary.isEmpty ? "无摘要" : $0.summary) | 目标: \($0.goals.isEmpty ? "无" : $0.goals.joined(separator: ", "))"
                }
                return queryResponse(
                    title: "活跃角色",
                    projectTitle: project.title,
                    filters: names.isEmpty ? "none" : "names=\(names.joined(separator: ", "))",
                    lines: lines
                )
            case "events":
                let names = decodeStringArray(input["involving"])
                let limit = max(1, input["limit"]?.intValue ?? 5)
                let events = try retrieval.recentEvents(projectId: projectId, involving: names, limit: limit)
                let lines = events.map {
                    "- Ch\($0.chapterNumber) Sc\($0.sceneIndex) | \($0.title) | \($0.locationName.isEmpty ? "未指定地点" : $0.locationName)"
                }
                return queryResponse(
                    title: "相关事件",
                    projectTitle: project.title,
                    filters: names.isEmpty ? "limit=\(limit)" : "involving=\(names.joined(separator: ", ")), limit=\(limit)",
                    lines: lines
                )
            case "foreshadows":
                let upToChapter = max(0, input["up_to_chapter"]?.intValue ?? .max)
                let items = try retrieval.unresolvedForeshadows(projectId: projectId, upToChapter: upToChapter)
                let lines = items.map {
                    "- \($0.tag) | introduced: Ch\($0.introducedInChapter) | \($0.detail.isEmpty ? "无详情" : $0.detail)"
                }
                return queryResponse(
                    title: "未解决伏笔",
                    projectTitle: project.title,
                    filters: upToChapter == .max ? "none" : "up_to_chapter=\(upToChapter)",
                    lines: lines
                )
            case "chapters":
                let chapters = try retrieval.chapters(projectId: projectId)
                let lines = chapters.map {
                    "- Chapter \($0.number) | \($0.title) | scenes: \($0.scenes.count) | locked: \($0.isLocked)"
                }
                return queryResponse(title: "章节", projectTitle: project.title, filters: "none", lines: lines)
            case "scenes":
                let chapterNumber = input["chapter_number"]?.intValue
                let scenes = try retrieval.scenes(projectId: projectId, chapterNumber: chapterNumber)
                let lines = scenes.map {
                    let chapterLabel = $0.chapter?.number ?? chapterNumber ?? 0
                    return "- Chapter \(chapterLabel) Scene \($0.sceneIndex) | \($0.title) | POV: \($0.povCharacterName.isEmpty ? "未指定" : $0.povCharacterName) | 地点: \($0.locationName.isEmpty ? "未指定" : $0.locationName)"
                }
                return queryResponse(
                    title: "场景",
                    projectTitle: project.title,
                    filters: chapterNumber.map { "chapter_number=\($0)" } ?? "none",
                    lines: lines
                )
            case "world_rules":
                let rules = try retrieval.worldRules(projectId: projectId)
                let lines = rules.map {
                    "- \($0.title) | category: \($0.category.isEmpty ? "unspecified" : $0.category) | scope: \($0.scope.isEmpty ? "unspecified" : $0.scope) | mutable: \($0.mutablePolicy)"
                }
                return queryResponse(title: "世界规则", projectTitle: project.title, filters: "none", lines: lines)
            case "locations":
                let locations = try retrieval.locations(projectId: projectId)
                let lines = locations.map {
                    let occupants = decodeJSONStringArray($0.occupantNamesJSON)
                    return "- \($0.name) | \($0.summary.isEmpty ? "无摘要" : $0.summary) | occupants: \(occupants.isEmpty ? "none" : occupants.joined(separator: ", "))"
                }
                return queryResponse(title: "地点档案", projectTitle: project.title, filters: "none", lines: lines)
            case "style":
                guard let style = try retrieval.styleProfile(projectId: projectId) else {
                    return queryResponse(title: "风格档案", projectTitle: project.title, filters: "none", lines: ["- none"])
                }
                let lines = [
                    "- author_preferences: \(style.authorPreferences.isEmpty ? "none" : style.authorPreferences)",
                    "- narrative_voice: \(style.narrativeVoice.isEmpty ? "none" : style.narrativeVoice)",
                    "- sentence_length_mean: \(style.sentenceLengthMean)",
                    "- dialogue_ratio: \(style.dialogueRatio)",
                    "- imagery_density: \(style.imageryDensity)"
                ]
                return queryResponse(title: "风格档案", projectTitle: project.title, filters: "none", lines: lines)
            case "continuity_issues":
                let resolutionStatus = input["resolution_status"]?.stringValue
                let issues = try retrieval.continuityIssues(projectId: projectId, resolutionStatus: resolutionStatus)
                let lines = issues.map {
                    "- \($0.issueKind) | status: \($0.resolutionStatus) | severity: \($0.severity) | Ch\($0.chapterNumber) Sc\($0.sceneIndex)"
                }
                return queryResponse(
                    title: "连续性问题",
                    projectTitle: project.title,
                    filters: resolutionStatus.map { "resolution_status=\($0)" } ?? "none",
                    lines: lines
                )
            default:
                return "Error: unsupported 'query_kind' value '\(queryKind)'. Use characters | events | foreshadows | chapters | scenes | world_rules | locations | style | continuity_issues"
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

    private func decodeUUIDArray(_ value: MessageResponse.Content.DynamicContent?) -> [UUID] {
        decodeStringArray(value).compactMap(UUID.init(uuidString:))
    }

    private func decodeUUIDJSONStringArray(_ value: String) -> [UUID] {
        StoryMemoryJSONCodec.decode([UUID].self, from: value, fallback: [])
    }

    private func parseDoubleParameter(_ key: String, from input: MessageResponse.Content.Input) -> Double? {
        guard let value = input[key] else { return nil }
        let any = dynamicContentToAny(value)
        if let doubleValue = any as? Double {
            return doubleValue
        }
        if let intValue = any as? Int {
            return Double(intValue)
        }
        if let number = any as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

    private func changedFields(_ fields: [(String, Bool)]) -> String {
        let names = fields.compactMap { $0.1 ? $0.0 : nil }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private func queryResponse(title: String, projectTitle: String, filters: String, lines: [String]) -> String {
        let body = lines.isEmpty ? "- none" : lines.joined(separator: "\n")
        return """
        \(title):
        Project: \(projectTitle)
        Filters: \(filters)
        \(body)
        """
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
