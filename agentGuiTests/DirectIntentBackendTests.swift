import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct DirectIntentBackendTests {

    @Test func strReplaceCreatesProposalAndSynchronizesRealWorkspaceDraft() async throws {
        let harness = try DirectIntentHarness.make(fileText: "hello", relativePath: "file.txt")
        let backend = harness.makeBackend()

        let snapshot = try await backend.captureStrReplace(
            path: harness.fileURL.path,
            oldStr: "hello",
            newStr: "world",
            sessionID: harness.session.sessionId,
            baseWorkspaceRoot: harness.workspaceRoot.path
        )

        #expect(try String(contentsOf: harness.fileURL, encoding: .utf8) == "world")
        #expect(snapshot.proposal.sessionID == harness.session.sessionId)
        #expect(snapshot.proposal.state == .readyForReview)
        #expect(snapshot.fileChanges.count == 1)
        #expect(snapshot.fileChanges[0].relativePath == "file.txt")
        #expect(snapshot.fileChanges[0].unifiedDiff.contains("+world"))
        #expect(harness.projectionStore.projection(forSessionID: harness.session.sessionId).pendingProposalCount == 1)
    }

    @Test func executeToolStagesCreateProposalAndReturnsReviewMetadata() async throws {
        let harness = try DirectIntentHarness.make(fileText: nil, relativePath: "nested/new.txt")
        let service = ClaudeService()
        service.changeReviewProjectionStore = harness.projectionStore

        let result = await service.executeTool(
            name: "str_replace_based_edit_tool",
            input: [
                "command": .string("create"),
                "path": .string(harness.fileURL.path),
                "file_text": .string("hello world")
            ],
            settings: harness.settings,
            session: harness.session,
            modelContext: harness.context
        )

        #expect(FileManager.default.fileExists(atPath: harness.fileURL.path))
        #expect(try String(contentsOf: harness.fileURL, encoding: .utf8) == "hello world")
        #expect(result.isError == false)
        #expect(result.changeProposalState == .readyForReview)
        #expect(result.changeProposalSnapshot?.fileChanges.count == 1)
        #expect(result.changeProposalSnapshot?.fileChanges.first?.relativePath == "nested/new.txt")
        let proposalID = try #require(result.changeProposalID)
        #expect(harness.projectionStore.snapshot(for: proposalID)?.proposal.id == proposalID)
    }
}

@MainActor
private struct DirectIntentHarness {
    let container: ModelContainer
    let context: ModelContext
    let settings: AppSettings
    let session: Session
    let workspaceRoot: URL
    let fileURL: URL
    let projectionStore: ChangeReviewProjectionStore

    static func make(fileText: String?, relativePath: String) throws -> DirectIntentHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(PersistenceSchema.sharedModelTypes),
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let workspaceRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let fileURL = workspaceRoot.appending(path: relativePath)
        if let fileText {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileText.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let settings = AppSettings.testFixture(apiKey: "")
        settings.workingDirectory = workspaceRoot.path
        settings.enableTextEditorTool = true
        let session = Session.fixture(title: "Direct Intent", workingDirectory: workspaceRoot.path)
        context.insert(settings)
        context.insert(session)
        try context.save()

        return DirectIntentHarness(
            container: container,
            context: context,
            settings: settings,
            session: session,
            workspaceRoot: workspaceRoot,
            fileURL: fileURL,
            projectionStore: ChangeReviewProjectionStore()
        )
    }

    func makeBackend() -> DirectIntentBackend {
        DirectIntentBackend(
            modelContext: context,
            persistenceCoordinator: PersistenceCoordinator(),
            projectionStore: projectionStore
        )
    }
}