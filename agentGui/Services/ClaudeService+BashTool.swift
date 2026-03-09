//
//  ClaudeService+BashTool.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

enum TerminalSignal: String, Sendable {
    case interrupt
    case terminate
}

enum TerminalScanPolicy: String, Sendable {
    case adaptive
    case manual
}

enum TerminalAutoReplyPolicy: String, Sendable {
    case safeOnly
    case disabled
}

enum BashToolRequestError: LocalizedError {
    case invalidExecutionMode(String)
    case invalidSignal(String)
    case invalidScanPolicy(String)
    case invalidAutoReplyPolicy(String)

    var errorDescription: String? {
        switch self {
        case .invalidExecutionMode(let value):
            return "Error: invalid execution_mode '\(value)'"
        case .invalidSignal(let value):
            return "Error: invalid signal '\(value)'"
        case .invalidScanPolicy(let value):
            return "Error: invalid scan_policy '\(value)'"
        case .invalidAutoReplyPolicy(let value):
            return "Error: invalid auto_reply_policy '\(value)'"
        }
    }
}

struct BashToolRequest: Equatable, Sendable {
    var command: String?
    var taskId: String?
    var executionMode: TerminalExecutionMode
    var input: String?
    var signal: TerminalSignal?
    var goalHint: String?
    var scanPolicy: TerminalScanPolicy
    var autoReplyPolicy: TerminalAutoReplyPolicy
    var timeout: TimeInterval?
    var restart: Bool
}

enum TerminalPromptUserAction: Equatable, Sendable {
    case reply(String)
    case interrupt
    case wait
}

extension ClaudeService {

    // MARK: - Bash Tool

    func executeBashTool(
        input: MessageResponse.Content.Input,
        session: BashSession,
        workingDirectory: String?,
        settings: AppSettings
    ) async -> String {
        let request: BashToolRequest
        do {
            request = try normalizeBashToolRequest(input: input)
        } catch {
            return error.localizedDescription
        }

        let environmentOverrides = settings.proxyConfiguration.bashEnvironmentOverrides
        if request.restart {
            await session.restart(
                workingDirectory: workingDirectory,
                environmentOverrides: environmentOverrides
            )
            return "Bash session restarted."
        }

        let timeout: TimeInterval
        if let t = request.timeout {
            timeout = TimeInterval(max(1, t))
        } else {
            timeout = request.executionMode == .interactive ? 2 : 300
        }

        if let signal = request.signal {
            switch signal {
            case .interrupt:
                return await session.interrupt(timeout: timeout)
            case .terminate:
                await session.terminateCurrentCommand()
                return "Foreground bash command terminated."
            }
        }

        if let followUpInput = request.input {
            let output = await session.sendInput(followUpInput, timeout: timeout)
            return await resolveInteractivePromptIfNeeded(
                output: output,
                request: request,
                session: session,
                timeout: timeout
            )
        }

        guard let command = request.command else {
            return "Error: missing 'command' parameter"
        }

        let background = request.executionMode == .background
        let interactive = request.executionMode == .interactive
        let output = await session.execute(command, timeout: timeout, background: background, interactive: interactive)
        guard interactive else { return output }

        return await resolveInteractivePromptIfNeeded(
            output: output,
            request: request,
            session: session,
            timeout: timeout
        )
    }

