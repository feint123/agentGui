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
}