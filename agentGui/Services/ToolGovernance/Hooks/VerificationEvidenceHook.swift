import Foundation
import SwiftAnthropic

/// Post-execution hook that:
/// 1. Detects test-run bash commands and appends a pass/fail summary to the ToolCall timeline.
/// 2. Detects "all todos done, no tests ran" and injects a verification nudge.
///
/// Registered in `AgentLoopToolExecutionCoordinatorBuilder.buildHookPipeline()`.
struct VerificationEvidenceHook: ToolExecutionHook {

    let hookID = "verification-evidence"

    /// Session this hook instance is scoped to (captured from builder).
    private let sessionID: String

    /// Shared in-memory store; typically held by ClaudeService per session.
    private let evidenceStore: VerificationEvidenceStore

    init(sessionID: String, evidenceStore: VerificationEvidenceStore) {
        self.sessionID = sessionID
        self.evidenceStore = evidenceStore
    }

    // MARK: - ToolExecutionHook

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        .allow  // This hook does not block any tool
    }

    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        switch record.toolName {
        case "bash":
            return await handleBashPostExecute(record: record)
        case "update_todo":
            return await handleTodoPostExecute(record: record)
        default:
            return .passthrough
        }
    }

    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        .propagate  // This hook does not recover from failures
    }

    // MARK: - Branch A: bash test detection

    private func handleBashPostExecute(record: ToolRunRecord) async -> PostExecuteAction {
        guard !record.result.isError else { return .passthrough }

        // Extract the command string from bash input
        guard let commandValue = record.input["command"],
              case .string(let command) = commandValue,
              TestCommandDetector.isTestCommand(command) else {
            return .passthrough
        }

        // Parse the output text
        let output = record.result.text
        let parsed = TestCommandDetector.parseTestOutput(output, command: command)

        // Record to store
        let summary = VerificationEvidenceSummary(
            command: String(command.prefix(200)),
            passCount: parsed.passCount,
            failCount: parsed.failCount,
            failureSummary: parsed.failureSummary,
            exitedZero: parsed.exitedZero,
            capturedAt: Date()
        )
        await evidenceStore.record(summary, sessionID: sessionID)

        // Build attachment label
        let label = TestCommandDetector.formatSummaryLabel(parsed, command: command)
        return .appendAttachment("✔ 验证证据已记录 — \(label)")
    }

    // MARK: - Branch B: todo nudge

    private func handleTodoPostExecute(record: ToolRunRecord) async -> PostExecuteAction {
        guard !record.result.isError else { return .passthrough }

        // Parse todos from input
        let todos = parseTodos(from: record.input)
        guard todos.count >= 3 else { return .passthrough }

        // Check: all done
        let allDone = todos.allSatisfy { $0.status == .done }
        guard allDone else { return .passthrough }

        // Check: no todo title suggests a verification step
        let hasVerificationTodo = todos.contains { item in
            let lower = item.title.lowercased()
            return lower.range(of: #"\b(test|verif|check|assert|validate|run)\b"#,
                               options: .regularExpression) != nil
        }
        guard !hasVerificationTodo else { return .passthrough }

        // Check: no test evidence recorded for this session
        let hasEvidence = await evidenceStore.hasEvidence(for: sessionID)
        guard !hasEvidence else { return .passthrough }

        let nudge = "⚠️ 注意：你已完成 \(todos.count) 个任务，但本次会话没有任何测试运行记录。" +
                    "建议在结束前运行一次测试（如 `xcodebuild test` 或 `swift test`）确认改动无误。"
        return .appendAttachment(nudge)
    }

    // MARK: - Helpers

    private func parseTodos(from input: MessageResponse.Content.Input) -> [TodoItem] {
        guard let itemsValue = input["items"] else { return [] }
        let anyValue = dynamicContentToAny(itemsValue)
        guard
            let array = anyValue as? [[String: Any]],
            let data = try? JSONSerialization.data(withJSONObject: array),
            let items = try? JSONDecoder().decode([TodoItem].self, from: data)
        else { return [] }
        return items
    }
}
