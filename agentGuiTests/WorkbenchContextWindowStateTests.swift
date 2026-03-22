import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkbenchContextWindowStateTests {

    @Test func openingSelectionCreatesAndSelectsTab() {
        let state = WorkbenchContextWindowState()
        let fileURL = URL(fileURLWithPath: "/tmp/repo/FileA.swift")

        state.open(.file(fileURL))

        #expect(state.tabs.count == 1)
        #expect(state.selectedTab?.selection == .file(fileURL.standardizedFileURL))
        #expect(state.openRequestToken == 1)
    }

    @Test func reopeningSameFileReusesExistingTab() throws {
        let state = WorkbenchContextWindowState()
        let fileURL = URL(fileURLWithPath: "/tmp/repo/FileA.swift")

        state.open(.file(fileURL))
        let firstTabID = try #require(state.selectedTab?.id)

        state.open(.file(fileURL))

        #expect(state.tabs.count == 1)
        #expect(state.selectedTab?.id == firstTabID)
        #expect(state.openRequestToken == 2)
    }

    @Test func reopeningProposalUpdatesExistingTabFilePath() {
        let state = WorkbenchContextWindowState()
        let proposalID = UUID()

        state.open(.changeProposal(proposalID: proposalID, filePath: "A.swift"))
        state.open(.changeProposal(proposalID: proposalID, filePath: "B.swift"))

        #expect(state.tabs.count == 1)
        #expect(state.selectedTab?.selection == .changeProposal(proposalID: proposalID, filePath: "B.swift"))
    }

    @Test func closingSelectedTabPromotesNearestNeighbor() {
        let state = WorkbenchContextWindowState()

        state.open(.file(URL(fileURLWithPath: "/tmp/repo/FileA.swift")))
        state.open(.file(URL(fileURLWithPath: "/tmp/repo/FileB.swift")))
        let firstTabID = state.tabs[0].id
        let secondTabID = state.tabs[1].id

        state.closeTab(id: secondTabID)

        #expect(state.tabs.count == 1)
        #expect(state.selectedTab?.id == firstTabID)
    }
}