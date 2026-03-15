//
//  ClaudeService+ToolDispatch.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Tool Dispatch

extension ClaudeService {

    private func wrapLargeTextToolResult(
        rawText: String,
        toolName: String,
        sourceKind: LargeTextPayload.SourceKind,
        sourceDescriptor: String,
        settings: AppSettings
    ) async -> ToolExecutionResult {
        let detected = ToolExecutionResult.detect(rawText, toolName: toolName)
        guard !detected.isError else { return detected }

        let decision = toolResultBudgetController.decide(
            rawText: rawText,
            sourceKind: sourceKind,
            roundInjectedChars: 0,
            reservedResponseTokens: settings.enableExtendedThinking ? max(1024, settings.extendedThinkingBudget / 2) : 4096
        )

        let payloadRef: String?
        if decision.shouldPersistPayload {
            payloadRef = try? await toolPayloadStore.createPayload(
                text: rawText,
                sourceKind: sourceKind,
                sourceDescriptor: sourceDescriptor
            ).payloadID
        } else {
            payloadRef = nil
        }

        let envelope = ToolResultEnvelope(
            summary: decision.summary,
            preview: decision.preview,
            payloadRef: payloadRef,
            isTruncated: decision.mode != .inline,
            estimatedChars: rawText.count,
            estimatedTokens: ToolResultEnvelope.estimateTokens(for: rawText),
            retrievalHint: decision.retrievalHint.isEmpty ? nil : decision.retrievalHint,
            sourceKind: sourceKind,
            injectionMode: decision.mode,
            rawCharCount: decision.rawCharCount,
            injectedCharCount: decision.injectedCharCount
        )

        let modelText = decision.mode == .inline ? rawText : envelope.renderForModel()
        return ToolExecutionResult(
            modelText,
            status: detected.status,
            mediaContent: detected.mediaContent,
            rawOutputText: rawText,
            envelope: envelope
        )
    }

    func wrapLargeTextToolResultForTests(
        rawText: String,
        toolName: String,
        sourceKind: LargeTextPayload.SourceKind,
        sourceDescriptor: String,
        settings: AppSettings
    ) async -> ToolExecutionResult {
        await wrapLargeTextToolResult(
            rawText: rawText,
            toolName: toolName,
            sourceKind: sourceKind,
            sourceDescriptor: sourceDescriptor,
            settings: settings
        )
    }

