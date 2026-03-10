import Foundation
import SwiftData

@MainActor
final class StoryMemoryDelegationService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func classifyTask(userRequest: String, candidateText: String? = nil) -> StoryMemoryTaskType {
        if let candidateText, !candidateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .evaluateWriteback
        }

        let normalized = userRequest.lowercased()
        let continuityKeywords = ["连续性", "continuity", "时间线", "timeline", "伏笔", "设定", "canon"]
        if continuityKeywords.contains(where: { normalized.contains($0) }) {
            return .verifyContinuity
        }

        let retrievalKeywords = ["角色", "状态", "世界观", "规则", "项目", "章节", "场景", "记忆"]
        if retrievalKeywords.contains(where: { normalized.contains($0) }) {
            return .retrieveContext
        }

        return .resolveProjectBinding
    }

    func prepareDelegation(
        session: Session,
        userRequest: String,
        candidateText: String? = nil
    ) -> StoryMemoryDelegationPreparation {
        let taskType = classifyTask(userRequest: userRequest, candidateText: candidateText)

        guard let projectId = UUID(uuidString: session.activeWritingProjectId) else {
            return StoryMemoryDelegationPreparation(
                request: nil,
                preflightResponse: StoryMemoryDelegationResponse(
                    status: .projectNotBound,
                    taskType: .resolveProjectBinding,
                    facts: [],
                    inferences: [],
                    risks: [
                        StoryMemoryRiskItem(
                            level: .warning,
                            message: "当前会话未绑定 WritingProject",
                            needsUserConfirmation: false
                        )
                    ],
                    writeDecision: nil,
                    fallbackNote: "需要先绑定项目，再执行创作记忆委托。"
                )
            )
        }

        guard let project = try? fetchProject(id: projectId) else {
            return StoryMemoryDelegationPreparation(
                request: nil,
                preflightResponse: StoryMemoryDelegationResponse(
                    status: .failed,
                    taskType: taskType,
                    facts: [],
                    inferences: [],
                    risks: [
                        StoryMemoryRiskItem(
                            level: .critical,
                            message: "绑定的 WritingProject 不存在或已失效",
                            needsUserConfirmation: false
                        )
                    ],
                    writeDecision: nil,
                    fallbackNote: "项目绑定失效，无法安全执行创作记忆委托。"
                )
            )
        }

        return StoryMemoryDelegationPreparation(
            request: StoryMemoryDelegationRequest(
                projectId: project.id.uuidString,
                projectTitle: project.title,
                taskType: taskType,
                userRequest: userRequest,
                candidateText: candidateText
            ),
            preflightResponse: nil
        )
    }

    private func fetchProject(id: UUID) throws -> WritingProject {
        let descriptor = FetchDescriptor<WritingProject>(predicate: #Predicate { $0.id == id })
        guard let project = try modelContext.fetch(descriptor).first else {
            throw StoryMemoryServiceError.projectNotFound(id)
        }
        return project
    }
}