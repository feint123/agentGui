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
        settings: AppSettings,
        baseResult: ToolExecutionResult? = nil
    ) async -> ToolExecutionResult {
        let detected = baseResult ?? ToolExecutionResult.detect(rawText, toolName: toolName)
        guard !detected.isError else { return detected }

        let decision = toolResultBudgetController.decide(
            rawText: rawText,
            sourceKind: sourceKind,
            roundInjectedChars: 0,
            reservedResponseTokens: settings.enableExtendedThinking ? max(1024, settings.extendedThinkingBudget / 2) : 4096
        )

        let payloadRef: String?
        if decision.shouldPersistPayload {
            do {
                payloadRef = try await toolPayloadStore.createPayload(
                    text: rawText,
                    sourceKind: sourceKind,
                    sourceDescriptor: sourceDescriptor
                ).payloadID
            } catch {
                payloadRef = nil
            }
        } else {
            payloadRef = nil
        }

        let effectiveMode: ToolResultEnvelope.InjectionMode
        let effectiveRetrievalHint: String?
        if decision.mode == .referenced, payloadRef == nil {
            effectiveMode = .preview
            effectiveRetrievalHint = "Inspect summary and preview before retrying the original tool. Payload persistence was unavailable for this result."
        } else {
            effectiveMode = decision.mode
            effectiveRetrievalHint = decision.retrievalHint.isEmpty ? nil : decision.retrievalHint
        }

        let envelope = ToolResultEnvelope(
            summary: decision.summary,
            preview: decision.preview,
            payloadRef: payloadRef,
            isTruncated: effectiveMode != .inline,
            estimatedChars: rawText.count,
            estimatedTokens: ToolResultEnvelope.estimateTokens(for: rawText),
            retrievalHint: effectiveRetrievalHint,
            sourceKind: sourceKind,
            injectionMode: effectiveMode,
            rawCharCount: decision.rawCharCount,
            injectedCharCount: decision.injectedCharCount
        )

        let modelText = effectiveMode == .inline ? rawText : envelope.renderForModel()
        return ToolExecutionResult(
            modelText,
            status: detected.status,
            mediaContent: detected.mediaContent,
            rawOutputText: rawText,
            envelope: envelope,
            changeProposalID: detected.changeProposalID,
            changeProposalState: detected.changeProposalState,
            changeProposalSnapshot: detected.changeProposalSnapshot,
            changeProposalDiffContent: detected.changeProposalDiffContent
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
            let raw = await executeTextEditorTool(
                input: input,
                sessionID: sessionId,
                baseWorkspaceRoot: textEditorBaseWorkspaceRoot(
                    forPath: input["path"]?.stringValue,
                    session: session,
                    settings: settings
                ),
                modelContext: modelContext
            )
            let descriptor = input["path"]?.stringValue ?? name
            return await wrapLargeTextToolResult(
                rawText: raw.text,
                toolName: name,
                sourceKind: .file,
                sourceDescriptor: descriptor,
                settings: settings,
                baseResult: raw
            )
        case "bash":
            let wd = effectiveWorkingDirectory(session: session, settings: settings)
            let runtime = getTerminalTaskRuntime(for: sessionId, workingDirectory: wd)
            let raw = await executeBashTool(input: input, runtime: runtime, workingDirectory: wd)
            let descriptor = input["command"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .bash, sourceDescriptor: descriptor, settings: settings)
        case "read_tool_payload":
            return .detect(await executeReadToolPayload(input: input), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = await skillService?.readSkillContent(name: skillName) {
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
            return .detect(await executeGovernedMemoryWrite(input: input, settings: settings, session: session, modelContext: modelContext), toolName: name)
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
        if !session.workingDirectory.isEmpty { return session.workingDirectory }
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
        let session = sessionForTextEditorExecution(sessionId: sessionId, modelContext: modelContext)
        let wd = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
        switch name {
        case "str_replace_based_edit_tool", "str_replace_editor":
            let raw = await executeTextEditorTool(
                input: input,
                sessionID: sessionId,
                baseWorkspaceRoot: textEditorBaseWorkspaceRoot(
                    forPath: input["path"]?.stringValue,
                    session: session,
                    settings: settings
                ),
                modelContext: modelContext
            )
            let descriptor = input["path"]?.stringValue ?? name
            return await wrapLargeTextToolResult(
                rawText: raw.text,
                toolName: name,
                sourceKind: .file,
                sourceDescriptor: descriptor,
                settings: settings,
                baseResult: raw
            )
        case "bash":
            let runtime = getTerminalTaskRuntime(for: sessionId, workingDirectory: wd)
            let raw = await executeBashTool(input: input, runtime: runtime, workingDirectory: wd)
            let descriptor = input["command"]?.stringValue ?? name
            return await wrapLargeTextToolResult(rawText: raw, toolName: name, sourceKind: .bash, sourceDescriptor: descriptor, settings: settings)
        case "read_tool_payload":
            return .detect(await executeReadToolPayload(input: input), toolName: name)
        case "read_skill":
            guard let skillName = input["name"]?.stringValue else {
                return .missingParameter("name")
            }
            if let content = await skillService?.readSkillContent(name: skillName) {
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
            return .detect(await executeGovernedMemoryWrite(input: input, settings: settings, session: nil, modelContext: modelContext), toolName: name)
        case "create_execution_plan":
            return .detect(executeCreateExecutionPlan(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        case "verify_completion":
            return .detect(await executeVerifyCompletion(input: input, sessionId: sessionId, modelContext: modelContext), toolName: name)
        default:
            return .unknownTool(name)
        }
    }

    private func sessionForTextEditorExecution(sessionId: String, modelContext: ModelContext) -> Session? {
        let targetSessionID = sessionId
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == targetSessionID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func textEditorBaseWorkspaceRoot(
        forPath path: String?,
        session: Session?,
        settings: AppSettings
    ) -> String? {
        if let session, let workingDirectory = effectiveWorkingDirectory(session: session, settings: settings) {
            return workingDirectory
        }
        if !settings.workingDirectory.isEmpty {
            return settings.workingDirectory
        }
        guard let path else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
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
            return (try? await facade.documentSymbols(workspaceRoot: workspaceRoot, serverID: serverID, uri: uri))
                ?? "Error: LSP document symbols request failed"
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

    /// Persists a user- or agent-authored long-term RMS insight through the `memory_write` tool.
    ///
    /// This is the simplified replacement for the older governed memory pipeline.
    /// Instead of routing through admission scoring, background jobs, confirmation,
    /// or archive-only branches, the method performs a direct classification and
    /// store write with a small amount of overwrite behavior.
    ///
    /// Current behavior:
    /// - Reads the required `content` parameter from the tool input.
    /// - Uses the current session scope when available, otherwise falls back to `.user`.
    /// - Supports a lightweight `mode` switch:
    ///   - `append`: always write a new insight ID.
    ///   - `overwrite`: try to find a prior insight in the same scope whose summary starts with the same normalized title.
    /// - Converts raw text into a typed `RMSInsight` via `makeMemoryWriteInsight(...)`.
    /// - Persists the result immediately to `RMSInsightStore`.
    ///
    /// The method returns human-readable tool output rather than throwing because it
    /// is part of tool dispatch and needs to surface a model-friendly success or error message.
    ///
    /// - Parameters:
    ///   - input: Tool arguments supplied by the model, expected to contain at least `content`.
    ///   - settings: App settings providing the active model choice for LLM classification.
    ///   - session: Current active session if the tool is invoked from a bound chat session.
    ///   - modelContext: SwiftData context carried by the tool dispatch path. It is unused here,
    ///     but kept in the signature to match the surrounding tool execution API.
    /// - Returns: A success or error string suitable for the tool result channel.
    private func executeGovernedMemoryWrite(
        input: MessageResponse.Content.Input,
        settings: AppSettings,
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
        guard let service else {
            return "Error: Claude service is not configured"
        }
        let generator = LLMRMSInsightGenerator(service: service, modelId: settings.selectedModel)

        do {
            let existingInsight: RMSInsight?
            if mode == "overwrite" {
                existingInsight = try store.load(scope: scope).last(where: { insight in
                    insight.summary.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(normalizedTitle)
                })
            } else {
                existingInsight = nil
            }

            let insight = try await makeMemoryWriteInsight(
                id: existingInsight?.id ?? UUID().uuidString,
                content: rawContent,
                normalizedTitle: normalizedTitle,
                scope: scope,
                updatedAt: now,
                generator: generator
            )

            try store.upsert(insight)
            let actionDescription = existingInsight == nil ? "inserted" : "updated"
            return "Stored RMS insight (\(actionDescription)): \(normalizedTitle)"
        } catch {
            return "Error: failed to store RMS insight - \(error.localizedDescription)"
        }
    }

    /// Converts raw `memory_write` content into one of the supported `RMSInsight` kinds.
    ///
    /// This method is intentionally heuristic and lightweight. The input is free-form text,
    /// so the classifier looks for a few high-signal phrases to decide whether the memory is:
    /// - a `counterexample`: text describes a regression, failure, avoidance rule, or "do X instead" pattern
    /// - a `tactic`: text describes a reusable action such as run/use/inspect/verify/rerun
    /// - a `constraint`: fallback classification when the content is better treated as a rule or boundary
    ///
    /// Classification priority matters:
    /// 1. Counterexamples are detected first because remembered failure modes are stronger than generic tactics.
    /// 2. Tactics are detected next for reusable action sequences.
    /// 3. Constraints are the default fallback when the text is neither obviously a failure mode nor a tactic.
    ///
    /// The returned insight always includes:
    /// - the provided stable identifier
    /// - the computed scope
    /// - a synthetic provenance reference of `tool:memory_write`
    /// - a default confidence of `0.8`
    ///
    /// - Parameters:
    ///   - id: Insight identifier to preserve on overwrite or create for first insert.
    ///   - content: Raw text to convert into an RMS insight.
    ///   - normalizedTitle: First-line summary extracted from the content and used as a compact applicability hint.
    ///   - scope: Reuse boundary for the stored insight.
    ///   - updatedAt: Timestamp prepared by the caller for this write operation.
    /// - Returns: A typed `RMSInsight` ready for persistence.
    func makeMemoryWriteInsight(
        id: String,
        content: String,
        normalizedTitle: String,
        scope: MemoryScope,
        updatedAt: Date,
        generator: any RMSInsightGenerating
    ) async throws -> RMSInsight {
        var insight = try await generator.generateRequiredInsight(
            id: id,
            content: content,
            normalizedTitle: normalizedTitle,
            scope: scope,
            updatedAt: updatedAt
        )
        insight.rawContentFilePath = try RMSRawContentStore().persistInsightRawContent(content, insightID: id)
        return insight
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
        } else {
            lspServerManager?.updateRegistry(registry)
        }

        return lspServerManager
    }
}
