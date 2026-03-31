import Foundation

// MARK: - Review Kind

enum AgentTeamReviewKind: String, Codable, Equatable, Sendable, CaseIterable {
    case semantic    // 语义正确性：输出是否满足 goal 与 acceptance criteria
    case validation  // 技术验证：实现是否正确、无回归
    case approval    // 发布批准：conductor/reviewer 的最终 approve
}

// MARK: - Review Decision

enum AgentTeamReviewDecision: String, Codable, Equatable, Sendable, CaseIterable {
    case approved           // 通过，对应 task card → .done
    case needsWork          // 需返工，对应 task card → .working
    case rejected           // 拒绝（不可修复），对应 task card → .blocked
    case conflictDetected   // 发现冲突，对应 task card → .blocked
}

// MARK: - Review Issue Severity

enum AgentTeamReviewIssueSeverity: String, Codable, Equatable, Sendable, CaseIterable {
    case critical  // 必须修复，否则阻塞 merge
    case warning   // 建议修复，不阻塞 merge
    case info      // 信息性，不影响 merge
}

// MARK: - Review Issue

struct AgentTeamReviewIssue: Codable, Equatable, Sendable {
    let id: UUID
    let severity: AgentTeamReviewIssueSeverity
    let description: String
    let targetArtifactID: UUID?  // 可选，指向出现问题的 artifact
}

// MARK: - Review Report

struct AgentTeamReviewReport: Codable, Equatable, Sendable {
    let id: UUID
    let reviewer: ExecutionProviderReference
    let reviewedArtifactIDs: [UUID]
    let kind: AgentTeamReviewKind
    let decision: AgentTeamReviewDecision
    let rationale: String
    let issues: [AgentTeamReviewIssue]
    /// 每个内层数组为一对冲突的 artifact ID，如 [[a, b], [c, d]]
    let conflictingArtifactPairs: [[UUID]]
    let submittedAt: Date
}
