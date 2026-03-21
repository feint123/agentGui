import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ExecutionPersistenceStoreTests {
    @Test func executionJobStartsQueuedAndBindsSourceMessage() throws {
        let sourceMessageID = UUID()
        let job = ExecutionJob(
            sessionID: "session-1",
            providerID: .githubCopilotCLI,
            payload: .userPrompt(
                text: "run tests",
                modelID: "gpt-5",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: sourceMessageID,
            targetAgentMessageID: nil
        )

        #expect(job.state == .queued)
        #expect(job.providerID == .githubCopilotCLI)
        #expect(job.sourceUserMessageID == sourceMessageID)
        #expect(job.latestAttemptID == nil)
    }

    @Test func executionAttemptStartsRunningAndLinksJob() throws {
        let job = ExecutionJob(
            sessionID: "session-1",
            providerID: .openCodeCLI,
            payload: .userPrompt(
                text: "queued",
                modelID: "gpt-5-mini",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: UUID(),
            targetAgentMessageID: UUID()
        )

        let attempt = ExecutionAttempt(jobID: job.id)

        #expect(attempt.jobID == job.id)
        #expect(attempt.state == .running)
        #expect(attempt.endedAt == nil)
    }

    @Test func executionPayloadDraftRoundTripsThroughStoredJSON() throws {
        let payload = ExecutionPayloadDraft.userPrompt(
            text: "ship it",
            modelID: "claude-4.1",
            selectedFilePath: "/tmp/file.swift",
            selectedText: "let value = 1",
            directives: [.skill(.init(directoryName: "swiftui-expert", displayName: "SwiftUI Expert"))]
        )

        let decoded = try #require(ExecutionPayloadDraft(json: payload.encodedJSON))

        switch decoded {
        case let .userPrompt(text, modelID, selectedFilePath, selectedText, directives):
            #expect(text == "ship it")
            #expect(modelID == "claude-4.1")
            #expect(selectedFilePath == "/tmp/file.swift")
            #expect(selectedText == "let value = 1")
            #expect(directives == [.skill(.init(directoryName: "swiftui-expert", displayName: "SwiftUI Expert"))])
        }
    }

    @Test func enqueuePersistsQueuedJobAndCreatesAgentPlaceholder() async throws {
        let harness = try ExecutionPersistenceHarness.make()
        let store = harness.makeStore()

        let result = try await store.enqueue(
            sessionID: harness.session.sessionId,
            providerID: .openCodeCLI,
            payload: .userPrompt(
                text: "queued",
                modelID: "gpt-5",
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: harness.userMessage.id
        )

        let messages = try harness.modelContext.fetch(FetchDescriptor<Message>()).sorted { $0.sequence < $1.sequence }
        let jobs = try harness.modelContext.fetch(FetchDescriptor<ExecutionJob>())

        #expect(result.job.state == .queued)
        #expect(result.agentMessageID != nil)
        #expect(messages.count == 2)
        #expect(messages.last?.direction == .agent)
        #expect(messages.last?.status == .pending)
        #expect(jobs.count == 1)
        #expect(jobs.first?.targetAgentMessageID == result.agentMessageID)
    }
}

@MainActor
struct ExecutionPersistenceHarness {
    let modelContext: ModelContext
    let session: Session
    let userMessage: Message
    let persistenceCoordinator: PersistenceCoordinator

    static func make() throws -> Self {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Session.self,
            Message.self,
            ExecutionJob.self,
            ExecutionAttempt.self,
            configurations: configuration
        )
        let modelContext = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "Execution")
        let userMessage = Message.userMessage(text: "queued", session: session)
        userMessage.status = .completed
        modelContext.insert(session)
        modelContext.insert(userMessage)
        try modelContext.save()

        return Self(
            modelContext: modelContext,
            session: session,
            userMessage: userMessage,
            persistenceCoordinator: PersistenceCoordinator(saveOperation: { try $0.save() })
        )
    }

    func makeStore() -> ExecutionPersistenceStore {
        ExecutionPersistenceStore(
            modelContext: modelContext,
            persistenceCoordinator: persistenceCoordinator
        )
    }
}