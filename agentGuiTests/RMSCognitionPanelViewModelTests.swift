import Foundation
import Testing
@testable import agentGui

@MainActor
struct RMSCognitionPanelViewModelTests {
    @Test func viewModelProjectsFrontiersCounterexamplesConstraintsAndDebt() {
        let snapshot = MemoryRuntimeSnapshot.fixture(
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
                ],
                activeConstraints: [
                    ConstraintMemory(id: "c-1", summary: "Run verification before file edits", scope: .session(id: "s1"))
                ],
                candidateActions: ["Run xcodebuild -list"],
                verificationDebt: [
                    VerificationDebt(id: "d-1", claim: "Build fix works", reason: "No direct test evidence yet")
                ],
                counterexamples: [
                    CounterexampleMemory(id: "ce-1", summary: "Do not edit before inspect", replacementAction: "Inspect first")
                ]
            ),
            influenceTrace: MemoryInfluenceTrace(
                activatedMemoryIDs: ["f-1", "ce-1"],
                rankedActionIDs: ["Run xcodebuild -list"],
                blockedActionIDs: ["Edit Build Settings"],
                actionRankingChanges: [
                    .init(memoryID: "ce-1", fromAction: "Edit Build Settings", toAction: "Run xcodebuild -list", rationale: "counterexample blocked premature edits")
                ],
                blockedPathReasons: [
                    .init(memoryID: "ce-1", blockedAction: "Edit Build Settings", rationale: "Do not edit before inspect")
                ],
                frontierBudgetDecisions: [
                    .init(frontierID: "f-1", allocatedBudget: 3, rationale: "high impact frontier")
                ]
            )
        )

        let viewModel = RMSCognitionPanelViewModel(snapshot: snapshot)

        #expect(viewModel.frontierItems.count == 1)
        #expect(viewModel.counterexampleItems.count == 1)
        #expect(viewModel.constraintItems.count == 1)
        #expect(viewModel.verificationDebtItems.count == 1)
        #expect(viewModel.suggestedActionItems.map(\.summary) == ["Run xcodebuild -list"])
        #expect(viewModel.influenceItems.contains { $0.kind == .actionRankingChange })
        #expect(viewModel.influenceItems.contains { $0.kind == .blockedPathReason })
    }

    @Test func viewModelExposesSectionsInUserFacingOrder() {
        let viewModel = RMSCognitionPanelViewModel(snapshot: .fixture())

        #expect(viewModel.sectionOrder == [
            .frontiers,
            .counterexamples,
            .constraints,
            .verificationDebt,
            .influenceTrace,
            .suggestedActions
        ])
    }

    @Test func viewModelExposesDeveloperDiagnosticsAsSecondaryDetails() {
        let snapshot = MemoryRuntimeSnapshot.fixture(
            dereferenceCount: 2,
            retrievalIntent: MemoryRetrievalIntent(
                phase: .verification,
                neededObjectTypes: [.fact, .procedure],
                reason: "Verify build fix"
            ),
            workingSetCost: 128
        )

        let viewModel = RMSCognitionPanelViewModel(snapshot: snapshot)

        #expect(viewModel.developerDiagnostics.workingSetCost == 128)
        #expect(viewModel.developerDiagnostics.dereferenceCount == 2)
        #expect(viewModel.developerDiagnostics.retrievalIntentSummary.contains("verification"))
        #expect(viewModel.showDeveloperDiagnosticsByDefault == false)
    }
}