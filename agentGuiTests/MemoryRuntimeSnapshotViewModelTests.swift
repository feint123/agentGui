import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRuntimeSnapshotViewModelTests {
    @Test func viewModelBuildsCountAndLoadBreakdownsForSelectedRecords() throws {
        let snapshot = MemoryRuntimeSnapshot.fixture(
            selectedRecords: [
                .fixture(recordID: "r1", title: "Known failure", layer: .task, kind: .working, verificationStatus: .verified, estimatedPromptChars: 40),
                .fixture(recordID: "r2", title: "User pref", layer: .semantic, kind: .semantic, verificationStatus: .verified, estimatedPromptChars: 10),
                .fixture(recordID: "r3", title: "Speculative cause", layer: .task, kind: .working, verificationStatus: .unverified, estimatedPromptChars: 20)
            ]
        )

        let viewModel = MemoryRuntimeSnapshotViewModel(snapshot: snapshot)
        viewModel.dimension = .layer
        viewModel.metric = .estimatedChars

        #expect(viewModel.chartItems.contains { $0.label == "task" && $0.value == 60 })
        #expect(viewModel.chartItems.contains { $0.label == "semantic" && $0.value == 10 })
        #expect(viewModel.selectedSummary.selectedCount == 3)
    }

    @Test func viewModelExposesBridgeAndDereferenceMetrics() throws {
        let snapshot = MemoryRuntimeSnapshot.fixture(
            bridgeExpansions: [MemoryBridgeEdge(sourceRecordID: "r1", targetRecordID: "r2", relationship: "recovery-path")],
            dereferenceCount: 2
        )

        let viewModel = MemoryRuntimeSnapshotViewModel(snapshot: snapshot)

        #expect(viewModel.bridgeExpansionCount == 1)
        #expect(viewModel.dereferenceCount == 2)
    }

    @Test func viewModelExposesRetrievalIntentAndWorkingSetCost() throws {
        let snapshot = MemoryRuntimeSnapshot.fixture(
            profileIDs: ["coding-task"],
            selectedRecords: [
                .fixture(recordID: "r1", title: "Build failure", layer: .task, kind: .working, estimatedPromptChars: 42)
            ],
            bridgeExpansions: [MemoryBridgeEdge(sourceRecordID: "r1", targetRecordID: "r2", relationship: "recovery-path")],
            dereferenceCount: 1,
            retrievalIntent: MemoryRetrievalIntent(
                phase: .verification,
                neededObjectTypes: [.fact, .procedure],
                reason: "User asked to verify the failing build"
            ),
            workingSetCost: 84
        )

        let viewModel = MemoryRuntimeSnapshotViewModel(snapshot: snapshot)

        #expect(viewModel.retrievalIntentSummary.contains("verification"))
        #expect(viewModel.workingSetCost == 84)
    }

    @Test func viewModelUsesRMSFallbackRetrievalSummary() throws {
        let viewModel = MemoryRuntimeSnapshotViewModel(snapshot: .fixture())

        #expect(viewModel.retrievalIntentSummary == "RMS retrieval fallback")
    }

    @Test func viewModelExposesEpistemicStateSummary() throws {
        let snapshot = MemoryRuntimeSnapshot.fixture(
            epistemicState: EpistemicState(
                frontiers: [
                    FrontierMemory(
                        frontierId: "f-1",
                        goal: "Fix build",
                        openClaim: "Need to confirm shared scheme",
                        uncertaintyType: .tooling,
                        impactLevel: .high,
                        suggestedProbe: "Run xcodebuild -list",
                        stopCondition: "Scheme confirmed"
                    )
                ],
                activeConstraints: [
                    ConstraintMemory(id: "c-1", summary: "Inspect before editing", scope: .session(id: "s1"))
                ],
                verificationDebt: [
                    VerificationDebt(id: "d-1", claim: "Scheme is shared", reason: "Need direct evidence")
                ],
                counterexamples: [
                    CounterexampleMemory(id: "ce-1", summary: "Edit-first is unsafe", replacementAction: "Inspect first")
                ]
            ),
            influenceTrace: MemoryInfluenceTrace(activatedMemoryIDs: ["f-1", "ce-1"], rankedActionIDs: ["Run xcodebuild -list"])
        )

        let viewModel = MemoryRuntimeSnapshotViewModel(snapshot: snapshot)

        #expect(viewModel.epistemicSummary.frontierCount == 1)
        #expect(viewModel.epistemicSummary.counterexampleCount == 1)
        #expect(viewModel.epistemicSummary.constraintCount == 1)
        #expect(viewModel.epistemicSummary.verificationDebtCount == 1)
        #expect(viewModel.epistemicSummary.activatedMemoryCount == 2)
        #expect(viewModel.epistemicSummary.rankedActionCount == 1)
    }
}