//
//  ClaudeService+ContextCompression.swift
//  agentGui
//
//  Compresses old messages into two complementary memory structures:
//
//  ContextMemory (in-memory) — injected into the live context window:
//    用户目标 / 已完成动作 / 未完成动作 / 关键文件路径 / 失败与约束 / 语义事实
//
//  TaskMemory (persistent) — stored as unified session-scoped memory records:
//    confirmedFacts / attemptedActions / failedAttempts / pendingQuestions / verificationStatus
//

import Foundation
import SwiftAnthropic

// MARK: - ContextMemory

/// Structured hierarchical memory produced by context compression.
/// Replaces the flat "整段摘要" approach with distinct, independently updatable layers.
struct ContextMemory {
    var userGoal: String = ""
    var completedActions: [String] = []
    var pendingActions: [String] = []
    var keyFilesAndPaths: [String] = []
    var failuresAndConstraints: [String] = []
    var semanticFacts: [String] = []

    var isEmpty: Bool {
        userGoal.isEmpty && completedActions.isEmpty && pendingActions.isEmpty
            && keyFilesAndPaths.isEmpty && failuresAndConstraints.isEmpty && semanticFacts.isEmpty
    }

    /// Merge a newer snapshot into this memory.
    /// Goal takes the newer value; pending replaces if the newer set is non-empty;
    /// completed / files / failures / facts accumulate with deduplication.
    mutating func merge(with newer: ContextMemory) {
        if !newer.userGoal.isEmpty { userGoal = newer.userGoal }
        completedActions = contextMemoryDeduped(completedActions + newer.completedActions)
        if !newer.pendingActions.isEmpty { pendingActions = newer.pendingActions }
        keyFilesAndPaths = contextMemoryDeduped(keyFilesAndPaths + newer.keyFilesAndPaths)
        failuresAndConstraints = contextMemoryDeduped(failuresAndConstraints + newer.failuresAndConstraints)
        semanticFacts = contextMemoryDeduped(semanticFacts + newer.semanticFacts)
    }

