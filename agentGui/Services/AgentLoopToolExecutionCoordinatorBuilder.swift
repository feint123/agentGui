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
                }
            )
        )
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

        return Task { @MainActor in
            var lastPromptText: String?
            var lastOutput = ""
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

                if !liveOutput.isEmpty {
                    record.terminalOutput = liveOutput
                }

                let promptDecision = BashPromptAnalyzer().analyze(output: liveOutput)

                if let promptDecision {
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
                            await registry.appendEvent(
                                TerminalTaskEvent(taskId: taskId, kind: .userDecisionRequested, summary: "等待用户处理终端提示")
                            )
                            let action = await claudeService.requestPromptUserAction(for: promptDecision)
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
                } else {
                    lastPromptText = nil
                    liveSnapshot.prompt = nil
                    if !liveSnapshot.status.isTerminal {
                        liveSnapshot.status = .running
                    }
                    if let summary = firstTerminalSummaryLine(from: liveOutput) {
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
        } else if result.toolCallStatus == .failed {
            record.terminalTaskId = taskId
            record.terminalTaskStatus = TerminalTaskStatus.failed.rawValue
            record.terminalExecutionMode = bashRequest.executionMode.rawValue
            record.terminalPromptSummary = firstTerminalSummaryLine(from: result.text)
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
}