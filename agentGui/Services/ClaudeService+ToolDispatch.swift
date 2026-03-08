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

    // MARK: Dispatch

    func executeTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings,
        session: Session
    ) async -> ToolExecutionResult {
        let sessionId = session.sessionId
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            return .detect(await executeTextEditorTool(input: input), toolName: name)
        case "bash":
            let wd = effectiveWorkingDirectory(session: session, settings: settings)
            let bashSess = getBashSession(for: sessionId, workingDirectory: wd)
            return .detect(await executeBashTool(input: input, session: bashSess, workingDirectory: wd), toolName: name)
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
                return .detect(await executeOllamaWebSearchTool(input: input, apiKey: settings.ollamaAPIKey), toolName: name)
            }
            return .detect(await executeWebSearchTool(input: input), toolName: name)
        case "web_fetch":
            return .detect(await executeWebFetchTool(input: input), toolName: name)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(executeMemoryWrite(input: input), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId), toolName: name)
        case "verify_completion":
            return .detect(executeVerifyCompletion(input: input, sessionId: sessionId), toolName: name)
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

    @discardableResult
    func executeCreateExecutionPlan(input: MessageResponse.Content.Input, sessionId: String) -> String {
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
        sessionExecutionPlans[sessionId] = plan

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

    /// Convenience overload used by subagent loops that only have a sessionId string.
    /// Falls back to global settings working directory.
    func executeTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings,
        sessionId: String
    ) async -> ToolExecutionResult {
        let wd = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            return .detect(await executeTextEditorTool(input: input), toolName: name)
        case "bash":
            let bashSess = getBashSession(for: sessionId, workingDirectory: wd)
            return .detect(await executeBashTool(input: input, session: bashSess, workingDirectory: wd), toolName: name)
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
                return .detect(await executeOllamaWebSearchTool(input: input, apiKey: settings.ollamaAPIKey), toolName: name)
            }
            return .detect(await executeWebSearchTool(input: input), toolName: name)
        case "web_fetch":
            return .detect(await executeWebFetchTool(input: input), toolName: name)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(executeMemoryWrite(input: input), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId), toolName: name)
        case "verify_completion":
            return .detect(executeVerifyCompletion(input: input, sessionId: sessionId), toolName: name)
        default:
            return .unknownTool(name)
        }
    }

    // MARK: Bash Session Management

    func getBashSession(for sessionId: String, workingDirectory: String?) -> BashSession {
        if let existing = bashSessions[sessionId] { return existing }
        let newSession = BashSession()
        Task { await newSession.start(workingDirectory: workingDirectory) }
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
        workingDirectory: String?
    ) async -> String {
        if input["restart"]?.boolValue == true {
            await session.restart(workingDirectory: workingDirectory)
            return "Bash session restarted."
        }
        guard let command = input["command"]?.stringValue else {
            return "Error: missing 'command' parameter"
        }
        let timeout: TimeInterval
        if let t = input["timeout"]?.intValue {
            timeout = TimeInterval(max(1, t))
        } else {
            timeout = 300
        }
        let background = input["background"]?.boolValue ?? false
        return await session.execute(command, timeout: timeout, background: background)
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
            let definition = SubagentDefinition.find(named: agentName)
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
