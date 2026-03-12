import Foundation
import SwiftAnthropic
import SwiftData

@MainActor
struct AgentLoopToolExecutionCoordinatorBuilder {
    let claudeService: ClaudeService
    let service: any AnthropicService
    let modelId: String
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
                startWorkflow: { input in
                    await claudeService.executeStartWorkflowTool(
                        input: input,
                        modelContext: modelContext
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
                populateStoryMemoryAuditFields: { record, agentMessage in
                    claudeService.populateStoryMemoryAuditFields(record: record, from: agentMessage)
                }
            )
        )
    }

    private func startForegroundBashObservation(
        bashRequest: BashToolRequest,
        record: ToolCall
    ) async -> Task<Void, Never>? {
        let workingDirectory = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
        let bashSession = claudeService.getBashSession(
            for: sessionId,
            workingDirectory: workingDirectory,
            environmentOverrides: settings.proxyConfiguration.bashEnvironmentOverrides
        )
        let registry = claudeService.getBashTaskRegistry(for: sessionId)
        let taskId = record.terminalTaskId ?? bashRequest.taskId ?? record.toolCallId
        var snapshot = TerminalTaskSnapshot(
            id: taskId,
            sessionId: sessionId,
            command: bashRequest.command ?? record.title ?? "bash",
            executionMode: bashRequest.executionMode,
            status: .runningForeground,
            startedAt: record.startTime
        )
        await registry.upsert(snapshot)

        return Task { @MainActor in
            var idleDuration: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { break }
                let liveOutput = await bashSession.currentOutput()
                let delta = await bashSession.currentOutputDelta()
                if !liveOutput.isEmpty {
                    record.terminalOutput = liveOutput
                }

                idleDuration = delta.isEmpty ? (idleDuration + 0.1) : 0
                let promptDecision = BashPromptAnalyzer().analyze(output: liveOutput)
                let observation = TerminalTaskObservation(
                    appendedOutput: delta,
                    processIsAlive: await bashSession.isProcessAlive(),
                    idleDuration: idleDuration,
                    promptDecision: promptDecision,
                    didBackgroundLaunch: false,
                    didTimeout: false,
                    exitCode: nil
                )
                let update = BashTaskEventReducer().reduce(previous: snapshot, observation: observation)
                snapshot = update.snapshot
                await registry.upsert(update.snapshot)
                for event in update.events {
                    await registry.appendEvent(event)
                }
                record.terminalTaskId = snapshot.id
                record.terminalTaskStatus = snapshot.status.rawValue
                record.terminalExecutionMode = snapshot.executionMode.rawValue
                record.terminalPromptSummary = snapshot.prompt?.promptText ?? snapshot.latestOutputSnippet
                if let data = try? JSONEncoder().encode(update.events),
                   let json = String(data: data, encoding: .utf8),
                   !json.isEmpty {
                    record.terminalAgentActionsJSON = json
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
            if bashRequest.executionMode == .background && result.status == .success {
                finalSnapshot.status = .runningBackground
            } else if result.toolCallStatus == .failed {
                finalSnapshot.status = .failed
                finalSnapshot.endedAt = Date()
            } else if !(finalSnapshot.status == .waitingForPrompt || finalSnapshot.status == .needsUserDecision) {
                finalSnapshot.status = .completed
                finalSnapshot.endedAt = Date()
            }
            finalSnapshot.latestOutputSnippet = result.text
            await registry.upsert(finalSnapshot)
            record.terminalTaskId = finalSnapshot.id
            record.terminalTaskStatus = finalSnapshot.status.rawValue
            record.terminalExecutionMode = finalSnapshot.executionMode.rawValue
            record.terminalPromptSummary = finalSnapshot.prompt?.promptText ?? firstTerminalSummaryLine(from: result.text)
        }
    }

    private func firstTerminalSummaryLine(from text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}