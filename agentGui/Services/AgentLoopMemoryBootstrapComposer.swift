import Foundation
import SwiftAnthropic

struct AgentLoopMemoryBootstrapComposition {
    var patch: AgentLoopMessagePatch?
    var runtimeProfiles: [String] = []
    var runtimeLayers: [String] = []
    var runtimeWarnings: [String] = []
    var runtimeSnapshotID: String?
    var runtimeIntentPhase: String?
    var runtimeWorkingSetCost: Int = 0
    var runtimeDereferenceCount: Int = 0
}

struct AgentLoopMemoryBootstrapComposer {
    struct Dependencies {
        var loadRMSState: () async throws -> RMSState?
        var loadInsights: (RMSState?) async throws -> [RMSInsight]
    }

    let dependencies: Dependencies

    func compose(bootstrapMessageCount _: Int, insightBudget: Int? = nil) async throws -> AgentLoopMemoryBootstrapComposition {
        let state = try await dependencies.loadRMSState()?.stableSnapshot()
        let activatedInsights = try await dependencies.loadInsights(state)

        guard state != nil || !activatedInsights.isEmpty else {
            return AgentLoopMemoryBootstrapComposition()
        }

        let effectiveState = state ?? RMSState(taskID: "", sessionID: "", threadID: "", summary: "")
        let effectiveBudget = max(insightBudget ?? defaultInsightBudget(for: effectiveState), 1)
        let selectedInsights = RMSSelector().select(for: effectiveState, insights: activatedInsights, budget: effectiveBudget)
        let renderedPrompt = RMSPromptComposer().compose(state: effectiveState, activatedInsights: selectedInsights)
        guard !renderedPrompt.isEmpty else {
            return AgentLoopMemoryBootstrapComposition()
        }

        return AgentLoopMemoryBootstrapComposition(
            patch: AgentLoopMessagePatch(
                insertions: [
                    .init(
                        index: 0,
                        message: MessageParameter.Message(
                            role: .user,
                            content: .text("【RMS】以下是当前任务的认知状态与高价值长期记忆，请先按这些约束与前沿推进：\n\n\(renderedPrompt)")
                        )
                    ),
                    .init(
                        index: 1,
                        message: MessageParameter.Message(
                            role: .assistant,
                            content: .text("已加载可用的 RMS 记忆上下文，将优先处理约束、前沿与验证债务。")
                        )
                    )
                ],
                metadata: [
                    "source": "rms",
                    "insightCount": selectedInsights.count
                ]
            )
        )
    }

    private func defaultInsightBudget(for state: RMSState) -> Int {
        max(0, 3 - min(state.frontiers.count, 2))
    }
}