import Foundation

enum TerminalExecutionMode: String, Codable, Equatable, Sendable {
    case auto
    case foreground
    case background
    case interactive
}

enum TerminalTaskStatus: String, Codable, Equatable, Sendable {
    case queued
    case classifying
    case launching
    case runningForeground
    case waitingForPrompt
    case runningBackground
    case completed
    case failed
    case interrupted
    case timedOut
    case needsUserDecision

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted, .timedOut:
            return true
        default:
            return false
        }
    }
}

enum TerminalPromptKind: String, Codable, Equatable, Sendable {
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

enum TerminalRiskLevel: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

enum TerminalTaskEventKind: String, Codable, Equatable, Sendable {
    case output
    case promptDetected
    case agentInput
    case stateChanged
    case backgroundRegistered
    case processExit
    case userDecisionRequested
    case signalSent
}

struct TerminalPromptSnapshot: Codable, Equatable, Sendable {
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

struct TerminalTaskSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var sessionId: String
    var command: String
    var executionMode: TerminalExecutionMode
    var status: TerminalTaskStatus
    var riskLevel: TerminalRiskLevel
    var prompt: TerminalPromptSnapshot?
    var latestOutputSnippet: String?
    var startedAt: Date?
    var endedAt: Date?
    var lastScanAt: Date?

    init(
        id: String,
        sessionId: String,
        command: String,
        executionMode: TerminalExecutionMode = .auto,
        status: TerminalTaskStatus = .queued,
        riskLevel: TerminalRiskLevel = .low,
        prompt: TerminalPromptSnapshot? = nil,
        latestOutputSnippet: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        lastScanAt: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.command = command
        self.executionMode = executionMode
        self.status = status
        self.riskLevel = riskLevel
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
        executionMode: TerminalExecutionMode = .foreground,
        status: TerminalTaskStatus = .queued,
        riskLevel: TerminalRiskLevel = .low,
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
            executionMode: executionMode,
            status: status,
            riskLevel: riskLevel,
            prompt: prompt,
            latestOutputSnippet: latestOutputSnippet,
            startedAt: startedAt,
            endedAt: endedAt,
            lastScanAt: lastScanAt
        )
    }
}

struct TerminalTaskEvent: Codable, Equatable, Sendable, Identifiable {
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