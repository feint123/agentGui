import Foundation

nonisolated enum TerminalExecutionMode: String, Codable, Equatable, Sendable {
    case attached
    case detached

    static let auto: TerminalExecutionMode = .attached
    static let foreground: TerminalExecutionMode = .attached
    static let background: TerminalExecutionMode = .detached
    static let interactive: TerminalExecutionMode = .attached

    static func parse(_ rawValue: String?) -> TerminalExecutionMode? {
        guard let rawValue else { return nil }

        if let mode = TerminalExecutionMode(rawValue: rawValue) {
            return mode
        }

        switch rawValue {
        case "auto", "foreground", "interactive":
            return .attached
        case "background":
            return .detached
        default:
            return nil
        }
    }
}

nonisolated enum TerminalTaskStatus: String, Codable, Equatable, Sendable {
    case launching
    case running
    case waitingForInput
    case planningInteraction
    case awaitingUserApproval
    case userTakeover
    case completed
    case failed
    case interrupted
    case timedOut
    case terminated

    static let queued: TerminalTaskStatus = .launching
    static let classifying: TerminalTaskStatus = .launching
    static let runningForeground: TerminalTaskStatus = .running
    static let waitingForPrompt: TerminalTaskStatus = .waitingForInput
    static let runningBackground: TerminalTaskStatus = .running
    static let needsUserDecision: TerminalTaskStatus = .waitingForInput

    static func parse(_ rawValue: String?) -> TerminalTaskStatus? {
        guard let rawValue else { return nil }

        if let status = TerminalTaskStatus(rawValue: rawValue) {
            return status
        }

        switch rawValue {
        case "queued", "classifying":
            return .launching
        case "runningForeground", "runningBackground":
            return .running
        case "waitingForPrompt", "needsUserDecision":
            return .waitingForInput
        default:
            return nil
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted, .timedOut, .terminated:
            return true
        default:
            return false
        }
    }
}

nonisolated enum TerminalPromptKind: String, Codable, Equatable, Sendable {
    case yesNo
    case singleChoice
    case multiChoice
    case textInput
    case pathInput
    case pressEnter
    case secret
    case destructiveConfirmation
    case unknown
}

nonisolated enum TerminalRiskLevel: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

nonisolated enum TerminalCompletionReason: String, Codable, Equatable, Sendable {
    case exitedZero
    case exitedNonZero
    case terminatedBySignal
    case timedOut
    case cancelledByAgent
    case cancelledByUser
    case runtimeFailure
}

nonisolated enum TerminalTaskEventKind: String, Codable, Equatable, Sendable {
    case output
    case promptDetected
    case plannerDecision
    case agentInput
    case stateChanged
    case backgroundRegistered
    case processExit
    case userDecisionRequested
    case signalSent
}

nonisolated struct TerminalPromptSnapshot: Codable, Equatable, Sendable {
    var kind: TerminalPromptKind
    var promptText: String
    var options: [String]
    var recommendedReply: String?

    var shouldMaskReply: Bool {
        switch kind {
        case .secret:
            return true
        default:
            return false
        }
    }
}

nonisolated struct TerminalTaskSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var sessionId: String
    var command: String
    var shellCommandLine: String?
    var currentWorkingDirectory: String?
    var executionMode: TerminalExecutionMode
    var status: TerminalTaskStatus
    var riskLevel: TerminalRiskLevel
    var pid: Int32?
    var processGroupID: Int32?
    var exitCode: Int32?
    var terminationSignal: Int32?
    var completionReason: TerminalCompletionReason?
    var transcriptPath: String?
    var prompt: TerminalPromptSnapshot?
    var latestOutputSnippet: String?
    var startedAt: Date?
    var endedAt: Date?
    var lastScanAt: Date?

    init(
        id: String,
        sessionId: String,
        command: String,
        shellCommandLine: String? = nil,
        currentWorkingDirectory: String? = nil,
        executionMode: TerminalExecutionMode = .attached,
        status: TerminalTaskStatus = .launching,
        riskLevel: TerminalRiskLevel = .low,
        pid: Int32? = nil,
        processGroupID: Int32? = nil,
        exitCode: Int32? = nil,
        terminationSignal: Int32? = nil,
        completionReason: TerminalCompletionReason? = nil,
        transcriptPath: String? = nil,
        prompt: TerminalPromptSnapshot? = nil,
        latestOutputSnippet: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        lastScanAt: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.command = command
        self.shellCommandLine = shellCommandLine
        self.currentWorkingDirectory = currentWorkingDirectory
        self.executionMode = executionMode
        self.status = status
        self.riskLevel = riskLevel
        self.pid = pid
        self.processGroupID = processGroupID
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.completionReason = completionReason
        self.transcriptPath = transcriptPath
        self.prompt = prompt
        self.latestOutputSnippet = latestOutputSnippet
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastScanAt = lastScanAt
    }
}

extension TerminalTaskSnapshot {
    static func fixture(
        id: String = "task-fixture",
        sessionId: String = "session-fixture",
        command: String = "echo hello",
        shellCommandLine: String? = nil,
        currentWorkingDirectory: String? = nil,
        executionMode: TerminalExecutionMode = .attached,
        status: TerminalTaskStatus = .launching,
        riskLevel: TerminalRiskLevel = .low,
        pid: Int32? = nil,
        processGroupID: Int32? = nil,
        exitCode: Int32? = nil,
        terminationSignal: Int32? = nil,
        completionReason: TerminalCompletionReason? = nil,
        transcriptPath: String? = nil,
        prompt: TerminalPromptSnapshot? = nil,
        latestOutputSnippet: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        lastScanAt: Date? = nil
    ) -> TerminalTaskSnapshot {
        TerminalTaskSnapshot(
            id: id,
            sessionId: sessionId,
            command: command,
            shellCommandLine: shellCommandLine,
            currentWorkingDirectory: currentWorkingDirectory,
            executionMode: executionMode,
            status: status,
            riskLevel: riskLevel,
            pid: pid,
            processGroupID: processGroupID,
            exitCode: exitCode,
            terminationSignal: terminationSignal,
            completionReason: completionReason,
            transcriptPath: transcriptPath,
            prompt: prompt,
            latestOutputSnippet: latestOutputSnippet,
            startedAt: startedAt,
            endedAt: endedAt,
            lastScanAt: lastScanAt
        )
    }
}

nonisolated struct TerminalTaskEvent: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var taskId: String
    var timestamp: Date
    var kind: TerminalTaskEventKind
    var summary: String
    var rawText: String?
    var structuredPayloadJSON: String?

    init(
        id: UUID = UUID(),
        taskId: String,
        timestamp: Date = Date(),
        kind: TerminalTaskEventKind,
        summary: String,
        rawText: String? = nil,
        structuredPayloadJSON: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
        self.rawText = rawText
        self.structuredPayloadJSON = structuredPayloadJSON
    }
}