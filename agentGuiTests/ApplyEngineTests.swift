import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ApplyEngineTests {

    @Test func applyConfirmsDraftAlreadyWrittenToWorkspace() async throws {
        let harness = try ApplyEngineHarness.make(original: "hello")
        let proposal = try await harness.makeProposal(newText: "world")

        #expect(try String(contentsOf: harness.fileURL, encoding: .utf8) == "world")

        try await harness.applyEngine.apply(proposalID: proposal.id, approvedPaths: ["file.txt"])

        #expect(try String(contentsOf: harness.fileURL, encoding: .utf8) == "world")
        #expect(try harness.store.proposal(id: proposal.id)?.state == .applied)
    }

    @Test func applyMarksProposalConflictedWhenDraftChangedAfterStaging() async throws {
        let harness = try ApplyEngineHarness.make(original: "hello")
        let proposal = try await harness.makeProposal(newText: "world")
        try "user edit".write(to: harness.fileURL, atomically: true, encoding: .utf8)

        await #expect(throws: ChangeReviewConflictError.self) {
            try await harness.applyEngine.apply(proposalID: proposal.id, approvedPaths: ["file.txt"])
        }
        #expect(try harness.store.proposal(id: proposal.id)?.state == .conflicted)
    }

    @Test func revertFilesDiscardsProposalWhenAllChangesAreRemoved() async throws {
        let harness = try ApplyEngineHarness.make(original: "hello")
        let proposal = try await harness.makeProposal(newText: "world")

        try await harness.revertService.revertFiles(proposalID: proposal.id, relativePaths: ["file.txt"])

        let snapshot = try await harness.store.reviewSnapshot(for: proposal.id)
        #expect(try String(contentsOf: harness.fileURL, encoding: .utf8) == "hello")
        #expect(snapshot.proposal.state == .discarded)
        #expect(snapshot.fileChanges.first?.state == .revertedBeforeApply)
    }
}

@MainActor
private struct ApplyEngineHarness {
    let container: ModelContainer
    let context: ModelContext
    let workspaceRoot: URL
    let fileURL: URL
    let session: Session
    let store: ChangeProposalStore
    let backend: DirectIntentBackend
    let projectionStore: ChangeReviewProjectionStore
    let applyEngine: ApplyEngine
    let revertService: DraftRevertService

    static func make(original: String) throws -> ApplyEngineHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(PersistenceSchema.sharedModelTypes),
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let workspaceRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let fileURL = workspaceRoot.appending(path: "file.txt")
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let settings = AppSettings.testFixture(apiKey: "")
        settings.workingDirectory = workspaceRoot.path
        let session = Session.fixture(title: "Apply Engine", workingDirectory: workspaceRoot.path)
        context.insert(settings)
        context.insert(session)
        try context.save()

        let projectionStore = ChangeReviewProjectionStore()
        let store = ChangeProposalStore(modelContext: context, persistenceCoordinator: PersistenceCoordinator())
        let backend = DirectIntentBackend(
            modelContext: context,
            persistenceCoordinator: PersistenceCoordinator(),
            projectionStore: projectionStore
        )
        let applyEngine = ApplyEngine(
            modelContext: context,
            persistenceCoordinator: PersistenceCoordinator(),
            projectionStore: projectionStore
        )
        let revertService = DraftRevertService(
            modelContext: context,
            persistenceCoordinator: PersistenceCoordinator(),
            projectionStore: projectionStore
        )

        return ApplyEngineHarness(
            container: container,
            context: context,
            workspaceRoot: workspaceRoot,
            fileURL: fileURL,
            session: session,
            store: store,
            backend: backend,
            projectionStore: projectionStore,
            applyEngine: applyEngine,
            revertService: revertService
        )
    }

    func makeProposal(newText: String) async throws -> ChangeProposalReviewSnapshot {
        try await backend.captureStrReplace(
            path: fileURL.path,
            oldStr: "hello",
            newStr: newText,
            sessionID: session.sessionId,
            baseWorkspaceRoot: workspaceRoot.path
        )
    }
}