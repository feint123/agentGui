import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentLoopMemoryBootstrapComposerTests {

    @Test func composerPrefersUnifiedBootstrapWhenAvailable() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadUnifiedContext: {
                    MemoryRuntimeContext(
                        profiles: ["coding-task"],
                        records: [MemoryRecord.fixture(layer: .task)],
                        warnings: ["warn"],
                        renderedPrompt: "Unified prompt",
                        runtimeSnapshot: .fixture(
                            id: "snapshot-1",
                            dereferenceCount: 2,
                            retrievalIntent: MemoryRetrievalIntent(
                                phase: .verification,
                                neededObjectTypes: [.fact, .procedure],
                                reason: "Verify the build fix"
                            ),
                            workingSetCost: 96
                        )
                    )
                },
                saveRuntimeSnapshot: { $0.id }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 1)

        #expect(composition.patch?.metadata["source"] as? String == "unified")
        #expect(composition.runtimeProfiles == ["coding-task"])
        #expect(composition.runtimeLayers == [MemoryLayer.task.rawValue])
        #expect(composition.runtimeWarnings == ["warn"])
        #expect(composition.runtimeSnapshotID == "snapshot-1")
        #expect(composition.runtimeDereferenceCount == 2)
        #expect(composition.runtimeIntentPhase == "verification")
        #expect(composition.runtimeWorkingSetCost == 96)
    }

    @Test func composerBuildsEpistemicFallbackWhenUnifiedContextIsMissing() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadUnifiedContext: { nil },
                saveRuntimeSnapshot: { _ in nil }
            )
        )

        let composition = try await composer.compose(
            bootstrapMessageCount: 4,
            epistemicState: EpistemicState(
                frontiers: [
                    FrontierMemory(
                        frontierId: "f-1",
                        goal: "Fix build",
                        openClaim: "Need scheme evidence",
                        uncertaintyType: .tooling,
                        impactLevel: .high,
                        suggestedProbe: "Run xcodebuild -list",
                        stopCondition: "Scheme confirmed"
                    )
                ]
            )
        )

        #expect(composition.patch?.insertions.count == 2)
        #expect(composition.patch?.metadata["epistemicSummary"] as? Bool == true)
    }

    @Test func composerReturnsNoPatchWhenAllSourcesAreEmpty() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadUnifiedContext: { nil },
                saveRuntimeSnapshot: { _ in nil }
            )
        )

        let composition = try await composer.compose(bootstrapMessageCount: 2)

        #expect(composition.patch == nil)
    }

    @Test func composerRendersStableEpistemicSnapshot() async throws {
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadUnifiedContext: { nil },
                saveRuntimeSnapshot: { _ in nil }
            )
        )

        let summary = composer.renderEpistemicSummary(
            EpistemicState(
                frontiers: [
                    FrontierMemory(
                        frontierId: " f-1 ",
                        goal: " Fix build ",
                        openClaim: " Need scheme evidence ",
                        uncertaintyType: .tooling,
                        impactLevel: .high,
                        suggestedProbe: " Run xcodebuild -list ",
                        stopCondition: " Scheme confirmed "
                    ),
                    FrontierMemory(
                        frontierId: "f-blank",
                        goal: "Fix build",
                        openClaim: "   ",
                        uncertaintyType: .tooling,
                        impactLevel: .high,
                        suggestedProbe: "Ignore",
                        stopCondition: "Ignore"
                    )
                ],
                activeConstraints: [
                    ConstraintMemory(id: " c-1 ", summary: " Inspect before editing ", scope: .session(id: "s1")),
                    ConstraintMemory(id: "c-blank", summary: "   ", scope: .session(id: "s1"))
                ],
                verificationDebt: [
                    VerificationDebt(id: " d-1 ", claim: " Build fix works ", reason: " No direct evidence yet "),
                    VerificationDebt(id: "d-blank", claim: "   ", reason: "ignored")
                ],
                counterexamples: [
                    CounterexampleMemory(id: " ce-1 ", summary: " Avoid edit-first loop ", replacementAction: " Inspect first "),
                    CounterexampleMemory(id: "ce-blank", summary: "   ", replacementAction: "ignored")
                ]
            )
        )

        #expect(summary.contains("- Need scheme evidence"))
        #expect(summary.contains("suggested_probe: Run xcodebuild -list"))
        #expect(summary.contains("- Inspect before editing"))
        #expect(summary.contains("- Build fix works: No direct evidence yet"))
        #expect(summary.contains("- Avoid edit-first loop -> Inspect first"))
        #expect(!summary.contains("ignored"))
    }
}