import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct MemoryRuntimeIntegrationTests {
    @Test func bootstrapUsesPersistedTaskBoundRMSState() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        let modelContext = try makeModelContext()
        let store = SessionTaskStateStore(modelContext: modelContext, persistenceCoordinator: .shared)

        try store.saveRMSState(
            RMSState.fixture(
                taskID: "task-1",
                sessionID: "s1",
                threadID: "s1",
                summary: "Fix the failing build",
                constraints: [
                    .init(id: "c-1", summary: "Inspect before editing", scope: .session(id: "s1"))
                ],
                candidateActions: ["Run targeted xcodebuild test"]
            ),
            for: "s1"
        )

        let context = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: nil,
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix the failing build"))],
            modelContext: modelContext
        )

        #expect(context?.profiles == ["rms"])
        #expect(context?.renderedPrompt.contains("Inspect before editing") == true)
        #expect(context?.renderedPrompt.contains("Run targeted xcodebuild test") == true)
    }

    @Test func bootstrapReturnsNilWhenNoTaskBoundRMSStateExists() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()

        let context = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: nil,
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix build"))],
            modelContext: try makeModelContext()
        )

        #expect(context == nil)
    }

    @Test func unifiedBootstrapRespectsFeatureFlag() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        settings.memoryEnabled = false

        let context = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: nil,
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix build"))],
            modelContext: try makeModelContext()
        )

        #expect(context == nil)
    }

    @Test func bootstrapUsesRMSPromptSectionsWithoutLegacyFallback() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        let modelContext = try makeModelContext()
        let store = SessionTaskStateStore(modelContext: modelContext, persistenceCoordinator: .shared)

        try store.saveRMSState(
            RMSState.fixture(
                taskID: "task-1",
                sessionID: "s1",
                threadID: "s1",
                summary: "Fix failing build and verify tests",
                frontiers: [
                    .init(id: "f-1", goal: "Fix build", openClaim: "Need shared scheme evidence", suggestedProbe: "Run xcodebuild -list", stopCondition: "Scheme confirmed")
                ],
                constraints: [
                    .init(id: "c-1", summary: "Inspect before editing", scope: .session(id: "s1"))
                ],
                counterexamples: [
                    .init(id: "x-1", summary: "Edit-first caused regression", replacementAction: "Read failure output first")
                ],
                verificationDebts: [
                    .init(id: "d-1", claim: "Fix works", reason: "No direct runtime evidence yet")
                ],
                candidateActions: ["Run xcodebuild -list"]
            ),
            for: "s1"
        )

        let context = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: nil,
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix failing build and verify tests"))],
            modelContext: modelContext
        )

        let renderedPrompt = try #require(context?.renderedPrompt)
        #expect(renderedPrompt.contains("Current Frontiers"))
        #expect(renderedPrompt.contains("Constraints"))
        #expect(renderedPrompt.contains("Known Counterexamples"))
        #expect(renderedPrompt.contains("Verification Debt"))
        #expect(renderedPrompt.contains("Preferred Next Actions"))
    }

    @Test func bootstrapLoadsPersistedInsightsForActiveScopes() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        let modelContext = try makeModelContext()
        let taskStateStore = SessionTaskStateStore(modelContext: modelContext, persistenceCoordinator: .shared)
        let insightStore = RMSInsightStore(baseDirectory: try makeTemporaryDirectory())

        try taskStateStore.saveRMSState(
            RMSState.fixture(
                taskID: "task-1",
                sessionID: "s1",
                threadID: "s1",
                summary: "Fix xcodebuild smoke failure",
                frontiers: [
                    .init(id: "f-1", goal: "Fix build", openClaim: "Need build evidence", suggestedProbe: "Run targeted xcodebuild test", stopCondition: "Failure reproduced")
                ]
            ),
            for: "s1"
        )
        try insightStore.upsert(.constraint(
            id: "user-constraint",
            summary: "Inspect before editing",
            appliesWhen: "coding",
            changesDecision: "block speculative edits",
            scope: .user
        ))
        try insightStore.upsert(.counterexample(
            id: "session-counterexample",
            summary: "Edit-first caused regression",
            appliesWhen: "xcodebuild",
            changesDecision: "inspect current state first",
            replacementAction: "Read failure output first",
            scope: .session(id: "s1")
        ))
        try insightStore.upsert(.constraint(
            id: "other-session",
            summary: "Unrelated session guidance",
            appliesWhen: "coding",
            changesDecision: "ignore",
            scope: .session(id: "s2")
        ))

        let context = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: Session.fixture(sessionId: "s1", title: "RMS Insight Session"),
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix xcodebuild smoke failure"))],
            modelContext: modelContext,
            insightStore: insightStore
        )

        let renderedPrompt = try #require(context?.renderedPrompt)
        #expect(renderedPrompt.contains("Inspect before editing"))
        #expect(renderedPrompt.contains("Edit-first caused regression"))
        #expect(!renderedPrompt.contains("Unrelated session guidance"))
    }

    @Test func unifiedMemoryRuntimeEmitsBusinessLogsOnProductionPath() async throws {
        let sink = InMemoryBusinessLogSink()
        let service = ClaudeService()
        service.businessLogSink = sink
        let settings = AppSettings.testFixture()
        let modelContext = try makeModelContext()
        let store = SessionTaskStateStore(modelContext: modelContext, persistenceCoordinator: .shared)

        try store.saveRMSState(
            RMSState.fixture(
                summary: "Fix build",
                frontiers: [
                    .init(id: "f-1", goal: "Fix build", openClaim: "Need build evidence", suggestedProbe: "Run xcodebuild test", stopCondition: "Failure reproduced")
                ]
            ),
            for: "s1"
        )

        _ = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: nil,
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix build"))],
            modelContext: modelContext
        )

        #expect(sink.events.contains { $0.event == .memoryContextPrepared })
    }

    private func makeModelContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            SessionTaskState.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
