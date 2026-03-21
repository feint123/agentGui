import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ExternalChangeReviewIntegrationTests {
    @Test func copilotExecutionSynchronizesDraftBackToRealWorkspace() async throws {
        let harness = try ExternalChangeReviewHarness.make()

        let jobHandle = try await harness.orchestrator.enqueue(
            EnqueueExecutionCommand(
                sessionID: harness.session.sessionId,
                providerID: .githubCopilotCLI,
                payload: .userPrompt(
                    text: "please update readme",
                    modelID: "gpt-5",
                    selectedFilePath: nil,
                    selectedText: nil,
                    directives: []
                ),
                sourceUserMessageID: harness.userMessage.id
            )
        )

        let proposal = try await harness.awaitProposal(for: jobHandle.jobID)
        let change = try #require(proposal.fileChanges.first)
        let diskText = try String(contentsOf: harness.realWorkspaceFile("README.md"), encoding: .utf8)

        #expect(diskText == "isolated")
        #expect(proposal.state == .readyForReview)
        #expect(proposal.baseWorkspaceRoot == harness.workspaceRoot.path)
        #expect(proposal.jobID == jobHandle.jobID)
        #expect(change.relativePath == "README.md")
        #expect(change.absolutePath == harness.realWorkspaceFile("README.md").path)
        #expect(change.unifiedDiff.contains("+isolated"))
        #expect(change.baseContentSnapshot == "original")
        #expect(change.stagedContentSnapshot == "isolated")
        #expect(change.baseContentHash != change.stagedContentHash)
        #expect(harness.runtimeClient.ensureSessionWorkingDirectories.count == 1)
        #expect(harness.runtimeClient.ensureSessionWorkingDirectories[0] == harness.workspaceRoot.path)
    }

    @Test func copilotExecutionIgnoresBinaryFilesWhenCapturingWorkspaceChanges() async throws {
        let harness = try ExternalChangeReviewHarness.make(additionalFiles: [
            ("image.bin", Data([0xFF, 0xD8, 0xFF, 0x00]))
        ])

        let jobHandle = try await harness.orchestrator.enqueue(
            EnqueueExecutionCommand(
                sessionID: harness.session.sessionId,
                providerID: .githubCopilotCLI,
                payload: .userPrompt(
                    text: "please update readme",
                    modelID: "gpt-5",
                    selectedFilePath: nil,
                    selectedText: nil,
                    directives: []
                ),
                sourceUserMessageID: harness.userMessage.id
            )
        )

        let proposal = try await harness.awaitProposal(for: jobHandle.jobID)

        #expect(proposal.fileChanges.map { $0.relativePath } == ["README.md"])
        #expect(try String(contentsOf: harness.realWorkspaceFile("README.md"), encoding: .utf8) == "isolated")
    }
}

@MainActor
private struct ExternalChangeReviewHarness {
    let modelContext: ModelContext
    let workspaceRoot: URL
    let session: Session
    let userMessage: Message
    let orchestrator: ConversationExecutionOrchestrator
    let runtimeClient: EditingGitHubRuntimeStub

