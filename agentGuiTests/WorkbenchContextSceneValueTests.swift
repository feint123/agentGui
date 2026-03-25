import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkbenchContextSceneValueTests {

    @Test func fileSelectionNormalizesToPathBackedSceneValue() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/repo/File.swift")

        let value = try #require(
            WorkbenchContextSceneValue(
                selection: .file(fileURL),
                diffSnapshotStore: .inMemory
            )
        )

        #expect(value == .file(path: fileURL.standardizedFileURL.path))
    }

    @Test func diffSelectionStoresSnapshotAndReturnsStableIdentifier() throws {
        let store = WorkbenchDiffSnapshotStore.inMemory
        let value = try #require(
            WorkbenchContextSceneValue(
                selection: .gitDiff(title: "A.swift", diffText: "diff --git a/A.swift b/A.swift"),
                diffSnapshotStore: store
            )
        )

        guard case .gitDiff(let title, let snapshotID) = value else {
            Issue.record("Expected gitDiff scene value")
            return
        }

        #expect(title == "A.swift")
        #expect(store.snapshot(for: snapshotID)?.title == "A.swift")
        #expect(store.snapshot(for: snapshotID)?.diffText == "diff --git a/A.swift b/A.swift")
    }

    @Test func changeProposalSelectionPreservesIdentifiers() throws {
        let proposalID = UUID()
        let value = try #require(
            WorkbenchContextSceneValue(
                selection: .changeProposal(proposalID: proposalID, filePath: "README.md"),
                diffSnapshotStore: .inMemory
            )
        )

        #expect(value == .changeProposal(proposalID: proposalID, filePath: "README.md"))
    }

    @Test func noneSelectionDoesNotCreateSceneValue() {
        let value = WorkbenchContextSceneValue(
            selection: .none,
            diffSnapshotStore: .inMemory
        )

        #expect(value == nil)
    }
}