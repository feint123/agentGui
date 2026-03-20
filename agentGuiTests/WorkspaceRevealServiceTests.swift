import Foundation
import Testing
@testable import agentGui

struct WorkspaceRevealServiceTests {

    @Test func revealInFinderDeduplicatesStandardizedURLs() {
        let client = RecordingWorkspaceFinderClient()
        let service = WorkspaceRevealService(client: client)
        let raw = URL(fileURLWithPath: "/tmp/ws/Docs/../Docs/Readme.md")

        service.revealInFinder([raw, raw.standardizedFileURL])

        #expect(client.revealedURLGroups == [[raw.standardizedFileURL]])
    }

    @Test func revealInFinderPreservesChinesePathsAfterStandardization() {
        let client = RecordingWorkspaceFinderClient()
        let service = WorkspaceRevealService(client: client)
        let raw = URL(fileURLWithPath: "/tmp/工作区/文档/../文档/说明.md")

        service.revealInFinder([raw])

        #expect(client.revealedURLGroups == [[raw.standardizedFileURL]])
    }
}

private final class RecordingWorkspaceFinderClient: WorkspaceFinderClient {
    private(set) var revealedURLGroups: [[URL]] = []

    func activateFileViewerSelecting(_ urls: [URL]) {
        revealedURLGroups.append(urls)
    }
}