    static func make(additionalFiles: [(String, Data)] = []) throws -> Self {
        let workspaceRoot = try makeTemporaryDirectory()
        try "original".write(
            to: workspaceRoot.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )
        for (relativePath, data) in additionalFiles {
            let fileURL = workspaceRoot.appending(path: relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Session.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            AppSettings.self,
            ExecutionJob.self,
            ExecutionAttempt.self,
            ChangeProposal.self,
            ProposedFileChange.self,
            ChangeReviewDecision.self,
            ACPExternalSessionBinding.self,
            configurations: configuration
        )
        let modelContext = ModelContext(container)
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(sessionId: "session-1", title: "External Review", workingDirectory: workspaceRoot.path)
        let userMessage = Message.userMessage(text: "please update readme", session: session)
        userMessage.status = .completed

        modelContext.insert(settings)
        modelContext.insert(session)
        modelContext.insert(userMessage)
        try modelContext.save()

        let runtimeClient = EditingGitHubRuntimeStub(relativePath: "README.md", newText: "isolated")
        let provider = GitHubCopilotCLIExecutionProvider(
            availabilityService: GitHubCopilotCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            ),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )
        let registry = ConversationExecutionProviderRegistry(
            builtIn: NoopExecutionProvider(id: .builtInAgent),
            copilot: provider,
            openCode: NoopExecutionProvider(id: .openCodeCLI)
        )
        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: modelContext,
            persistenceStore: ExecutionPersistenceStore(
                modelContext: modelContext,
                persistenceCoordinator: PersistenceCoordinator(saveOperation: { try $0.save() })
            ),
            projectionStore: ExecutionProjectionStore(),
            scheduler: ExecutionScheduler(maxConcurrentJobs: 1),
            runtimePool: ExecutionRuntimePool(),
            providerRegistry: registry,
            runtimeCoordinator: ConversationExecutionRuntimeCoordinator(),
            changeReviewProjectionStore: ChangeReviewProjectionStore()
        )

        return Self(
            modelContext: modelContext,
            workspaceRoot: workspaceRoot,
            session: session,
            userMessage: userMessage,
            orchestrator: orchestrator,
            runtimeClient: runtimeClient
        )
    }

    func realWorkspaceFile(_ relativePath: String) -> URL {
        workspaceRoot.appending(path: relativePath)
    }

    func awaitProposal(for jobID: UUID) async throws -> ChangeProposal {
        for _ in 0..<100 {
            if let proposal = try latestProposal(for: jobID) {
                return proposal
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        throw ExternalChangeReviewHarnessError.proposalTimedOut(jobID)
    }

    private func latestProposal(for jobID: UUID) throws -> ChangeProposal? {
        let targetJobID = jobID
        var descriptor = FetchDescriptor<ChangeProposal>(
            predicate: #Predicate { proposal in
                proposal.jobID == targetJobID
            }
        )
        descriptor.sortBy = [SortDescriptor(\ChangeProposal.updatedAt, order: .reverse)]
        return try modelContext.fetch(descriptor).first
    }
}

private enum ExternalChangeReviewHarnessError: Error {
    case proposalTimedOut(UUID)
    case missingWorkingDirectory
}

@MainActor
private final class NoopExecutionProvider: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID

    init(id: ConversationExecutionProviderID) {
        self.id = id
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        _ = request
    }

    func regenerate(_ request: ConversationRegenerationRequest) async throws {
        _ = request
    }

    func editAndResend(_ request: ConversationEditAndResendRequest) async throws {
        _ = request
    }

    func cancel(session: Session, modelContext: ModelContext) async {
        _ = session
        _ = modelContext
    }
}

@MainActor
private final class EditingGitHubRuntimeStub: GitHubCopilotCLIRuntimeClient {
    let relativePath: String
    let newText: String

    var updateSink: (@Sendable (CopilotACPUpdate) async -> Void)?
    private(set) var ensureSessionWorkingDirectories: [String] = []
    private var currentWorkingDirectory: String?

    init(relativePath: String, newText: String) {
        self.relativePath = relativePath
        self.newText = newText
    }

    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> GitHubCopilotCLISessionHandshake {
        _ = remoteSessionID
        currentWorkingDirectory = workingDirectory
        ensureSessionWorkingDirectories.append(workingDirectory)
        return GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-review", cliVersion: "1.0.0")
    }

    func setModel(_ modelID: String, sessionID: String) async throws {
        _ = modelID
        _ = sessionID
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        _ = text
        _ = sessionID
        guard let currentWorkingDirectory else {
            throw ExternalChangeReviewHarnessError.missingWorkingDirectory
        }

        let targetURL = URL(fileURLWithPath: currentWorkingDirectory).appending(path: relativePath)
        try newText.write(to: targetURL, atomically: true, encoding: .utf8)
        return .endTurn
    }

    func cancel(sessionID: String) async throws {
        _ = sessionID
    }

    func close() async {}
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}