    func normalizeBashToolRequest(input: MessageResponse.Content.Input) throws -> BashToolRequest {
        let command = input["command"]?.stringValue
        let taskId = input["task_id"]?.stringValue
        let followUpInput = input["input"]?.stringValue
        let goalHint = input["goal_hint"]?.stringValue
        let restart = input["restart"]?.boolValue ?? false
        let timeout = input["timeout"]?.intValue.map(TimeInterval.init)
        let legacyBackground = input["background"]?.boolValue ?? false
        let legacyInteractive = input["interactive"]?.boolValue ?? false
        let legacyInterrupt = input["interrupt"]?.boolValue ?? false

        let explicitExecutionMode: TerminalExecutionMode?
        if let rawMode = input["execution_mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawMode.isEmpty {
            guard let mode = TerminalExecutionMode(rawValue: rawMode) else {
                throw BashToolRequestError.invalidExecutionMode(rawMode)
            }
            explicitExecutionMode = mode
        } else {
            explicitExecutionMode = nil
        }

        let explicitSignal: TerminalSignal?
        if let rawSignal = input["signal"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawSignal.isEmpty {
            guard let signal = TerminalSignal(rawValue: rawSignal) else {
                throw BashToolRequestError.invalidSignal(rawSignal)
            }
            explicitSignal = signal
        } else {
            explicitSignal = nil
        }

        let scanPolicy: TerminalScanPolicy
        if let rawScanPolicy = input["scan_policy"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawScanPolicy.isEmpty {
            guard let parsed = TerminalScanPolicy(rawValue: rawScanPolicy) else {
                throw BashToolRequestError.invalidScanPolicy(rawScanPolicy)
            }
            scanPolicy = parsed
        } else {
            scanPolicy = .adaptive
        }

        let autoReplyPolicy: TerminalAutoReplyPolicy
        if let rawAutoReplyPolicy = input["auto_reply_policy"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAutoReplyPolicy.isEmpty {
            guard let parsed = TerminalAutoReplyPolicy(rawValue: rawAutoReplyPolicy) else {
                throw BashToolRequestError.invalidAutoReplyPolicy(rawAutoReplyPolicy)
            }
            autoReplyPolicy = parsed
        } else {
            autoReplyPolicy = .safeOnly
        }

        let resolvedSignal = explicitSignal ?? (legacyInterrupt ? .interrupt : nil)
        let resolvedExecutionMode = try resolvedExecutionMode(
            explicitMode: explicitExecutionMode,
            command: command,
            goalHint: goalHint,
            hasFollowUpInput: followUpInput != nil,
            legacyBackground: legacyBackground,
            legacyInteractive: legacyInteractive
        )

        return BashToolRequest(
            command: command,
            taskId: taskId,
            executionMode: resolvedExecutionMode,
            input: followUpInput,
            signal: resolvedSignal,
            goalHint: goalHint,
            scanPolicy: scanPolicy,
            autoReplyPolicy: autoReplyPolicy,
            timeout: timeout,
            restart: restart
        )
    }

    private func resolvedExecutionMode(
        explicitMode: TerminalExecutionMode?,
        command: String?,
        goalHint: String?,
        hasFollowUpInput: Bool,
        legacyBackground: Bool,
        legacyInteractive: Bool
    ) throws -> TerminalExecutionMode {
        if let explicitMode {
            return explicitMode
        }

        if legacyBackground {
            return .background
        }

        if legacyInteractive || hasFollowUpInput {
            return .interactive
        }

        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .foreground
        }

        let classification = BashCommandClassifier().classify(command: command, goalHint: goalHint)
        switch classification.executionMode {
        case .auto:
            return shouldAutoEnableInteractiveMode(for: command) ? .interactive : .foreground
        default:
            return classification.executionMode
        }
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

    private func resolveInteractivePromptIfNeeded(
        output: String,
        request: BashToolRequest,
        session: BashSession,
        timeout: TimeInterval,
        remainingRounds: Int = 4
    ) async -> String {
        guard remainingRounds > 0 else {
            return joinedOutput([
                output,
                "[Managed bash] Prompt handling limit reached. Further input requires another bash tool call."
            ])
        }

        guard let decision = BashPromptAnalyzer().analyze(output: output) else {
            return output
        }

        if request.autoReplyPolicy == .safeOnly,
           decision.shouldAutoReply,
           let reply = decision.autoReplyText {
            let nextOutput = await session.sendInput(reply, timeout: timeout)
            let autoReplySummary = reply.isEmpty
                ? "[Managed bash] Auto-replied by pressing Enter."
                : "[Managed bash] Auto-replied with '\(reply)'."

            let resolvedNext = await resolveInteractivePromptIfNeeded(
                output: nextOutput,
                request: request,
                session: session,
                timeout: timeout,
                remainingRounds: remainingRounds - 1
            )

            return joinedOutput([output, autoReplySummary, resolvedNext])
        }

        let action = await askUserToResolvePrompt(decision: decision)
        switch action {
        case .reply(let reply):
            let nextOutput = await session.sendInput(reply, timeout: timeout)
            let resolvedNext = await resolveInteractivePromptIfNeeded(
                output: nextOutput,
                request: request,
                session: session,
                timeout: timeout,
                remainingRounds: remainingRounds - 1
            )
            return joinedOutput([output, "[Managed bash] User replied with '\(reply)'.", resolvedNext])
        case .interrupt:
            let interruptOutput = await session.interrupt(timeout: timeout)
            return joinedOutput([output, "[Managed bash] User chose to cancel the command.", interruptOutput])
        case .wait:
            return joinedOutput([output, "[Managed bash] Prompt left waiting for manual follow-up input."])
        }
    }

    private func askUserToResolvePrompt(decision: TerminalPromptDecision) async -> TerminalPromptUserAction {
        let questions = makeAskUserQuestions(for: decision)
        let input: MessageResponse.Content.Input = [
            "questions": .array(questions.map(dynamicContentQuestion(from:)))
        ]
        let response = await executeAskUserQuestion(input: input)
        return resolvePromptUserAction(from: response, decision: decision)
    }

    private func dynamicContentQuestion(from question: AskUserQuestion) -> MessageResponse.Content.DynamicContent {
        .dictionary([
            "question": .string(question.question),
            "header": .string(question.header),
            "options": .array(question.options.map { option in
                .dictionary([
                    "label": .string(option.label),
                    "description": .string(option.description)
                ])
            }),
            "multiSelect": .bool(question.multiSelect)
        ])
    }

    private func joinedOutput(_ segments: [String]) -> String {
        segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Interactive Mode Detection

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
}
