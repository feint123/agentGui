import Foundation
import SwiftAnthropic
import SwiftData

@MainActor
struct AgentLoopToolExecutionCoordinatorBuilder {
    static let terminalPlannerAutoExecuteThreshold = 0.8

    let claudeService: ClaudeService
    let service: any AnthropicService
    let modelId: String
    let toolApprovalMode: ToolApprovalMode
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext

    func build() -> AgentLoopToolExecutionCoordinator {
        AgentLoopToolExecutionCoordinator(
            dependencies: .init(
                runSubagent: { input, record in
                    await claudeService.executeRunSubagentTool(
                        input: input,
                        toolCallRecord: record,
                        service: service,
                        modelId: modelId,
                        settings: settings,
                        sessionId: sessionId,
                        modelContext: modelContext
                    )
                },
                requestApprovalIfNeeded: { name, input, record in
                    await requestApprovalIfNeeded(
                        toolName: name,
                        input: input,
                        record: record
                    )
                },
                executeTool: { name, input in
                    await claudeService.executeTool(
                        name: name,
                        input: input,
                        settings: settings,
                        sessionId: sessionId,
                        modelContext: modelContext
                    )
                },
                normalizeBashRequest: { input in
                    try claudeService.normalizeBashToolRequest(input: input)
                },
                startForegroundBashObservation: { bashRequest, record in
                    await startForegroundBashObservation(
                        bashRequest: bashRequest,
                        record: record
                    )
                },
                finishBashObservation: { bashRequest, record, result in
                    await finishBashObservation(
                        bashRequest: bashRequest,
                        record: record,
                        result: result
                    )
                },
                hookPipeline: buildHookPipeline()
            )
        )
    }

    private func buildHookPipeline() -> ToolExecutionHookPipeline {
        var hooks: [any ToolExecutionHook] = []

        if let projectionStore = claudeService.changeReviewProjectionStore {
            hooks.append(ChangeReviewHook(projectionStore: projectionStore))
        }

        // F-C4 VerificationEvidenceHook 将在此追加
        // F-C5 PayloadBudgetHook 将在此追加

        return ToolExecutionHookPipeline(hooks: hooks)
    }

    private func requestApprovalIfNeeded(
        toolName: String,
        input: MessageResponse.Content.Input,
        record: ToolCall
    ) async -> ToolExecutionResult? {
        guard requestRequiresApproval(toolName: toolName, input: input) else {
            return nil
        }

        let source = ACPPermissionCenter.RequestSource(
            providerReference: .builtIn,
            providerDisplayName: ConversationExecutionProviderID.builtInAgent.displayName,
            localSessionID: sessionId
        )
        let response = await claudeService.acpPermissionCenter.resolveBuiltInToolApproval(
            toolName: toolName,
            input: input,
            source: source,
            toolCallID: record.toolCallId,
            title: record.title,
            approvalMode: toolApprovalMode
        )

        guard let response else {
            return ToolExecutionResult.permissionDenied("Error: permission approval was cancelled")
        }

        switch response.outcome {
        case .selected:
            return nil
        case .cancelled:
            return ToolExecutionResult.permissionDenied("Error: permission approval was rejected")
        case .other:
            return ToolExecutionResult.permissionDenied("Error: permission approval returned an unsupported outcome")
        }
    }

    private func requestRequiresApproval(
        toolName: String,
        input: MessageResponse.Content.Input
    ) -> Bool {
        toolApprovalMode == .defaultApprovals
            && ACPPermissionPolicyEvaluator.approvalScope(for: toolName, command: input["command"]?.stringValue) != nil
    }