    /// Renders the memory as structured text for injection into the conversation.
    func toPromptText() -> String {
        var parts: [String] = []
        if !userGoal.isEmpty {
            parts.append("## 用户目标\n\(userGoal)")
        }
        if !completedActions.isEmpty {
            parts.append("## 已完成动作\n" + completedActions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !pendingActions.isEmpty {
            parts.append("## 未完成动作\n" + pendingActions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !keyFilesAndPaths.isEmpty {
            parts.append("## 关键文件/路径\n" + keyFilesAndPaths.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !failuresAndConstraints.isEmpty {
            parts.append("## 失败与约束\n" + failuresAndConstraints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !semanticFacts.isEmpty {
            parts.append("## 语义事实\n" + semanticFacts.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Order-preserving deduplication helper for ContextMemory arrays.
private func contextMemoryDeduped(_ array: [String]) -> [String] {
    var seen = Set<String>()
    return array.filter { seen.insert($0).inserted }
}

// MARK: - ClaudeService Extension

extension ClaudeService {

    // MARK: - Constants

    /// Compression fires when input token usage exceeds this fraction of the context window.
    private static let compressionThreshold: Double = 0.7;

    /// Number of most-recent messages to keep verbatim after compression.
    private static let recentMessageCount: Int = 6

    // MARK: - Public API

    /// Checks whether context usage is above the threshold and, if so, compresses the
    /// message history in-place using hierarchical memory extraction.
    /// Also extracts structured TaskMemory and persists it into unified memory.
    /// Safe to call even when `currentInputTokens == 0`.
    func compressIfNeeded(
        messages: inout [MessageParameter.Message],
        memory: inout ContextMemory,
        service: any AnthropicService,
        modelId: String,
        sessionId: String = ""
    ) async {
        guard currentInputTokens > 0,
              contextUsageRatio > Self.compressionThreshold,
              messages.count > Self.recentMessageCount + 2 else { return }

        let cutoff = messages.count - Self.recentMessageCount
        let oldMessages = Array(messages[..<cutoff])
        let recentMessages = Array(messages[cutoff...])

        print("Context compression triggered: \(currentInputTokens) tokens (\(Int(contextUsageRatio * 100))%), compressing \(oldMessages.count) messages → hierarchical memory + \(recentMessages.count) recent")

        // Take value copies before entering async-let concurrent scope to satisfy
        // Swift 6 strict-concurrency rules (inout params may not be captured).
        let memorySnapshot = memory
        let unifiedStore = UnifiedMemoryFileStoreAdapter()
        let existingTaskMemoryText = sessionId.isEmpty ? nil : (try? taskMemoryPromptText(sessionId: sessionId, store: unifiedStore))

        // Run both extractions concurrently.
        async let contextExtraction = buildHierarchicalMemory(
            from: oldMessages,
            existing: memorySnapshot,
            service: service,
            modelId: modelId
        )
        async let taskExtraction = buildTaskMemory(
            from: oldMessages,
            existingPromptText: existingTaskMemoryText,
            service: service,
            modelId: modelId
        )

        let (extractedContext, extractedTask) = await (contextExtraction, taskExtraction)

        guard let extracted = extractedContext else {
            print("Context compression: extraction failed, skipping")
            return
        }

        memory.merge(with: extracted)

        // Persist task memory into the unified store (fire-and-forget on success; errors are logged inside).
        if !sessionId.isEmpty, let taskMem = extractedTask {
            do {
                try persistTaskMemoryExtraction(
                    sessionId: sessionId,
                    extracted: taskMem,
                    store: unifiedStore
                )
            } catch {
                print("Task memory persist error: \(error)")
            }
        }

        let memoryText = buildCombinedMemoryText(
            contextMemory: memory,
            sessionId: sessionId,
            store: unifiedStore
        )
        messages = [
            MessageParameter.Message(
                role: .user,
                content: .text("【结构化记忆摘要】以下是之前对话的结构化记忆（含任务级持久记忆），请在后续回复中保持这些上下文：\n\n\(memoryText)")
            ),
            MessageParameter.Message(
                role: .assistant,
                content: .text("已了解结构化记忆摘要，将基于此上下文继续工作。")
            )
        ] + recentMessages

        currentInputTokens = 0
        print("Context compression complete: memory injected + \(recentMessages.count) recent messages")
    }

    // MARK: - Combined Memory Text

    /// Merges ContextMemory and session-scoped unified task memory into a single prompt string.
    /// Task-memory fields take priority as they are more precise; ContextMemory fills in the narrative context.
    func buildCombinedMemoryText(
        contextMemory: ContextMemory,
        sessionId: String,
        store: UnifiedMemoryFileStoreAdapter = UnifiedMemoryFileStoreAdapter()
    ) -> String {
        var parts: [String] = []

        // --- Task Memory (structured, high signal) ---
        if !sessionId.isEmpty,
           let taskMemoryText = try? taskMemoryPromptText(sessionId: sessionId, store: store),
           !taskMemoryText.isEmpty {
            parts.append("### 任务级持久记忆 (Task Memory)")
            parts.append(taskMemoryText)
        }

        // --- Context Memory (narrative context) ---
        if !contextMemory.isEmpty {
            parts.append("### 上下文记忆 (Context Memory)")
            parts.append(contextMemory.toPromptText())
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Private: Hierarchical Memory Extraction (ContextMemory)

    /// Codable mirror of the JSON schema requested from Claude.
    private struct MemoryJSON: Codable {
        var user_goal: String
        var completed_actions: [String]
        var pending_actions: [String]
        var key_files: [String]
        var failures_and_constraints: [String]
        var semantic_facts: [String]
    }

    private func buildHierarchicalMemory(
        from messages: [MessageParameter.Message],
        existing: ContextMemory,
        service: any AnthropicService,
        modelId: String
    ) async -> ContextMemory? {
        let transcript = messages.map { msg in
            let role = msg.role == "user" ? "用户" : "助手"
            let text = extractText(from: msg.content)
            return "[\(role)]: \(text)"
        }.joined(separator: "\n\n")

        let existingContext = existing.isEmpty ? "" : """

        已有的记忆摘要（请将新信息融合进去，不要重复已有条目）：
        \(existing.toPromptText())
        """

        let prompt = """
        分析以下对话历史，提取结构化的分层记忆。**只输出 JSON，不要包含任何其他文字、解释或代码块标记**。

        输出格式（严格 JSON，所有字段必须存在）：
        {
          "user_goal": "用户想要达成什么目标（一句话简述）",
          "completed_actions": ["已完成的具体操作，每条一项"],
          "pending_actions": ["尚未完成或仍在进行的操作，每条一项"],
          "key_files": ["提到的关键文件路径、函数名、模块名等，每条一项"],
          "failures_and_constraints": ["遇到的错误、失败、注意事项、限制条件，每条一项"],
          "semantic_facts": ["稳定的技术事实：项目结构、API约定、路径信息、已确认的设计决策等，每条一项"]
        }
        \(existingContext)

        对话历史：
        \(transcript)
        """

        let params = MessageParameter(
            model: .other(modelId),
            messages: [MessageParameter.Message(role: .user, content: .text(prompt))],
            maxTokens: 2048
        )

        do {
            let response = try await service.createMessage(params)
            let raw = response.content.compactMap { block -> String? in
                if case .text(let text, _) = block { return text }
                return nil
            }.joined()
            return parseMemoryJSON(raw)
        } catch {
            print("Context compression: extraction error: \(error)")
            return nil
        }
    }

    private func parseMemoryJSON(_ raw: String) -> ContextMemory? {
        guard let parsed = ModelResponseJSONExtractor.decodeIfPresent(MemoryJSON.self, from: raw) else {
            print("Context compression: JSON parse failed, raw=\(raw.prefix(400))")
            return nil
        }

        var m = ContextMemory()
        m.userGoal = parsed.user_goal
        m.completedActions = parsed.completed_actions
        m.pendingActions = parsed.pending_actions
        m.keyFilesAndPaths = parsed.key_files
        m.failuresAndConstraints = parsed.failures_and_constraints
        m.semanticFacts = parsed.semantic_facts
        return m
    }

    // MARK: - Private: Task Memory Extraction

    private struct TaskMemoryJSON: Codable {
        var confirmed_facts: [String]
        var attempted_actions: [String]
        var failed_attempts: [FailedAttemptJSON]
        var pending_questions: [String]
        var verification_status: [VerificationEntryJSON]

        struct FailedAttemptJSON: Codable {
            var action: String
            var reason: String
        }
        struct VerificationEntryJSON: Codable {
            var item: String
            var status: String
        }
    }

    /// Extracts structured TaskMemory from message history via a dedicated Claude call.
    private func buildTaskMemory(
        from messages: [MessageParameter.Message],
        existingPromptText: String?,
        service: any AnthropicService,
        modelId: String
    ) async -> TaskMemory? {
        let transcript = messages.map { msg in
            let role = msg.role == "user" ? "用户" : "助手"
            let text = extractText(from: msg.content)
            return "[\(role)]: \(text)"
        }.joined(separator: "\n\n")

        let existingContext: String
        if let existingPromptText, !existingPromptText.isEmpty {
            existingContext = """

            已有任务记忆（请将新信息融合进去，不要重复已有条目）：
            \(existingPromptText)
            """
        } else {
            existingContext = ""
        }

        let prompt = """
        分析以下对话历史，提取结构化任务记忆。**只输出 JSON，不要包含任何其他文字、解释或代码块标记**。

        输出格式（严格 JSON，所有字段必须存在）：
        {
          "confirmed_facts": ["已验证的稳定事实，每条一项"],
          "attempted_actions": ["已尝试的操作（无论成功与否），每条一项"],
          "failed_attempts": [
            {"action": "失败操作的简短描述", "reason": "失败原因"}
          ],
          "pending_questions": ["尚未解答的问题，每条一项"],
          "verification_status": [
            {"item": "被验证的功能/断言", "status": "verified|unverified|partial|failed"}
          ]
        }
        \(existingContext)

        对话历史：
        \(transcript)
        """

        let params = MessageParameter(
            model: .other(modelId),
            messages: [MessageParameter.Message(role: .user, content: .text(prompt))],
            maxTokens: 1024
        )

        do {
            let response = try await service.createMessage(params)
            let raw = response.content.compactMap { block -> String? in
                if case .text(let text, _) = block { return text }
                return nil
            }.joined()
            return parseTaskMemoryJSON(raw)
        } catch {
            print("Task memory extraction error: \(error)")
            return nil
        }
    }

    private func parseTaskMemoryJSON(_ raw: String) -> TaskMemory? {
        guard let parsed = ModelResponseJSONExtractor.decodeIfPresent(TaskMemoryJSON.self, from: raw) else {
            print("Task memory: JSON parse failed, raw=\(raw.prefix(400))")
            return nil
        }

        var m = TaskMemory(sessionId: "")
        m.confirmedFacts = parsed.confirmed_facts
        m.attemptedActions = parsed.attempted_actions
        m.failedAttempts = parsed.failed_attempts.map { FailedAttempt(action: $0.action, reason: $0.reason) }
        m.pendingQuestions = parsed.pending_questions
        m.verificationStatus = parsed.verification_status.map { VerificationEntry(item: $0.item, status: $0.status) }
        return m
    }

    func persistTaskMemoryExtraction(
        sessionId: String,
        extracted: TaskMemory,
        store: UnifiedMemoryFileStoreAdapter = UnifiedMemoryFileStoreAdapter(),
        timestamp: Date = Date()
    ) throws {
        let existing = try loadTaskMemory(sessionId: sessionId, store: store) ?? TaskMemory(sessionId: sessionId)
        var merged = existing
        var snapshot = extracted
        snapshot.sessionId = sessionId
        merged.merge(with: snapshot)

        let records = TaskMemoryRecordFactory().makeRecords(
            sessionId: sessionId,
            confirmedFacts: merged.confirmedFacts,
            attemptedActions: merged.attemptedActions,
            failedAttempts: merged.failedAttempts,
            pendingQuestions: merged.pendingQuestions,
            verificationEntries: merged.verificationStatus,
            timestamp: timestamp
        )

        for record in records {
            _ = try store.persist(record: record)
        }
    }

    func taskMemoryPromptText(
        sessionId: String,
        store: UnifiedMemoryFileStoreAdapter = UnifiedMemoryFileStoreAdapter()
    ) throws -> String {
        let records = try taskMemoryRecords(sessionId: sessionId, store: store)
        return TaskMemoryPromptRenderer().render(records: records)
    }

    func loadTaskMemory(
        sessionId: String,
        store: UnifiedMemoryFileStoreAdapter = UnifiedMemoryFileStoreAdapter()
    ) throws -> TaskMemory? {
        let records = try taskMemoryRecords(sessionId: sessionId, store: store)
        guard !records.isEmpty else {
            return nil
        }

        var memory = TaskMemory(sessionId: sessionId)
        memory.confirmedFacts = records.filter { $0.tags.contains("confirmed-fact") }.map(\.title)
        memory.attemptedActions = records.filter { $0.tags.contains("attempt") }.map(\.title)
        memory.failedAttempts = records.filter { $0.tags.contains("failed-attempt") }.map { record in
            switch record.payload {
            case let .structured(fields):
                return FailedAttempt(
                    action: fields["action"] ?? record.title,
                    reason: fields["reason"] ?? record.summary
                )
            case let .text(text):
                return FailedAttempt(action: record.title, reason: text)
            }
        }
        memory.pendingQuestions = records.filter { $0.tags.contains("pending") }.map(\.title)
        memory.verificationStatus = records.filter { $0.tags.contains("verification-entry") }.map { record in
            switch record.payload {
            case let .structured(fields):
                return VerificationEntry(
                    item: fields["item"] ?? record.title,
                    status: fields["status"] ?? record.summary
                )
            case .text:
                return VerificationEntry(item: record.title, status: record.summary)
            }
        }
        memory.lastUpdated = records.map(\.updatedAt).max() ?? records.map(\.createdAt).max() ?? memory.lastUpdated
        return memory
    }

    func taskMemoryRecords(
        sessionId: String,
        store: UnifiedMemoryFileStoreAdapter = UnifiedMemoryFileStoreAdapter()
    ) throws -> [MemoryRecord] {
        try store.records(for: .session(id: sessionId), includeArchived: false)
            .filter { $0.source == .taskMemory }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return lhs.updatedAt < rhs.updatedAt
            }
    }

    // MARK: - Helpers

    /// Extracts a plain-text representation from a `MessageParameter.Message.Content` value.
    func extractText(from content: MessageParameter.Message.Content) -> String {
        switch content {
        case .text(let str):
            return str
        case .list(let objects):
            return objects.compactMap { (obj: MessageParameter.Message.Content.ContentObject) -> String? in
                switch obj {
                case .text(let str): return str
                case .toolUse(_, let name, _): return "[工具调用: \(name)]"
                case .toolResult(_, let result, _, _): return "[工具结果: \(String(result.prefix(200)))]"
                default: return nil
                }
            }.joined(separator: " ")
        }
    }
}
