import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct AgentLoopMemoryBootstrapComposerTests {

    @Test func composerBuildsSingleRMSPatchWhenStateIsAvailable() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadRMSState: {
                    RMSState(
                        taskID: "task-1",
                        sessionID: "session-1",
                        threadID: "thread-1",
                        summary: "Fix build",
                        frontiers: [
                            .init(
                                id: "frontier-1",
                                goal: "Fix build",
                                openClaim: "Need current build evidence",
                                suggestedProbe: "Run targeted xcodebuild test",
                                stopCondition: "Targeted failure reproduced"
                            )
                        ],
                        candidateActions: ["Run targeted xcodebuild test"]
                    )
                },
                loadInsights: { _ in
                    [
                        .constraint(
                            id: "constraint-1",
                            summary: "Inspect before editing",
                            appliesWhen: "coding",
                            changesDecision: "block speculative edits"
                        )
                    ]
                }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 1)
        let firstUserText = extractText(from: composition.patch?.insertions.first?.message.content)
        let containsCurrentFrontiers = firstUserText.contains("Current Frontiers")

        #expect(composition.patch?.metadata["source"] as? String == "rms")
        #expect(composition.patch?.insertions.count == 2)
        #expect(composition.patch?.insertions.first?.message.role == "user")
        #expect(containsCurrentFrontiers)
        #expect(composition.runtimeProfiles.isEmpty)
        #expect(composition.runtimeLayers.isEmpty)
        #expect(composition.runtimeWarnings.isEmpty)
        #expect(composition.runtimeSnapshotID == nil)
        #expect(composition.runtimeDereferenceCount == 0)
        #expect(composition.runtimeIntentPhase == nil)
        #expect(composition.runtimeWorkingSetCost == 0)
    }

    @Test func composerReturnsNoPatchWhenRMSStateIsMissing() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadRMSState: { nil },
                loadInsights: { _ in [] }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 4)

        #expect(composition.patch == nil)
    }

    @Test func composerUsesSelectorBudgetToTrimActivatedInsights() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadRMSState: {
                    RMSState(
                        taskID: "task-1",
                        sessionID: "session-1",
                        threadID: "thread-1",
                        summary: "Fix build",
                        candidateActions: ["Run targeted xcodebuild test"]
                    )
                },
                loadInsights: { _ in
                    [
                        .tactic(
                            id: "tactic-1",
                            summary: "Use a targeted test",
                            appliesWhen: "swift build triage",
                            changesDecision: "narrow scope"
                        ),
                        .counterexample(
                            id: "counterexample-1",
                            summary: "Edit-first caused regression",
                            appliesWhen: "coding",
                            changesDecision: "inspect first",
                            replacementAction: "Read failure output first"
                        ),
                        .constraint(
                            id: "constraint-1",
                            summary: "Inspect before editing",
                            appliesWhen: "coding",
                            changesDecision: "block speculative edits"
                        )
                    ]
                }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 1)
        let userText = extractText(from: composition.patch?.insertions.first?.message.content)

        #expect(userText.contains("Inspect before editing"))
        #expect(userText.contains("Edit-first caused regression"))
        #expect(!userText.contains("Use a targeted test"))
    }
}

private func extractText(from content: MessageParameter.Message.Content?) -> String {
    guard let content else { return "" }
    if case .text(let value) = content {
        return value
    }
    return ""
}