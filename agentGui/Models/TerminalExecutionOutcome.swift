import Foundation

struct TerminalExecutionOutcome: Codable, Equatable, Sendable {
    var taskId: String
    var exitCode: Int32?
    var terminationSignal: Int32?
    var completionReason: TerminalCompletionReason
    var startedAt: Date?
    var endedAt: Date?
    var transcriptPath: String?
    var finalOutputSnippet: String

    init(
        taskId: String,
        exitCode: Int32?,
        terminationSignal: Int32?,
        completionReason: TerminalCompletionReason,
        startedAt: Date?,
        endedAt: Date?,
        transcriptPath: String?,
        finalOutputSnippet: String
    ) {
        self.taskId = taskId
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.completionReason = completionReason
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcriptPath = transcriptPath
        self.finalOutputSnippet = finalOutputSnippet
    }
}