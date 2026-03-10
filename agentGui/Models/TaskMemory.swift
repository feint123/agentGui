//
//  TaskMemory.swift
//  agentGui
//
//  Structured task-level extraction model used during prompt compression and reflection.
//  Complements ContextMemory (in-context compression) with a durable, structured record
//  that survives across context resets and long agentic sessions.
//

import Foundation

// MARK: - TaskMemory

/// Persistent task-level memory for a single session.
/// Intermediate task-memory shape used to extract and merge task state before
/// persisting it as unified session-scoped MemoryRecord values.
struct TaskMemory: Codable {

    // MARK: - Metadata
    var sessionId: String
    var lastUpdated: Date

    // MARK: - Structured State

    /// Verified, stable facts about the task environment (project layout, API contracts, etc.)
    var confirmedFacts: [String]

    /// Actions that have been attempted (successful or not).
    var attemptedActions: [String]

    /// Distinct failed attempts, each with a brief reason.
    var failedAttempts: [FailedAttempt]

    /// Open questions that still need answers.
    var pendingQuestions: [String]

    /// Per-item verification state (item description → status string).
    var verificationStatus: [VerificationEntry]

    // MARK: - Init

    init(sessionId: String) {
        self.sessionId = sessionId
        self.lastUpdated = Date()
        self.confirmedFacts = []
        self.attemptedActions = []
        self.failedAttempts = []
        self.pendingQuestions = []
        self.verificationStatus = []
    }

    var isEmpty: Bool {
        confirmedFacts.isEmpty && attemptedActions.isEmpty && failedAttempts.isEmpty
            && pendingQuestions.isEmpty && verificationStatus.isEmpty
    }

    // MARK: - Merge

    /// Merge a newer extraction into this memory.
    mutating func merge(with newer: TaskMemory) {
        lastUpdated = Date()
        confirmedFacts = taskMemoryDeduped(confirmedFacts + newer.confirmedFacts)
        attemptedActions = taskMemoryDeduped(attemptedActions + newer.attemptedActions)
        // Deduplicate failedAttempts by action
        var seen = Set(failedAttempts.map(\.action))
        for fa in newer.failedAttempts where seen.insert(fa.action).inserted {
            failedAttempts.append(fa)
        }
        // Pending questions: replace with newer set if non-empty, else keep
        if !newer.pendingQuestions.isEmpty {
            pendingQuestions = taskMemoryDeduped(newer.pendingQuestions)
        }
        // Verification: update/append by item name
        var vsMap = Dictionary(verificationStatus.map { ($0.item, $0) }, uniquingKeysWith: { _, new in new })
        for entry in newer.verificationStatus {
            vsMap[entry.item] = entry
        }
        verificationStatus = vsMap.values.sorted { $0.item < $1.item }
    }

    // MARK: - Prompt Text

    /// Renders structured task memory as a prompt-ready string.
    func toPromptText() -> String {
        var parts: [String] = []
        if !confirmedFacts.isEmpty {
            parts.append("## Confirmed Facts\n" + confirmedFacts.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !attemptedActions.isEmpty {
            parts.append("## Attempted Actions\n" + attemptedActions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !failedAttempts.isEmpty {
            let lines = failedAttempts.map { "- \($0.action): \($0.reason)" }.joined(separator: "\n")
            parts.append("## Failed Attempts\n" + lines)
        }
        if !pendingQuestions.isEmpty {
            parts.append("## Pending Questions\n" + pendingQuestions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !verificationStatus.isEmpty {
            let lines = verificationStatus.map { "- \($0.item) [\($0.status)]" }.joined(separator: "\n")
            parts.append("## Verification Status\n" + lines)
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Supporting Types

struct FailedAttempt: Codable, Equatable {
    var action: String
    var reason: String
}

struct VerificationEntry: Codable, Equatable {
    var item: String
    /// e.g. "verified", "unverified", "partial", "failed"
    var status: String
}

// MARK: - Private Helper

private func taskMemoryDeduped(_ array: [String]) -> [String] {
    var seen = Set<String>()
    return array.filter { seen.insert($0).inserted }
}
