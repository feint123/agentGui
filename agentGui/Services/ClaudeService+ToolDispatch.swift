//
//  ClaudeService+ToolDispatch.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - ToolExecutionResult

/// Wraps the result of a tool execution with a semantic status, text output, and optional
/// media objects (e.g. images). The `status` drives both `ToolCall.status` in the UI and
/// the `is_error` flag sent back to the model so it can reason about failures explicitly.
struct ToolExecutionResult {
    let status: ToolResultStatus
    let text: String
    let mediaContent: [MessageParameter.Message.Content.ContentObject]

    /// True when the result represents any kind of failure; maps directly to `is_error` in the
    /// Anthropic tool-result block so the model receives a structured failure signal.
    var isError: Bool { status != .success }

    /// True when the failure is transient and the caller may choose to retry.
    var isRetryable: Bool {
        switch status {
        case .retryableFailure, .timeout: return true
        default: return false
        }
    }

    /// Maps ToolResultStatus to the persistent ToolCall.status stored in SwiftData.
    var toolCallStatus: ToolStatus {
        status == .success ? .success : .failed
    }

    // MARK: Designated initialiser (backward-compatible, defaults to .success)
    init(
        _ text: String,
        status: ToolResultStatus = .success,
        mediaContent: [MessageParameter.Message.Content.ContentObject] = []
    ) {
        self.status = status
        self.text = text
        self.mediaContent = mediaContent
    }

    // MARK: Named factory methods

    static func success(
        _ text: String,
        mediaContent: [MessageParameter.Message.Content.ContentObject] = []
    ) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .success, mediaContent: mediaContent)
    }

    static func failure(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .failure)
    }

    static func retryableFailure(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .retryableFailure)
    }

    static func timeout(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .timeout)
    }

    static func permissionDenied(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .permissionDenied)
    }

    static func missingParameter(_ name: String) -> ToolExecutionResult {
        ToolExecutionResult("Error: missing required parameter '\(name)'", status: .missingParameter)
    }

    static func parseError(_ text: String) -> ToolExecutionResult {
        ToolExecutionResult(text, status: .parseError)
    }

    static func unknownTool(_ name: String) -> ToolExecutionResult {
        ToolExecutionResult("Error: unknown tool '\(name)'", status: .unknownTool)
    }

    // MARK: String-based error detection

    /// Wraps a plain string returned by a tool implementation, automatically inferring the
    /// correct ToolResultStatus from the text content.  Strings not starting with "Error:"
    /// are treated as `.success`.
    static func detect(_ text: String, toolName: String = "") -> ToolExecutionResult {
        let hasErrorPrefix = text.hasPrefix("Error:") || text.hasPrefix("error:")
        guard hasErrorPrefix else { return ToolExecutionResult(text, status: .success) }
        let lower = text.lowercased()
        if lower.contains("[timed out after") || lower.contains("timed out") {
            return ToolExecutionResult(text, status: .timeout)
        }
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return ToolExecutionResult(text, status: .permissionDenied)
        }
        if lower.contains("missing") && (lower.contains("parameter") || lower.contains("param")) {
            return ToolExecutionResult(text, status: .missingParameter)
        }
        if lower.contains("parse") || lower.contains("decode") || lower.contains("failed to parse") {
            return ToolExecutionResult(text, status: .parseError)
        }
        // Transient network errors for web tools
        let isWebTool = toolName == "web_fetch" || toolName.contains("web_search")
        if isWebTool && (lower.contains("http") || lower.contains("network") ||
                         lower.contains("connection") || lower.contains("urlerror")) {
            return ToolExecutionResult(text, status: .retryableFailure)
        }
        return ToolExecutionResult(text, status: .failure)
    }
}

// MARK: - Tool Dispatch & Bash Session Management

extension ClaudeService {