    private func startForegroundBashObservation(
        bashRequest: BashToolRequest,
        record: ToolCall
    ) async -> Task<Void, Never>? {
        let workingDirectory = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
        let runtime = claudeService.getTerminalTaskRuntime(for: sessionId, workingDirectory: workingDirectory)
        let registry = claudeService.getBashTaskRegistry(for: sessionId)
        let taskId = record.terminalTaskId ?? bashRequest.taskId ?? record.toolCallId

        record.terminalTaskId = taskId
        record.terminalTaskStatus = TerminalTaskStatus.launching.rawValue
        record.terminalExecutionMode = bashRequest.executionMode.rawValue

        let observedCommand = bashRequest.command ?? record.title ?? "nil"
        print("[bash-observer] start foreground observation session=\(sessionId) task_id=\(taskId) mode=\(bashRequest.executionMode.rawValue) command=\(observedCommand)")

        return Task { @MainActor in
            var lastPromptText: String?
            var lastOutput = ""
            var lastInteractiveSurfaceFingerprint: String?
            var lastSurfaceDiagnosticKey: String?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { break }

                guard var liveSnapshot = try? await runtime.status(taskId: taskId) else {
                    continue
                }

                let liveOutput = (try? await runtime.readOutput(taskId: taskId, tailLines: 40)) ?? ""
                let delta: String
                if liveOutput.hasPrefix(lastOutput) {
                    delta = String(liveOutput.dropFirst(lastOutput.count))
                } else {
                    delta = liveOutput
                }
                lastOutput = liveOutput

                if !delta.isEmpty {
                    try? await runtime.ingestShellIntegrationOutput(taskId: taskId, output: delta)
                    if let refreshedSnapshot = try? await runtime.status(taskId: taskId) {
                        liveSnapshot = refreshedSnapshot
                    }
                }

                if !liveOutput.isEmpty {
                    record.terminalOutput = liveOutput
                }

                let screenSnapshot = try? await runtime.screenSnapshot(taskId: taskId)
                let projectedSurface = screenSnapshot.map { TerminalSurfaceProjector().project($0, rawANSISnippet: liveOutput) }
                    ?? TerminalSurfaceSnapshot(plainTextFrame: liveOutput, rawANSISnippet: liveOutput)
                let promptDecision = BashPromptAnalyzer().analyze(output: projectedSurface.plainTextFrame)

                if let promptDecision {
                    print("[bash-observer] prompt detected task_id=\(taskId) kind=\(promptDecision.snapshot.kind.rawValue) autoReply=\(promptDecision.shouldAutoReply) prompt=\(promptDecision.snapshot.promptText)")
                    liveSnapshot.status = .waitingForInput
                    liveSnapshot.prompt = promptDecision.snapshot
                    liveSnapshot.latestOutputSnippet = promptDecision.snapshot.promptText
                    if lastPromptText != promptDecision.snapshot.promptText {
                        lastPromptText = promptDecision.snapshot.promptText
                        await registry.appendEvent(
                            TerminalTaskEvent(
                                taskId: taskId,
                                kind: .promptDetected,
                                summary: promptDecision.snapshot.promptText
                            )
                        )

                        if promptDecision.shouldAutoReply,
                           let autoReply = promptDecision.autoReplyText {
                            do {
                                let reply = claudeService.normalizedTerminalReply(autoReply)
                                print("[bash-observer] auto replying prompt task_id=\(taskId) reply=\(autoReply.debugDescription)")
                                try await runtime.sendInput(taskId: taskId, input: reply)
                                liveSnapshot.status = .running
                                liveSnapshot.prompt = nil
                                await registry.appendEvent(
                                    TerminalTaskEvent(taskId: taskId, kind: .agentInput, summary: "已自动回复 \(autoReply)")
                                )
                            } catch {
                                liveSnapshot.status = .failed
                                liveSnapshot.latestOutputSnippet = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            }
                        } else {
                            print("[bash-observer] waiting for prompt user action task_id=\(taskId)")
                            await registry.appendEvent(
                                TerminalTaskEvent(taskId: taskId, kind: .userDecisionRequested, summary: "等待用户处理终端提示")
                            )
                            let action = await claudeService.requestPromptUserAction(for: promptDecision)
                            print("[bash-observer] prompt user action resolved task_id=\(taskId) action=\(String(describing: action))")
                            switch action {
                            case .reply(let replyText):
                                do {
                                    try await runtime.sendInput(taskId: taskId, input: claudeService.normalizedTerminalReply(replyText))
                                    liveSnapshot.status = .running
                                    liveSnapshot.prompt = nil
                                    await registry.appendEvent(
                                        TerminalTaskEvent(taskId: taskId, kind: .agentInput, summary: "已发送用户输入")
                                    )
                                } catch {
                                    liveSnapshot.status = .failed
                                    liveSnapshot.latestOutputSnippet = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                                }
                            case .interrupt:
                                do {
                                    try await runtime.interrupt(taskId: taskId)
                                    liveSnapshot.status = .interrupted
                                    liveSnapshot.prompt = nil
                                    await registry.appendEvent(
                                        TerminalTaskEvent(taskId: taskId, kind: .signalSent, summary: "用户取消了终端命令")
                                    )
                                } catch {
                                    liveSnapshot.status = .failed
                                    liveSnapshot.latestOutputSnippet = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                                }
                            case .wait:
                                await registry.appendEvent(
                                    TerminalTaskEvent(taskId: taskId, kind: .stateChanged, summary: "继续等待终端提示")
                                )
                            }
                        }
                    }
                    lastInteractiveSurfaceFingerprint = nil
                } else {
                    let interactiveFingerprint = Self.interactiveSurfaceFingerprint(for: projectedSurface)
                    let shouldProcessInteractiveSurface = interactiveFingerprint != nil
                        && interactiveFingerprint != lastInteractiveSurfaceFingerprint

                    let surfaceDiagnosticKey = "\(projectedSurface.selectionMode.rawValue)|\(projectedSurface.visibleOptions.count)|\(projectedSurface.plainTextFrame.hashValue)"
                    let surfaceChanged = surfaceDiagnosticKey != lastSurfaceDiagnosticKey
                    if surfaceChanged {
                        lastSurfaceDiagnosticKey = surfaceDiagnosticKey
                        print(
                            "[bash-observer] surface snapshot task_id=\(taskId) selectionMode=\(projectedSurface.selectionMode.rawValue) options=\(projectedSurface.visibleOptions.count) altScreen=\(projectedSurface.isAlternateScreen) preview=\(Self.terminalPreview(projectedSurface.plainTextFrame))"
                        )
                        if projectedSurface.visibleOptions.isEmpty {
                            print("[bash-observer] surface options empty task_id=\(taskId) rawPreview=\(Self.terminalPreview(projectedSurface.rawANSISnippet))")
                        } else {
                            print("[bash-observer] surface options task_id=\(taskId) labels=\(projectedSurface.visibleOptions.map { $0.label }.joined(separator: " | "))")
                        }
                    }

                    if let interactiveFingerprint {
                        print("[bash-observer] interactive surface candidate task_id=\(taskId) fingerprintHash=\(interactiveFingerprint.hashValue) changed=\(shouldProcessInteractiveSurface)")
                    } else if !liveOutput.isEmpty, surfaceChanged {
                        print("[bash-observer] interactive surface not detected task_id=\(taskId) selectionMode=\(projectedSurface.selectionMode.rawValue) options=\(projectedSurface.visibleOptions.count)")
                    }

                    if shouldProcessInteractiveSurface {
                        print("[bash-observer] processing interactive surface task_id=\(taskId)")
                        guard let screenSnapshot else {
                            print("[bash-observer] screen snapshot unavailable task_id=\(taskId)")
                            lastInteractiveSurfaceFingerprint = nil
                            await registry.upsert(liveSnapshot)
                            continue
                        }
                        let handledInteractiveSurface = (try? await Self.processInteractiveTerminalSurfaceForTests(
                            command: bashRequest.command ?? record.title ?? liveSnapshot.command,
                            screenSnapshot: screenSnapshot,
                            liveSnapshot: &liveSnapshot,
                            record: record,
                            runtime: runtime,
                            registry: registry,
                            planner: .deterministicFallback()
                        )) ?? false

                        let interactionPhase = record.terminalInteractionPhase ?? "nil"
                        print("[bash-observer] interactive surface processed task_id=\(taskId) handled=\(handledInteractiveSurface) status=\(liveSnapshot.status.rawValue) phase=\(interactionPhase) approvalPending=\(record.terminalApprovalPending)")

                        if handledInteractiveSurface {
                            lastInteractiveSurfaceFingerprint = interactiveFingerprint
                        } else {
                            lastInteractiveSurfaceFingerprint = nil
                        }
                    } else if interactiveFingerprint == nil {
                        lastInteractiveSurfaceFingerprint = nil
                    }

                    lastPromptText = nil
                    liveSnapshot.prompt = nil
                    if !liveSnapshot.status.isTerminal,
                       liveSnapshot.status != .userTakeover {
                        liveSnapshot.status = .running
                    }
                    if liveSnapshot.status == .running,
                       let summary = firstTerminalSummaryLine(from: liveOutput) {
                        liveSnapshot.latestOutputSnippet = summary
                    }
                }

                await registry.upsert(liveSnapshot)
                if !delta.isEmpty {
                    await registry.appendEvent(
                        TerminalTaskEvent(taskId: taskId, kind: .output, summary: firstTerminalSummaryLine(from: delta) ?? "terminal output", rawText: delta)
                    )
                }

                let events = await registry.events(taskId: taskId)
                record.terminalTaskId = liveSnapshot.id
                record.terminalTaskStatus = liveSnapshot.status.rawValue
                record.terminalExecutionMode = liveSnapshot.executionMode.rawValue
                record.terminalPromptSummary = liveSnapshot.prompt?.promptText ?? liveSnapshot.latestOutputSnippet
                record.terminalTranscriptPath = liveSnapshot.transcriptPath
                record.terminalCompletionReason = liveSnapshot.completionReason?.rawValue
                if let data = try? JSONEncoder().encode(events),
                   let json = String(data: data, encoding: .utf8),
                   !json.isEmpty {
                    record.terminalAgentActionsJSON = json
                }

                if liveSnapshot.status.isTerminal {
                    print("[bash-observer] observation finished task_id=\(taskId) terminalStatus=\(liveSnapshot.status.rawValue)")
                    break
                }
            }
        }
    }

    private func finishBashObservation(
        bashRequest: BashToolRequest,
        record: ToolCall,
        result: ToolExecutionResult
    ) async {
        let registry = claudeService.getBashTaskRegistry(for: sessionId)
        let taskId = record.terminalTaskId ?? bashRequest.taskId ?? record.toolCallId
        if var finalSnapshot = await registry.snapshot(taskId: taskId) {
            if bashRequest.executionMode == .detached && result.status == .success && !finalSnapshot.status.isTerminal {
                finalSnapshot.status = .running
            } else if result.toolCallStatus == .failed && !finalSnapshot.status.isTerminal {
                finalSnapshot.status = .failed
                finalSnapshot.endedAt = Date()
            } else if !finalSnapshot.status.isTerminal {
                finalSnapshot.status = .completed
                finalSnapshot.endedAt = Date()
            }
            finalSnapshot.latestOutputSnippet = result.text
            await registry.upsert(finalSnapshot)
            record.terminalTaskId = finalSnapshot.id
            record.terminalTaskStatus = finalSnapshot.status.rawValue
            record.terminalExecutionMode = finalSnapshot.executionMode.rawValue
            record.terminalPromptSummary = finalSnapshot.prompt?.promptText ?? firstTerminalSummaryLine(from: result.text)
            record.terminalTranscriptPath = finalSnapshot.transcriptPath
            record.terminalCompletionReason = finalSnapshot.completionReason?.rawValue
            if finalSnapshot.status.isTerminal {
                record.terminalApprovalPending = false
                record.terminalUserTakeoverActive = false
            }
        } else if result.toolCallStatus == .failed {
            record.terminalTaskId = taskId
            record.terminalTaskStatus = TerminalTaskStatus.failed.rawValue
            record.terminalExecutionMode = bashRequest.executionMode.rawValue
            record.terminalPromptSummary = firstTerminalSummaryLine(from: result.text)
            record.terminalApprovalPending = false
            record.terminalUserTakeoverActive = false
        }
    }

    private func firstTerminalSummaryLine(from text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    /// Mirrors the production terminal summary heuristic so focused tests can assert it directly.
    static func extractTerminalSummaryForTests(from text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    static func shouldAutoExecuteTerminalPlan(_ plan: TerminalInteractionPlan) -> Bool {
        !plan.requiresUserConfirmation && plan.confidence >= terminalPlannerAutoExecuteThreshold
    }

    static func interactiveSurfaceFingerprint(for output: String) -> String? {
        let screenSnapshot = TerminalScreenSnapshot(
            plainTextLines: output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
            activeBuffer: .primary,
            cursor: .init(),
            width: 80,
            height: 24
        )
        let surface = TerminalSurfaceProjector().project(screenSnapshot, rawANSISnippet: output)
        return interactiveSurfaceFingerprint(for: surface)
    }

    static func interactiveSurfaceFingerprint(for surface: TerminalSurfaceSnapshot) -> String? {
        guard isInteractiveSurface(surface) else {
            return nil
        }

        return surface.plainTextFrame.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func processInteractiveTerminalSurfaceForTests(
        command: String,
        screenSnapshot: TerminalScreenSnapshot,
        liveSnapshot: inout TerminalTaskSnapshot,
        record: ToolCall,
        runtime: TerminalTaskRuntime,
        registry: BashTaskRegistry,
        planner: TerminalInteractionPlanner
    ) async throws -> Bool {
        let surface = TerminalSurfaceProjector().project(screenSnapshot)
        guard isInteractiveSurface(surface) else {
            print("[bash-planner] ignoring non-interactive surface command=\(command)")
            return false
        }

        let optionsSummary = surface.visibleOptions.map { $0.label }.joined(separator: " | ")
        let focusedIndex = surface.focusedOptionIndex.map(String.init) ?? "nil"
        print("[bash-planner] extracted surface task_id=\(liveSnapshot.id) selectionMode=\(surface.selectionMode.rawValue) options=\(optionsSummary) focusedIndex=\(focusedIndex) altScreen=\(surface.isAlternateScreen)")

        liveSnapshot.status = .planningInteraction
        record.terminalInteractionPhase = TerminalInteractionPhase.planning.rawValue
        record.terminalApprovalPending = false
        record.terminalUserTakeoverActive = false

        let plan = try await planner.plan(
            goal: command,
            command: command,
            surface: surface,
            recentOutput: surface.plainTextFrame
        )

        let planJSON: String?
        if let data = try? JSONEncoder().encode(plan) {
            planJSON = String(data: data, encoding: .utf8)
        } else {
            planJSON = nil
        }

        let plannerSummary = plan.reasoningSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? plan.intentSummary
            : plan.reasoningSummary

        print("[bash-planner] plan ready task_id=\(liveSnapshot.id) interactionType=\(plan.interactionType) confidence=\(plan.confidence) requiresConfirmation=\(plan.requiresUserConfirmation) actions=\(terminalActionSummary(plan.nextActions)) summary=\(plannerSummary)")

        await registry.appendEvent(
            TerminalTaskEvent(
                taskId: liveSnapshot.id,
                kind: .plannerDecision,
                summary: plannerSummary,
                rawText: surface.plainTextFrame,
                structuredPayloadJSON: planJSON
            )
        )

        if shouldAutoExecuteTerminalPlan(plan) {
            print("[bash-planner] auto executing plan task_id=\(liveSnapshot.id)")
            try await runtime.applyInteractionActions(taskId: liveSnapshot.id, actions: plan.nextActions)
            liveSnapshot.status = .running
            liveSnapshot.latestOutputSnippet = plannerSummary
            record.terminalInteractionPhase = TerminalInteractionPhase.autoExecuting.rawValue
            record.terminalPlannerSummary = plannerSummary
            record.terminalPromptSummary = plannerSummary
            record.terminalApprovalPending = false
            await registry.appendEvent(
                TerminalTaskEvent(
                    taskId: liveSnapshot.id,
                    kind: .agentInput,
                    summary: "已执行交互计划: \(terminalActionSummary(plan.nextActions))",
                    structuredPayloadJSON: planJSON
                )
            )
        } else {
            print("[bash-planner] plan requires direct user takeover task_id=\(liveSnapshot.id)")
            liveSnapshot.status = .userTakeover
            liveSnapshot.latestOutputSnippet = plannerSummary
            record.terminalInteractionPhase = TerminalInteractionPhase.userTakeover.rawValue
            record.terminalPlannerSummary = plannerSummary
            record.terminalPromptSummary = plannerSummary
            record.terminalApprovalPending = false
            record.terminalUserTakeoverActive = true
            await registry.appendEvent(
                TerminalTaskEvent(
                    taskId: liveSnapshot.id,
                    kind: .stateChanged,
                    summary: "终端任务已交给用户接管",
                    structuredPayloadJSON: planJSON
                )
            )
        }

        await registry.upsert(liveSnapshot)
        record.terminalTaskId = liveSnapshot.id
        record.terminalTaskStatus = liveSnapshot.status.rawValue
        record.terminalExecutionMode = liveSnapshot.executionMode.rawValue
        return true
    }

    private static func isInteractiveSurface(_ surface: TerminalSurfaceSnapshot) -> Bool {
        surface.selectionMode == .singleSelect
            || surface.selectionMode == .multiSelect
            || surface.selectionMode == .textInput
            || surface.inputHint == "viewer_navigation"
    }

    private static func terminalActionSummary(_ actions: [TerminalInteractionAction]) -> String {
        actions.map { action in
            switch action {
            case .key(let key):
                return key.rawValue
            case .text(let text):
                return "text:\(text)"
            case .wait(let milliseconds):
                return "wait:\(milliseconds)ms"
            case .signal(let signal):
                return signal.rawValue
            }
        }
        .joined(separator: ", ")
    }

    private static func terminalPreview(_ text: String, limit: Int = 240) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }

}