    // MARK: - Dispatch

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
            let raw = await executeTextEditorTool(input: input)
            let descriptor = input["path"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .file, sourceDescriptor: descriptor, settings: settings)
        case "bash":
            let wd = effectiveWorkingDirectory(session: session, settings: settings)
            let bashSess = getBashSession(
                for: sessionId,
                workingDirectory: wd,
                environmentOverrides: settings.proxyConfiguration.bashEnvironmentOverrides
            )
            let raw = await executeBashTool(input: input, session: bashSess, workingDirectory: wd, settings: settings)
            let descriptor = input["command"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .bash, sourceDescriptor: descriptor, settings: settings)
        case "read_tool_payload":
            return .detect(await executeReadToolPayload(input: input), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = skillService?.readSkillContent(name: skillName) {
                return .success(content)
            }
            return .failure("Error: skill '\(skillName)' not found")
        case "update_todo_list":
            return .detect(executeUpdateTodoList(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "web_search":
            if settings.enableOllamaWebSearch && !settings.ollamaAPIKey.isEmpty {
                let raw = await executeOllamaWebSearchTool(input: input, apiKey: settings.ollamaAPIKey, settings: settings)
                let descriptor = input["query"]?.stringValue ?? name
                return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webSearch, sourceDescriptor: descriptor, settings: settings)
            }
            let raw = await executeWebSearchTool(input: input, settings: settings)
            let descriptor = input["query"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webSearch, sourceDescriptor: descriptor, settings: settings)
        case "web_fetch":
            let raw = await executeWebFetchTool(input: input, settings: settings)
            let descriptor = input["url"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webFetch, sourceDescriptor: descriptor, settings: settings)
        case "lsp_definition", "lsp_references", "lsp_hover", "lsp_document_symbols", "lsp_workspace_symbols", "lsp_diagnostics", "lsp_list_servers", "lsp_server_status":
            return .detect(await executeLSPTool(name: name, input: input, settings: settings), toolName: name)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(await executeGovernedMemoryWrite(input: input, session: session, modelContext: modelContext), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "verify_completion":
            return .detect(await executeVerifyCompletion(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        default:
            return .unknownTool(name)
        }
    }

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
            let raw = await executeTextEditorTool(input: input)
            let descriptor = input["path"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .file, sourceDescriptor: descriptor, settings: settings)
        case "bash":
            let bashSess = getBashSession(
                for: sessionId,
                workingDirectory: wd,
                environmentOverrides: settings.proxyConfiguration.bashEnvironmentOverrides
            )
            let raw = await executeBashTool(input: input, session: bashSess, workingDirectory: wd, settings: settings)
            let descriptor = input["command"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .bash, sourceDescriptor: descriptor, settings: settings)
        case "read_tool_payload":
            return .detect(await executeReadToolPayload(input: input), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = skillService?.readSkillContent(name: skillName) {
                return .success(content)
            }
            return .failure("Error: skill '\(skillName)' not found")
        case "update_todo_list":
            return .detect(executeUpdateTodoList(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "web_search":
            if settings.enableOllamaWebSearch && !settings.ollamaAPIKey.isEmpty {
                let raw = await executeOllamaWebSearchTool(input: input, apiKey: settings.ollamaAPIKey, settings: settings)
                let descriptor = input["query"]?.stringValue ?? name
                return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webSearch, sourceDescriptor: descriptor, settings: settings)
            }
            let raw = await executeWebSearchTool(input: input, settings: settings)
            let descriptor = input["query"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webSearch, sourceDescriptor: descriptor, settings: settings)
        case "web_fetch":
            let raw = await executeWebFetchTool(input: input, settings: settings)
            let descriptor = input["url"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .webFetch, sourceDescriptor: descriptor, settings: settings)
        case "lsp_definition", "lsp_references", "lsp_hover", "lsp_document_symbols", "lsp_workspace_symbols", "lsp_diagnostics", "lsp_list_servers", "lsp_server_status":
            return .detect(await executeLSPTool(name: name, input: input, settings: settings), toolName: name)
        case "ask_user_question":
            return .detect(await executeAskUserQuestion(input: input), toolName: name)
        case "analyze_image":
            return await executeAnalyzeImageTool(input: input)
        case "read_pdf":
            return await executeReadPDFTool(input: input)
        case "memory_write":
            return .detect(await executeGovernedMemoryWrite(input: input, session: nil, modelContext: modelContext), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "verify_completion":
            return .detect(await executeVerifyCompletion(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        default:
            return .unknownTool(name)
        }
    }

    private func executeLSPTool(
        name: String,
        input: MessageResponse.Content.Input,
        settings: AppSettings
    ) async -> String {
        guard settings.enableLSPTools else {
            return "Error: LSP tools are disabled in settings"
        }
        guard let facade = makeLSPToolFacade(settings: settings) else {
            return "Error: unable to configure LSP tools"
        }

        switch name {
        case "lsp_list_servers":
            return facade.listServers()
        case "lsp_server_status":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let serverID = input["server_id"]?.stringValue else {
                return "Error: missing parameter 'server_id'"
            }
            return facade.serverStatus(workspaceRoot: workspaceRoot, serverID: serverID)
        case "lsp_diagnostics":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let uri = input["uri"]?.stringValue else {
                return "Error: missing parameter 'uri'"
            }
            return facade.diagnostics(workspaceRoot: workspaceRoot, uri: uri)
        case "lsp_definition", "lsp_references", "lsp_hover":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let serverID = input["server_id"]?.stringValue else {
                return "Error: missing parameter 'server_id'"
            }
            guard let uri = input["uri"]?.stringValue else {
                return "Error: missing parameter 'uri'"
            }
            guard let line = input["line"]?.intValue else {
                return "Error: missing parameter 'line'"
            }
            guard let character = input["character"]?.intValue else {
                return "Error: missing parameter 'character'"
            }

            if let startError = await ensureLSPToolSessionIfNeeded(
                workspaceRoot: workspaceRoot,
                serverID: serverID,
                settings: settings
            ) {
                return startError
            }

            switch name {
            case "lsp_definition":
                return (try? await facade.definition(workspaceRoot: workspaceRoot, serverID: serverID, uri: uri, line: line, character: character))
                    ?? "Error: LSP definition request failed"
            case "lsp_references":
                return (try? await facade.references(workspaceRoot: workspaceRoot, serverID: serverID, uri: uri, line: line, character: character))
                    ?? "Error: LSP references request failed"
            default:
                return (try? await facade.hover(workspaceRoot: workspaceRoot, serverID: serverID, uri: uri, line: line, character: character))
                    ?? "Error: LSP hover request failed"
            }
        case "lsp_document_symbols":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let serverID = input["server_id"]?.stringValue else {
                return "Error: missing parameter 'server_id'"
            }
            guard let uri = input["uri"]?.stringValue else {
                return "Error: missing parameter 'uri'"
            }
            if let startError = await ensureLSPToolSessionIfNeeded(
                workspaceRoot: workspaceRoot,
                serverID: serverID,
                settings: settings
            ) {
                return startError
            }
            return facade.documentSymbols(workspaceRoot: workspaceRoot, serverID: serverID, uri: uri)
        case "lsp_workspace_symbols":
            guard let workspaceRoot = input["workspace_root"]?.stringValue else {
                return "Error: missing parameter 'workspace_root'"
            }
            guard let serverID = input["server_id"]?.stringValue else {
                return "Error: missing parameter 'server_id'"
            }
            guard let query = input["query"]?.stringValue else {
                return "Error: missing parameter 'query'"
            }
            if let startError = await ensureLSPToolSessionIfNeeded(
                workspaceRoot: workspaceRoot,
                serverID: serverID,
                settings: settings
            ) {
                return startError
            }
            return facade.workspaceSymbols(workspaceRoot: workspaceRoot, serverID: serverID, query: query)
        default:
            return "Error: unsupported LSP tool '\(name)'"
        }
    }

    private func executeGovernedMemoryWrite(
        input: MessageResponse.Content.Input,
        session: Session?,
        modelContext _: ModelContext
    ) async -> String {
        guard let rawContent = input["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawContent.isEmpty else {
            return "Error: missing parameter 'content'"
        }

        let mode = input["mode"]?.stringValue?.lowercased() ?? "append"
        let scope = session.map { MemoryScope.session(id: $0.sessionId) } ?? .user
        let now = Date()
        let firstLine = rawContent
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedTitle = firstLine.isEmpty ? "Memory" : String(firstLine.prefix(80))
        let store = RMSInsightStore()

        do {
            let existingInsight: RMSInsight?
            if mode == "overwrite" {
                existingInsight = try store.load(scope: scope).last(where: { insight in
                    insight.summary.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(normalizedTitle)
                })
            } else {
                existingInsight = nil
            }

            let insight = makeMemoryWriteInsight(
                id: existingInsight?.id ?? UUID().uuidString,
                content: rawContent,
                normalizedTitle: normalizedTitle,
                scope: scope,
                updatedAt: now
            )

            try store.upsert(insight)
            let actionDescription = existingInsight == nil ? "inserted" : "updated"
            return "Stored RMS insight (\(actionDescription)): \(normalizedTitle)"
        } catch {
            return "Error: failed to store RMS insight - \(error.localizedDescription)"
        }
    }

    private func makeMemoryWriteInsight(
        id: String,
        content: String,
        normalizedTitle: String,
        scope: MemoryScope,
        updatedAt: Date
    ) -> RMSInsight {
        let lowercased = content.lowercased()
        let appliesWhen = normalizedTitle == "Memory" ? "general" : normalizedTitle

        if lowercased.contains("regress") ||
            lowercased.contains("failed") ||
            lowercased.contains("avoid") ||
            lowercased.contains("instead") {
            return RMSInsight.counterexample(
                id: id,
                summary: content,
                appliesWhen: appliesWhen,
                changesDecision: "avoid repeating the remembered failure mode",
                replacementAction: "Inspect current state before acting",
                evidenceRefs: ["tool:memory_write"],
                scope: scope,
                confidence: 0.8
            )
        }

        if lowercased.contains("run ") ||
            lowercased.contains("use ") ||
            lowercased.contains("inspect ") ||
            lowercased.contains("verify ") ||
            lowercased.contains("rerun") {
            return RMSInsight.tactic(
                id: id,
                summary: content,
                appliesWhen: appliesWhen,
                changesDecision: "prefer this remembered tactic when the same situation recurs",
                evidenceRefs: ["tool:memory_write"],
                scope: scope,
                confidence: 0.8
            )
        }

        return RMSInsight.constraint(
            id: id,
            summary: content,
            appliesWhen: appliesWhen,
            changesDecision: "apply the remembered constraint before taking the next action",
            evidenceRefs: ["tool:memory_write"],
            scope: scope,
            confidence: 0.8
        )
    }

    func ensureLSPServerStartedIfNeeded(
        workspaceRoot: String,
        serverID: String,
        settings: AppSettings
    ) async throws -> Bool {
        guard settings.isLSPAutoStartEffective,
              let manager = lspServerManager else {
            return false
        }

        if let state = manager.state(for: workspaceRoot, serverID: serverID) {
            switch state {
            case .crashed, .failedToLaunch, .stopped:
                _ = try await manager.recoverSessionIfNeeded(workspaceRoot: workspaceRoot, serverID: serverID)
                return true
            case .idle, .starting, .running:
                return false
            }
        }

        _ = try await manager.startSession(workspaceRoot: workspaceRoot, serverID: serverID)
        return true
    }

    func autoStartLSPServerForSelectedFileIfNeeded(
        workingDirectory: String,
        selectedFilePath: String?,
        settings: AppSettings
    ) async {
        _ = try? await ensureWorkspaceLSPState(
            workingDirectory: workingDirectory,
            selectedFilePath: selectedFilePath,
            settings: settings
        )
    }

    func ensureWorkspaceLSPState(
        workingDirectory: String,
        selectedFilePath: String?,
        settings: AppSettings
    ) async throws -> LSPWorkspaceBootstrapResult {
        guard let coordinator = makeLSPWorkspaceCoordinator(settings: settings) else {
            return .empty
        }

        return try await coordinator.bootstrapWorkspace(
            workingDirectory: workingDirectory,
            selectedFilePath: selectedFilePath,
            settings: settings
        )
    }

    private func ensureLSPToolSessionIfNeeded(
        workspaceRoot: String,
        serverID: String,
        settings: AppSettings
    ) async -> String? {
        do {
            _ = try await ensureLSPServerStartedIfNeeded(
                workspaceRoot: workspaceRoot,
                serverID: serverID,
                settings: settings
            )
            return nil
        } catch {
            return "Error: unable to start LSP server '\(serverID)': \(error.localizedDescription)"
        }
    }

    private func makeLSPToolFacade(settings: AppSettings) -> LSPToolFacade? {
        guard let registry = try? LSPServerRegistry(settings: settings) else {
            return nil
        }

        _ = makeOrReuseLSPServerManager(registry: registry)

        return LSPToolFacade(registry: registry, serverManager: lspServerManager)
    }

    func makeLSPWorkspaceCoordinator(settings: AppSettings) -> LSPWorkspaceCoordinator? {
        guard let registry = try? LSPServerRegistry(settings: settings),
              let manager = makeOrReuseLSPServerManager(registry: registry) else {
            return nil
        }

        return LSPWorkspaceCoordinator(
            registry: registry,
            serverManager: manager,
            fileIndexer: LSPProjectFileIndexer()
        )
    }

    @discardableResult
    private func makeOrReuseLSPServerManager(registry: LSPServerRegistry) -> LSPServerManager? {
        if lspServerManager == nil {
            let diagnosticsStore = LSPDiagnosticsStore()
            lspServerManager = LSPServerManager(
                registry: registry,
                diagnosticsStore: diagnosticsStore,
                makeClient: {
                    LSPClient(
                        transport: LSPJSONRPCTransport(),
                        documentStore: LSPDocumentStore(),
                        diagnosticsStore: diagnosticsStore,
                        adapter: GenericLSPServerAdapter()
                    )
                },
                makeSupervisor: {
                    LSPProcessSupervisor(processLauncher: ProcessLSPProcessLauncher())
                }
            )
        }

        return lspServerManager
    }
}