    private static let interactiveCommandRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(^|\s)read\s+"#,
            #"(^|\s)select\s+"#,
            #"(^|\s)(sudo|su|passwd)(\s|$)"#,
            #"(^|\s)(ssh|sftp|ftp)\s"#,
            #"(^|\s)(mysql|psql|sqlite3)(\s|$)"#,
            #"(^|\s)git\s+add\s+-p(\s|$)"#,
            #"(^|\s)git\s+rebase\s+-i(\s|$)"#,
            #"(^|\s)git\s+commit(\s|$)"#,
            #"(^|\s)(npm|pnpm|yarn)\s+(init|login)(\s|$)"#,
            #"(^|\s)(pnpm|yarn|npm|bunx|npx)\s+(create|dlx)\s"#,
            #"(^|\s)(rails\s+console|python(3)?|node|irb)(\s|$)"#
        ]

        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    private static let nonInteractiveGitCommitRegex = try? NSRegularExpression(
        pattern: #"(^|\s)git\s+commit\s+.*(--message|-m|--amend\s+--no-edit|--no-edit)(\s|$)"#,
        options: [.caseInsensitive]
    )

    private func shouldAutoEnableInteractiveMode(for command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let range = NSRange(location: 0, length: trimmed.utf16.count)
        if let regex = Self.nonInteractiveGitCommitRegex,
           regex.firstMatch(in: trimmed, options: [], range: range) != nil {
            return false
        }

        return Self.interactiveCommandRegexes.contains { regex in
            regex.firstMatch(in: trimmed, options: [], range: range) != nil
        }
    }

    // MARK: Dispatch

    func executeTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings,
        session: Session,
        modelContext: ModelContext
    ) async -> ToolExecutionResult {
        let sessionId = session.sessionId
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            return .detect(await executeTextEditorTool(input: input), toolName: name)
        case "bash":
            let wd = effectiveWorkingDirectory(session: session, settings: settings)
            let bashSess = getBashSession(
                for: sessionId,
                workingDirectory: wd,
                environmentOverrides: settings.proxyConfiguration.bashEnvironmentOverrides
            )
            return .detect(await executeBashTool(input: input, session: bashSess, workingDirectory: wd, settings: settings), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = skillService?.readSkillContent(name: skillName) {
                return .success(content)
            }
            return .failure("Error: skill '\(skillName)' not found")
        case "update_todo_list":
            return .detect(executeUpdateTodoList(input: input, sessionId: sessionId), toolName: name)
        case "web_search":
            if settings.enableOllamaWebSearch && !settings.ollamaAPIKey.isEmpty {
                return .detect(await executeOllamaWebSearchTool(input: input, apiKey: settings.ollamaAPIKey, settings: settings), toolName: name)
            }
            return .detect(await executeWebSearchTool(input: input, settings: settings), toolName: name)
        case "web_fetch":
            return .detect(await executeWebFetchTool(input: input, settings: settings), toolName: name)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(executeMemoryWrite(input: input), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "verify_completion":
            return .detect(executeVerifyCompletion(input: input, sessionId: sessionId), toolName: name)
        case "story_memory_create_project":
            return .detect(executeStoryMemoryCreateProject(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_attach_project":
            return .detect(executeStoryMemoryAttachProject(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_character":
            return .detect(executeStoryMemoryUpsertCharacter(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_append_event":
            return .detect(executeStoryMemoryAppendEvent(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_query":
            return .detect(executeStoryMemoryQuery(input: input, session: session, modelContext: modelContext), toolName: name)
        case "story_memory_verify_continuity":
            return .detect(executeStoryMemoryVerifyContinuity(input: input, session: session, modelContext: modelContext), toolName: name)
        default:
            return .unknownTool(name)
        }
    }

    // MARK: Update Todo List

    @discardableResult
    func executeUpdateTodoList(input: MessageResponse.Content.Input, sessionId: String) -> String {
        guard let itemsValue = input["items"] else {
            return "Error: missing 'items' parameter"
        }
        let anyValue = dynamicContentToAny(itemsValue)
        guard
            let arrayValue = anyValue as? [[String: Any]],
            let data = try? JSONSerialization.data(withJSONObject: arrayValue),
            let items = try? JSONDecoder().decode([TodoItem].self, from: data)
        else {
            return "Error: failed to parse 'items' array"
        }
        sessionTodoLists[sessionId] = items
        return "Todo list updated with \(items.count) items."
    }

    // MARK: Create Execution Plan

    /// Parses the `create_execution_plan` tool call, persists the plan to `Session.planJson`,
    /// and returns a human-readable confirmation string.
    @discardableResult
    func executeCreateExecutionPlan(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let goal = input["goal"]?.stringValue else {
            return "Error: missing required parameter 'goal'"
        }
        guard let stepsValue = input["steps"] else {
            return "Error: missing required parameter 'steps'"
        }
        let anySteps = dynamicContentToAny(stepsValue)
        guard
            let stepsArray = anySteps as? [[String: Any]],
            let stepsData = try? JSONSerialization.data(withJSONObject: stepsArray),
            let parsedSteps = try? JSONDecoder().decode([PlanStep].self, from: stepsData)
        else {
            return "Error: failed to parse 'steps' array — each item must have 'id' (string) and 'title' (string)"
        }

        var assumptions: [String] = []
        if let assumptionsValue = input["assumptions"] {
            let anyAssumptions = dynamicContentToAny(assumptionsValue)
            if let arr = anyAssumptions as? [Any],
               let data = try? JSONSerialization.data(withJSONObject: arr),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                assumptions = decoded
            }
        }

        var successCriteria: [String] = []
        if let criteriaValue = input["success_criteria"] {
            let anyCriteria = dynamicContentToAny(criteriaValue)
            if let arr = anyCriteria as? [Any],
               let data = try? JSONSerialization.data(withJSONObject: arr),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                successCriteria = decoded
            }
        }

        let plan = ExecutionPlan(
            goal: goal,
            steps: parsedSteps,
            assumptions: assumptions,
            successCriteria: successCriteria
        )

        // single source of truth shared with the workflow plan path.
        persistPlan(plan, sessionId: sessionId, modelContext: modelContext)

        let stepList = parsedSteps.enumerated()
            .map { "\($0.offset + 1). \($0.element.title)" }
            .joined(separator: "\n")
        return """
        Execution plan recorded.
        Goal: \(goal)
        Steps (\(parsedSteps.count)):
        \(stepList)
        Assumptions: \(assumptions.isEmpty ? "none" : assumptions.joined(separator: "; "))
        Success criteria: \(successCriteria.isEmpty ? "none" : successCriteria.joined(separator: "; "))
        """
    }

    /// Encodes `plan` as JSON and writes it to the matching `Session.planJson`.
    func persistPlan(_ plan: ExecutionPlan, sessionId: String, modelContext: ModelContext) {
        guard let data = try? JSONEncoder().encode(plan),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        if let session = (try? modelContext.fetch(descriptor))?.first {
            session.planJson = json
            try? modelContext.save()
        }
    }

    // MARK: Verify Completion

    @discardableResult
    func executeVerifyCompletion(input: MessageResponse.Content.Input, sessionId: String) -> String {
        let dynamicToStringArray: (MessageResponse.Content.DynamicContent) -> [String]? = { value in
            let any = self.dynamicContentToAny(value)
            guard let arr = any as? [Any],
                  let data = try? JSONSerialization.data(withJSONObject: arr),
                  let decoded = try? JSONDecoder().decode([String].self, from: data)
            else { return nil }
            return decoded
        }

        guard let verifiedValue = input["verified"],
              let verified = dynamicToStringArray(verifiedValue) else {
            return "Error: missing or invalid 'verified' parameter (expected array of strings)"
        }
        guard let notVerifiedValue = input["not_verified"],
              let notVerified = dynamicToStringArray(notVerifiedValue) else {
            return "Error: missing or invalid 'not_verified' parameter (expected array of strings)"
        }

        let conclusion = input["conclusion"]?.stringValue
        let verification = CompletionVerification(
            verified: verified,
            notVerified: notVerified,
            conclusion: conclusion
        )
        sessionVerifications[sessionId] = verification

        var output = "Verification recorded.\n"
        output += "✅ Verified (\(verified.count)):\n"
        output += verified.map { "  - \($0)" }.joined(separator: "\n")
        if !notVerified.isEmpty {
            output += "\n⚠️ Not verified (\(notVerified.count)):\n"
            output += notVerified.map { "  - \($0)" }.joined(separator: "\n")
        }
        if let conclusion {
            output += "\nConclusion: \(conclusion)"
        }
        return output
    }

    // MARK: Ask User Question

    func executeAskUserQuestion(input: MessageResponse.Content.Input) async -> String {
        // Parse the questions array from the DynamicContent input
        guard let questionsValue = input["questions"] else {
            return "{\"error\": \"missing 'questions' parameter\"}"
        }

        // DynamicContent is Decodable-only, so convert to Any via JSONSerialization
        let anyValue = dynamicContentToAny(questionsValue)
        guard
            let arrayValue = anyValue as? [[String: Any]],
            let data = try? JSONSerialization.data(withJSONObject: arrayValue),
            let questions = try? JSONDecoder().decode([AskUserQuestion].self, from: data)
        else {
            return "{\"error\": \"failed to parse questions\"}"
        }

        // Suspend the agentic loop. ClaudeService is @MainActor so self.pendingUserQuestion
        // can be set directly without a Task wrapper.
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            self.pendingUserQuestion = AskUserQuestionRequest(
                questions: questions,
                continuation: continuation
            )
        }
        // Clear pending state now that the user has responded
        self.pendingUserQuestion = nil
        return result
    }

    /// Recursively convert DynamicContent (Decodable-only) to a JSONSerialization-compatible Any.
    private func dynamicContentToAny(_ content: MessageResponse.Content.DynamicContent) -> Any {
        switch content {
        case .string(let s):  return s
        case .integer(let i): return i
        case .double(let d):  return d
        case .bool(let b):    return b
        case .null:           return NSNull()
        case .array(let arr): return arr.map { dynamicContentToAny($0) }
        case .dictionary(let dict):
            return dict.mapValues { dynamicContentToAny($0) }
        }
    }

    // MARK: Bash Session Management

    // MARK: - Effective Working Directory

    func effectiveWorkingDirectory(session: Session, settings: AppSettings) -> String? {
        if !settings.workingDirectory.isEmpty { return settings.workingDirectory }
        return nil
    }

    /// Convenience overload used by the core agentic loop (and subagents), which carries
    /// a `sessionId` string and `ModelContext` but not a full `Session` object.
    func executeTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async -> ToolExecutionResult {
        let wd = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            return .detect(await executeTextEditorTool(input: input), toolName: name)
        case "bash":
            let bashSess = getBashSession(
                for: sessionId,
                workingDirectory: wd,
                environmentOverrides: settings.proxyConfiguration.bashEnvironmentOverrides
            )
            return .detect(await executeBashTool(input: input, session: bashSess, workingDirectory: wd, settings: settings), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = skillService?.readSkillContent(name: skillName) {
                return .success(content)
            }
            return .failure("Error: skill '\(skillName)' not found")
        case "update_todo_list":
            return .detect(executeUpdateTodoList(input: input, sessionId: sessionId), toolName: name)
        case "web_search":
            if settings.enableOllamaWebSearch && !settings.ollamaAPIKey.isEmpty {
                return .detect(await executeOllamaWebSearchTool(input: input, apiKey: settings.ollamaAPIKey, settings: settings), toolName: name)
            }
            return .detect(await executeWebSearchTool(input: input, settings: settings), toolName: name)
        case "web_fetch":
            return .detect(await executeWebFetchTool(input: input, settings: settings), toolName: name)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(executeMemoryWrite(input: input), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "verify_completion":
            return .detect(executeVerifyCompletion(input: input, sessionId: sessionId), toolName: name)
        case "story_memory_create_project":
            return .detect(executeStoryMemoryCreateProject(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_attach_project":
            return .detect(executeStoryMemoryAttachProject(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_upsert_character":
            return .detect(executeStoryMemoryUpsertCharacter(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_append_event":
            return .detect(executeStoryMemoryAppendEvent(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_query":
            return .detect(executeStoryMemoryQuery(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "story_memory_verify_continuity":
            return .detect(executeStoryMemoryVerifyContinuity(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        default:
            return .unknownTool(name)
        }
    }

    // MARK: Story Memory Tools

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

    // MARK: Bash Session Management

    func getBashSession(
        for sessionId: String,
        workingDirectory: String?,
        environmentOverrides: [String: String]
    ) -> BashSession {
        if let existing = bashSessions[sessionId] { return existing }
        let newSession = BashSession()
        Task {
            await newSession.start(
                workingDirectory: workingDirectory,
                environmentOverrides: environmentOverrides
            )
        }
        bashSessions[sessionId] = newSession
        return newSession
    }

    // MARK: Memory Write

    func executeMemoryWrite(input: MessageResponse.Content.Input) -> String {
        guard let content = input["content"]?.stringValue else {
            return "Error: missing 'content' parameter"
        }
        let modeString = input["mode"]?.stringValue ?? "append"
        let mode: MemoryWriteMode = modeString == "overwrite" ? .overwrite : .append
        switch ConfigDirectoryManager.shared.writeMemory(content: content, mode: mode) {
        case .success:
            return "Memory updated successfully (mode: \(modeString))."
        case .failure(let error):
            return "Error writing memory: \(error.localizedDescription)"
        }
    }

    // MARK: Start Workflow

    /// Launches a named workflow synchronously and returns a result summary.
    func executeStartWorkflowTool(
        input: MessageResponse.Content.Input,
        modelContext: ModelContext
    ) async -> ToolExecutionResult {
        guard let workflowId = input["workflow_id"]?.stringValue else {
            return .missingParameter("workflow_id")
        }
        guard let task = input["task"]?.stringValue else {
            return .missingParameter("task")
        }
        guard let definition = ClaudeService.makeWorkflowDefinition(id: workflowId) else {
            let available = ClaudeService.availableWorkflows.map(\.id).joined(separator: ", ")
            return .failure("Error: unknown workflow_id '\(workflowId)'. Available: \(available)")
        }
        guard let runtime = workflowRuntime else {
            return .failure("Error: workflow runtime is not available")
        }
        guard let session = currentSession else {
            return .failure("Error: no active session for workflow")
        }

        if runtime.isRunning {
            return .failure("Error: a workflow is already running. Wait for it to complete before launching another.")
        }

        do {
            let handle = try await runtime.startWorkflow(
                definition: definition,
                session: session,
                initialTask: task,
                workspaceContext: currentWorkspaceContext,
                modelContext: modelContext
            )
            // Fetch the persisted instance for status/artifact info
            let wfId = handle.workflowId
            let descriptor = FetchDescriptor<WorkflowInstance>(
                predicate: #Predicate { $0.id == wfId }
            )
            let instance = (try? modelContext.fetch(descriptor))?.first
            let statusName = instance?.status.displayName ?? "完成"
            let artifactSummary = instance?.latestArtifacts
                .map { "\($0.kind.displayName) (v\($0.version))" }
                .joined(separator: ", ") ?? "无"
            return .success("""
            Workflow '\(definition.displayName)' completed. Status: \(statusName)
            Artifacts: \(artifactSummary)
            Workflow ID: \(handle.workflowId)

            The workflow sidebar in the UI shows the full execution timeline, inter-agent messages, and artifacts.
            Summarize the outcome for the user based on this information.
            """)
        } catch {
            return .failure("Error: workflow failed — \(error.localizedDescription)")
        }
    }

    // MARK: Bash Tool

    func executeBashTool(
        input: MessageResponse.Content.Input,
        session: BashSession,
        workingDirectory: String?,
        settings: AppSettings
    ) async -> String {
        let environmentOverrides = settings.proxyConfiguration.bashEnvironmentOverrides
        if input["restart"]?.boolValue == true {
            await session.restart(
                workingDirectory: workingDirectory,
                environmentOverrides: environmentOverrides
            )
            return "Bash session restarted."
        }
        let hasFollowUpInput = input["input"]?.stringValue != nil
        let isInteractive = input["interactive"]?.boolValue == true || hasFollowUpInput
        let timeout: TimeInterval
        if let t = input["timeout"]?.intValue {
            timeout = TimeInterval(max(1, t))
        } else {
            timeout = isInteractive ? 2 : 300
        }
        if input["interrupt"]?.boolValue == true {
            return await session.interrupt(timeout: timeout)
        }
        if let followUpInput = input["input"]?.stringValue {
            return await session.sendInput(followUpInput, timeout: timeout)
        }
        guard let command = input["command"]?.stringValue else {
            return "Error: missing 'command' parameter"
        }
        let background = input["background"]?.boolValue ?? false
        let interactive = background
            ? false
            : (input["interactive"]?.boolValue ?? shouldAutoEnableInteractiveMode(for: command))
        return await session.execute(command, timeout: timeout, background: background, interactive: interactive)
    }

    // MARK: ToolCall Record Factory

    func makeToolCallRecord(
        toolUseId: String,
        toolName: String,
        input: MessageResponse.Content.Input,
        message: Message?,
        agentRound: AgentRound? = nil
    ) -> ToolCall {
        let path = input["path"]?.stringValue
        let fileName = path.map { ($0 as NSString).lastPathComponent } ?? ""

        let kind: ToolKind
        let title: String
        var diffContent: String? = nil

        switch toolName {
        case "str_replace_based_edit_tool", "str_replace_editor":
            let cmd = input["command"]?.stringValue ?? "?"
            switch cmd {
            case "view", "read", "open":
                kind = .read
                title = "查看 \(fileName)"
            case "str_replace":
                kind = .edit
                title = "编辑 \(fileName)"
                let old = input["old_str"]?.stringValue ?? ""
                let new = input["new_str"]?.stringValue ?? ""
                diffContent = "--- 原文\n\(old)\n+++ 新文\n\(new)"
            case "create":
                kind = .edit
                title = "创建 \(fileName)"
            case "write":
                kind = .edit
                title = "写入 \(fileName)"
            case "insert":
                kind = .edit
                title = "插入 \(fileName)"
            default:
                kind = .other
                title = cmd
            }
        case "bash":
            kind = .execute
            if input["restart"]?.boolValue == true {
                title = "重启 bash session"
            } else {
                title = String((input["command"]?.stringValue ?? "").prefix(80))
            }
        case "code_execution":
            kind = .execute
            let code = input["code"]?.stringValue ?? ""
            title = "执行代码: \(String(code.prefix(60)))"
        case "read_skill":
            kind = .other
            let skillName = input["name"]?.stringValue ?? ""
            title = "加载技能: \(skillName)"
        case "ask_user_question":
            kind = .askUser
            title = "提问用户"
        case "run_subagent":
            kind = .subagent
            let agentName = input["agent_name"]?.stringValue ?? ""
            let definition = WorkflowRoleDefinition.find(named: agentName)
            title = "子代理: \(definition?.displayName ?? agentName)"
        case "update_todo_list":
            kind = .todo
            let itemCount = input["items"]?.arrayValue?.count ?? 0
            title = "更新任务列表 (\(itemCount)项)"
        case "web_search":
            kind = .search
            let query = input["query"]?.stringValue ?? ""
            title = "搜索: \(String(query.prefix(60)))"
        case "web_fetch":
            kind = .fetch
            let fetchUrl = input["url"]?.stringValue ?? ""
            title = "获取: \(String(fetchUrl.prefix(60)))"
        case "story_memory_create_project":
            kind = .other
            title = "创建故事项目"
        case "story_memory_attach_project":
            kind = .other
            title = "绑定故事项目"
        case "story_memory_upsert_character":
            kind = .other
            title = "更新角色记忆"
        case "story_memory_append_event":
            kind = .other
            title = "追加剧情事件"
        case "story_memory_query":
            kind = .other
            title = "查询故事记忆"
        case "story_memory_verify_continuity":
            kind = .other
            title = "检查连续性"
        default:
            kind = .other
            title = toolName
        }

        let record = ToolCall(toolCallId: toolUseId, kind: kind, message: message, agentRound: agentRound)
        record.title = title
        record.filePath = path
        record.diffContent = diffContent
        record.startTime = Date()

        if kind == .subagent {
            record.subagentAgentName = input["agent_name"]?.stringValue
            record.subagentTask = input["task"]?.stringValue
        }

        return record
    }
}
