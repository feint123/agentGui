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
    var runtimeBridgeExpansionCount: Int = 0
    var runtimeDereferenceCount: Int = 0
}

struct AgentLoopMemoryBootstrapComposer {
    struct Dependencies {
        var loadUnifiedContext: () async throws -> MemoryRuntimeContext?
        var loadTaskMemory: () throws -> TaskMemory?
        var loadTaskMemoryPromptText: () throws -> String?
        var saveRuntimeSnapshot: (MemoryRuntimeSnapshot) throws -> String?
    }

    let dependencies: Dependencies

    func compose(bootstrapMessageCount: Int) async throws -> AgentLoopMemoryBootstrapComposition {
        if let unifiedContext = try await dependencies.loadUnifiedContext() {
            var composition = AgentLoopMemoryBootstrapComposition(
                runtimeProfiles: unifiedContext.profiles,
                runtimeLayers: Array(Set(unifiedContext.records.map { $0.layer.rawValue })).sorted(),
                runtimeWarnings: unifiedContext.warnings,
                runtimeSnapshotID: nil,
                runtimeIntentPhase: unifiedContext.runtimeSnapshot?.plan.retrievalIntent?.phase.rawValue,
                runtimeWorkingSetCost: unifiedContext.runtimeSnapshot?.metrics.workingSetCost ?? 0,
                runtimeBridgeExpansionCount: unifiedContext.runtimeSnapshot?.bridgeExpansions.count ?? 0,
                runtimeDereferenceCount: unifiedContext.runtimeSnapshot?.dereferenceCount ?? 0
            )

            if let snapshot = unifiedContext.runtimeSnapshot {
                composition.runtimeSnapshotID = try dependencies.saveRuntimeSnapshot(snapshot) ?? snapshot.id
            }

            if !unifiedContext.renderedPrompt.isEmpty {
                composition.patch = AgentLoopMessagePatch(
                    insertions: [
                        .init(
                            index: 0,
                            message: MessageParameter.Message(
                                role: .user,
                                content: .text("【统一记忆切片】以下是当前任务的统一记忆视图，请优先遵守其中的当前状态、事实、事件与风险：\n\n\(unifiedContext.renderedPrompt)")
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

        if let taskMemory = try dependencies.loadTaskMemory(),
           !taskMemory.isEmpty,
           let taskMemoryPromptText = try dependencies.loadTaskMemoryPromptText(),
           !taskMemoryPromptText.isEmpty {
            patch.insertions.append(
                .init(
                    index: 0,
                    message: MessageParameter.Message(
                        role: .user,
                        content: .text("【任务级持久记忆】这是本任务的已知状态，请优先保留这些结构化状态：\n\n\(taskMemoryPromptText)")
                    )
                )
            )
            patch.insertions.append(
                .init(
                    index: 1,
                    message: MessageParameter.Message(
                        role: .assistant,
                        content: .text("已加载任务级持久记忆，将在后续操作中保持这些状态。")
                    )
                )
            )
            patch.metadata = [
                "source": "task-unified",
                "confirmedFactCount": taskMemory.confirmedFacts.count,
                "failedAttemptCount": taskMemory.failedAttempts.count
            ]
        }

        return AgentLoopMemoryBootstrapComposition(
            patch: patch.insertions.isEmpty ? nil : patch
        )
    }
}