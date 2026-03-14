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
        var loadUnifiedContext: () async throws -> MemoryRuntimeContext?
        var saveRuntimeSnapshot: (MemoryRuntimeSnapshot) throws -> String?
    }

    let dependencies: Dependencies

    func compose(
        bootstrapMessageCount: Int,
        epistemicState: EpistemicState = EpistemicState()
    ) async throws -> AgentLoopMemoryBootstrapComposition {
        let epistemicSummary = renderEpistemicSummary(epistemicState)
        if let unifiedContext = try await dependencies.loadUnifiedContext() {
            let renderedPrompt: String
            if epistemicSummary.isEmpty {
                renderedPrompt = unifiedContext.renderedPrompt
            } else if unifiedContext.renderedPrompt.isEmpty {
                renderedPrompt = epistemicSummary
            } else {
                renderedPrompt = "\(epistemicSummary)\n\n\(unifiedContext.renderedPrompt)"
            }
            var composition = AgentLoopMemoryBootstrapComposition(
                runtimeProfiles: unifiedContext.profiles,
                runtimeLayers: Array(Set(unifiedContext.records.map { $0.layer.rawValue })).sorted(),
                runtimeWarnings: unifiedContext.warnings,
                runtimeSnapshotID: nil,
                runtimeIntentPhase: unifiedContext.runtimeSnapshot?.plan.retrievalIntent?.phase.rawValue,
                runtimeWorkingSetCost: unifiedContext.runtimeSnapshot?.metrics.workingSetCost ?? 0,
                runtimeDereferenceCount: unifiedContext.runtimeSnapshot?.dereferenceCount ?? 0
            )

            if let snapshot = unifiedContext.runtimeSnapshot {
                composition.runtimeSnapshotID = try dependencies.saveRuntimeSnapshot(snapshot) ?? snapshot.id
            }

            if !renderedPrompt.isEmpty {
                composition.patch = AgentLoopMessagePatch(
                    insertions: [
                        .init(
                            index: 0,
                            message: MessageParameter.Message(
                                role: .user,
                                content: .text("【统一记忆切片】以下是当前任务的统一记忆视图，请优先遵守其中的当前状态、事实、事件与风险：\n\n\(renderedPrompt)")
                            )
                        ),
                        .init(
                            index: 1,
                            message: MessageParameter.Message(
                                role: .assistant,
                                content: .text("已加载统一记忆切片，将据此继续执行当前任务。")
                            )
                        )
                    ],
                    metadata: [
                        "source": "unified",
                        "recordCount": unifiedContext.records.count,
                        "warningCount": unifiedContext.warnings.count
                    ]
                )
            }

            return composition
        }

        var patch = AgentLoopMessagePatch()

        if !epistemicSummary.isEmpty {
            patch.insertions.append(
                .init(
                    index: 0,
                    message: MessageParameter.Message(
                        role: .user,
                        content: .text("【Epistemic State】以下是当前任务的未决前沿、约束和验证债务：\n\n\(epistemicSummary)")
                    )
                )
            )
            patch.insertions.append(
                .init(
                    index: 1,
                    message: MessageParameter.Message(
                        role: .assistant,
                        content: .text("已加载当前 epistemic state，将优先处理未决前沿与验证债务。")
                    )
                )
            )
            patch.metadata["epistemicSummary"] = true
        }

        return AgentLoopMemoryBootstrapComposition(
            patch: patch.insertions.isEmpty ? nil : patch
        )
    }

    func renderEpistemicSummary(_ epistemicState: EpistemicState) -> String {
        var sections: [String] = []

        if !epistemicState.frontiers.isEmpty {
            sections.append(
                "未决前沿:\n" + epistemicState.frontiers.map {
                    "- \($0.openClaim)\n  suggested_probe: \($0.suggestedProbe)"
                }.joined(separator: "\n")
            )
        }

        if !epistemicState.activeConstraints.isEmpty {
            sections.append(
                "当前约束:\n" + epistemicState.activeConstraints.map {
                    "- \($0.summary)"
                }.joined(separator: "\n")
            )
        }

        if !epistemicState.verificationDebt.isEmpty {
            sections.append(
                "验证债务:\n" + epistemicState.verificationDebt.map {
                    "- \($0.claim): \($0.reason)"
                }.joined(separator: "\n")
            )
        }

        if !epistemicState.counterexamples.isEmpty {
            sections.append(
                "激活反例:\n" + epistemicState.counterexamples.map {
                    "- \($0.summary) -> \($0.replacementAction)"
                }.joined(separator: "\n")
            )
        }

        return sections.joined(separator: "\n\n")
    }
}