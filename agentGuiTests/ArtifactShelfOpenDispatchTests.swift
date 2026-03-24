import Foundation
import Testing
@testable import agentGui

struct ArtifactShelfOpenDispatchTests {

    @Test func markdownFilesRouteToInternalEditor() {
        let url = URL(fileURLWithPath: "/tmp/Notes.md").standardizedFileURL

        let action = ArtifactOpenDispatcher.resolve(for: .localFile(url))

        #expect(action == .openInEditor(url))
    }

    @Test func filesWithoutExtensionRouteToInternalEditor() {
        let url = URL(fileURLWithPath: "/tmp/.env").standardizedFileURL

        let action = ArtifactOpenDispatcher.resolve(for: .localFile(url))

        #expect(action == .openInEditor(url))
    }

    @Test func binaryFilesRouteToExternalOpen() {
        let url = URL(fileURLWithPath: "/tmp/Guide.pdf").standardizedFileURL

        let action = ArtifactOpenDispatcher.resolve(for: .localFile(url))

        #expect(action == .openExternally(url))
    }

    @Test func folderAndWebLinkRouteToExternalOpen() {
        let folderURL = URL(fileURLWithPath: "/tmp/docs").standardizedFileURL
        let webURL = URL(string: "https://example.com/spec")!

        #expect(ArtifactOpenDispatcher.resolve(for: .localFolder(folderURL)) == .openExternally(folderURL))
        #expect(ArtifactOpenDispatcher.resolve(for: .webURL(webURL)) == .openExternally(webURL))
    }

    @Test func unknownResourceRoutesToNone() {
        #expect(ArtifactOpenDispatcher.resolve(for: .unknown("mystery")) == .none)
    }

    @Test func collapsedSummaryShowsFirstThreeItemsOnly() {
        let items = (1...5).map { ArtifactSummaryLine(id: "\($0)", text: "cmd \($0)") }

        let collapsed = ArtifactShelfSummaryVisibility.visibleItems(items, isExpanded: false, limit: 3)
        let expanded = ArtifactShelfSummaryVisibility.visibleItems(items, isExpanded: true, limit: 3)

        #expect(collapsed.map(\.id) == ["1", "2", "3"])
        #expect(expanded.map(\.id) == ["1", "2", "3", "4", "5"])
    }
}