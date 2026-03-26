//
//  ClaudeService+BashTool.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

enum TerminalSignal: String, Codable, Sendable {
    case interrupt
    case terminate
}

enum BashToolOperation: String, Equatable, Sendable {
    case start
    case sendInput = "send_input"
    case interrupt
    case terminate
    case status
    case readOutput = "read_output"
    case cleanup
}

struct BashToolOperationRequest: Equatable, Sendable {
    var operation: BashToolOperation
    var taskId: String?
    var command: String?
    var executionMode: TerminalExecutionMode
    var input: String?
    var timeout: TimeInterval?
    var force: Bool
    var tailLines: Int?
}

struct BashToolRequest: Equatable, Sendable {
    var command: String?
    var taskId: String?
    var executionMode: TerminalExecutionMode
    var input: String?
    var signal: TerminalSignal?
    var timeout: TimeInterval?
}

enum TerminalPromptUserAction: Equatable, Sendable {
    case reply(String)
    case interrupt
    case wait
}

extension ClaudeService {

    func requestPromptUserAction(for decision: TerminalPromptDecision) async -> TerminalPromptUserAction {
        let questions = makeAskUserQuestions(for: decision)
        let sessionID = activeBuiltInSessionID
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let request = AskUserQuestionRequest(
                questions: questions,
                continuation: continuation
            )
            self.publishPendingUserQuestion(request, for: sessionID)
        }
        clearPendingUserQuestion(for: sessionID)
        return resolvePromptUserAction(from: response, decision: decision)
    }

    func stopManagedTerminalTask(toolCall: ToolCall, modelContext: ModelContext?) async {
        guard let taskId = toolCall.terminalTaskId,
              let sessionId = toolCall.terminalSessionID else {
            return
        }

        let runtime = getTerminalTaskRuntime(for: sessionId, workingDirectory: nil)
        do {
            try await runtime.interrupt(taskId: taskId)
            let registry = getBashTaskRegistry(for: sessionId)
            await registry.updateStatus(taskId: taskId, status: .interrupted, endedAt: Date())
            await registry.appendEvent(
                TerminalTaskEvent(taskId: taskId, kind: .signalSent, summary: "已手动停止")
            )

            toolCall.status = .cancelled
            toolCall.terminalTaskStatus = TerminalTaskStatus.interrupted.rawValue
            toolCall.terminalPromptSummary = "已手动停止"
            toolCall.endTime = Date()
            try? modelContext?.save()
        } catch {
            toolCall.terminalPromptSummary = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func applyManagedTerminalActions(
        toolCall: ToolCall,
        actions: [TerminalInteractionAction],
        modelContext: ModelContext?
    ) async {
        guard let taskId = toolCall.terminalTaskId,
              let sessionId = toolCall.terminalSessionID else {
            return
        }

        let runtime = getTerminalTaskRuntime(for: sessionId, workingDirectory: nil)
        let registry = getBashTaskRegistry(for: sessionId)

        do {
            try await runtime.applyInteractionActions(taskId: taskId, actions: actions)
            await registry.appendEvent(
                TerminalTaskEvent(
                    taskId: taskId,
                    kind: .agentInput,
                    summary: "用户接管输入: \(actions.map(terminalActionLabel).joined(separator: ", "))"
                )
            )

            toolCall.status = .inProgress
            toolCall.terminalTaskStatus = TerminalTaskStatus.userTakeover.rawValue
            toolCall.terminalInteractionPhase = TerminalInteractionPhase.userTakeover.rawValue
            toolCall.terminalUserTakeoverActive = true
            toolCall.terminalApprovalPending = false
            try? modelContext?.save()
        } catch {
            toolCall.terminalPromptSummary = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func terminalActionLabel(_ action: TerminalInteractionAction) -> String {
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

    func executeBashTool(
        input: MessageResponse.Content.Input,
        runtime: TerminalTaskRuntime,
        workingDirectory: String?
    ) async -> String {
        let request: BashToolOperationRequest
        do {
            request = try parseBashToolOperationRequest(input: input)
        } catch {
            print("[bash-tool] parse failed error=\(error.localizedDescription)")
            return error.localizedDescription
        }

        print("[bash-tool] execute operation=\(request.operation.rawValue) task_id=\(request.taskId ?? "nil") command=\(request.command ?? "nil") mode=\(request.executionMode.rawValue)")

        do {
            switch request.operation {
            case .start:
                let taskId = request.taskId ?? UUID().uuidString
                guard let command = request.command else {
                    return BashToolOperationRouterError.missingCommand.localizedDescription
                }

                if request.executionMode == .detached {
                    let snapshot = try await runtime.startDetached(command: command, taskId: taskId, workingDirectory: workingDirectory)
                    print("[bash-tool] start detached created task_id=\(snapshot.id) status=\(snapshot.status.rawValue)")
                    return "Started detached task \(snapshot.id)"
                }

                let outcome = try await runtime.startAttached(command: command, taskId: taskId, workingDirectory: workingDirectory)
                print("[bash-tool] start attached finished task_id=\(taskId) completion=\(outcome.completionReason.rawValue)")
                return outcome.finalOutputSnippet
            case .sendInput:
                guard let taskId = request.taskId, let input = request.input else {
                    return BashToolOperationRouterError.missingTaskID(.sendInput).localizedDescription
                }
                try await runtime.sendInput(taskId: taskId, input: input)
                print("[bash-tool] send_input task_id=\(taskId) chars=\(input.count)")
                return try await runtime.readOutput(taskId: taskId, tailLines: request.tailLines ?? 20)
            case .interrupt:
                guard let taskId = request.taskId else {
                    return BashToolOperationRouterError.missingTaskID(.interrupt).localizedDescription
                }
                try await runtime.interrupt(taskId: taskId)
                print("[bash-tool] interrupt task_id=\(taskId)")
                return "Interrupted task \(taskId)"
            case .terminate:
                guard let taskId = request.taskId else {
                    return BashToolOperationRouterError.missingTaskID(.terminate).localizedDescription
                }
                try await runtime.terminate(taskId: taskId, force: request.force)
                print("[bash-tool] terminate task_id=\(taskId) force=\(request.force)")
                return request.force ? "Force terminated task \(taskId)" : "Terminated task \(taskId)"
            case .status:
                guard let taskId = request.taskId else {
                    return BashToolOperationRouterError.missingTaskID(.status).localizedDescription
                }
                let snapshot = try await runtime.status(taskId: taskId)
                print("[bash-tool] status task_id=\(taskId) found status=\(snapshot.status.rawValue) session=\(snapshot.sessionId)")
                return "Task \(snapshot.id): \(snapshot.status.rawValue)"
            case .readOutput:
                guard let taskId = request.taskId else {
                    return BashToolOperationRouterError.missingTaskID(.readOutput).localizedDescription
                }
                print("[bash-tool] read_output task_id=\(taskId) tail_lines=\(request.tailLines ?? 20)")
                return try await runtime.readOutput(taskId: taskId, tailLines: request.tailLines ?? 20)
            case .cleanup:
                guard let taskId = request.taskId else {
                    return BashToolOperationRouterError.missingTaskID(.cleanup).localizedDescription
                }
                try await runtime.cleanup(taskId: taskId)
                print("[bash-tool] cleanup task_id=\(taskId)")
                return "Cleaned up task \(taskId)"
            }
        } catch {
            print("[bash-tool] operation=\(request.operation.rawValue) task_id=\(request.taskId ?? "nil") failed error=\(error.localizedDescription)")
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func parseBashToolOperationRequest(input: MessageResponse.Content.Input) throws -> BashToolOperationRequest {
        try BashToolOperationRouter().parse(input: input)
    }

    func normalizeBashToolRequest(input: MessageResponse.Content.Input) throws -> BashToolRequest {
        let operationRequest = try parseBashToolOperationRequest(input: input)
        let signal: TerminalSignal?

        switch operationRequest.operation {
        case .interrupt:
            signal = .interrupt
        case .terminate:
            signal = .terminate
        default:
            signal = nil
        }

        return BashToolRequest(
            command: operationRequest.command,
            taskId: operationRequest.taskId,
            executionMode: operationRequest.executionMode,
            input: operationRequest.input,
            signal: signal,
            timeout: operationRequest.timeout
        )
    }

    func makeAskUserQuestions(for decision: TerminalPromptDecision) -> [AskUserQuestion] {
        let options: [AskUserQuestionOption]

        switch decision.snapshot.kind {
        case .secret:
            options = [
                AskUserQuestionOption(label: "Cancel command", description: "Send Ctrl-C and stop waiting for this prompt"),
                AskUserQuestionOption(label: "Keep waiting", description: "Leave the command running and return control without replying")
            ]
        default:
            let promptOptions = decision.snapshot.options.isEmpty
                ? ["Cancel command", "Keep waiting"]
                : decision.snapshot.options

            options = promptOptions.map { option in
                let description: String
                if option == decision.snapshot.recommendedReply {
                    description = "Recommended by the bash prompt policy"
                } else if option == "Cancel command" {
                    description = "Interrupt the current foreground command"
                } else if option == "Keep waiting" {
                    description = "Leave the command running and return control"
                } else {
                    description = "Reply with '\(option)' to the current bash prompt"
                }

                return AskUserQuestionOption(label: option, description: description)
            }
        }

        return [
            AskUserQuestion(
                question: decision.snapshot.promptText,
                header: "Bash Prompt",
                options: options,
                multiSelect: false
            )
        ]
    }

    func resolvePromptUserAction(from responseJSON: String, decision: TerminalPromptDecision) -> TerminalPromptUserAction {
        struct AskUserAnswerPayload: Decodable {
            struct Answer: Decodable {
                let selected: [String]
            }

            let answers: [Answer]
        }

        guard
            let data = responseJSON.data(using: .utf8),
            let payload = try? JSONDecoder().decode(AskUserAnswerPayload.self, from: data),
            let firstSelection = payload.answers.first?.selected.first
        else {
            return .wait
        }

        if firstSelection == "Cancel command" {
            return .interrupt
        }

        if firstSelection == "Keep waiting" {
            return .wait
        }

        return .reply(firstSelection)
    }

    func normalizedTerminalReply(_ reply: String) -> String {
        if reply.isEmpty {
            return "\n"
        }
        return reply.hasSuffix("\n") ? reply : reply + "\n"
    }
}
