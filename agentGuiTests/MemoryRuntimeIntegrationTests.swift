import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct MemoryRuntimeIntegrationTests {
    @Test func codingRequestProducesSingleUnifiedMemorySlice() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            unifiedRecords: [MemoryRecord.fixture(layer: .task, kind: .working, title: "Known task fact")]
        )

        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix the failing build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let context = try await coordinator.prepareContext(for: request)
        #expect(context.renderedPrompt.contains("Known task fact"))
    }

    @Test func unifiedMemoryBootstrapPersistsSnapshotAndLinksToolCall() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            unifiedRecords: [MemoryRecord.fixture(id: "task-1", layer: .task, scope: .session(id: "s1"), title: "Known failure")]
        )

        let context = try await coordinator.prepareContext(for: .init(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        ))
        let snapshot = try #require(context.runtimeSnapshot)
        try store.save(snapshot)

        let toolCall = ToolCall(toolCallId: "tool-1", kind: .search)
        toolCall.memoryRuntimeSnapshotID = snapshot.id

        let loadedSnapshot = try store.snapshot(id: snapshot.id)
        #expect(loadedSnapshot?.selectedRecords.contains { $0.layer == .task && $0.title == "Known failure" } == true)
        #expect(loadedSnapshot?.selectedRecords.contains { $0.layer == .working && $0.tags.contains("runtime-working") } == true)
        #expect(toolCall.memoryRuntimeSnapshotID == snapshot.id)
    }

    @Test func unifiedMemoryBootstrapCarriesEpistemicStateIntoRenderedPrompt() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        settings.enableUnifiedMemoryRuntime = true

        let context = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: nil,
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix build"))],
            modelContext: try makeModelContext(),
            epistemicState: EpistemicState(
                frontiers: [
                    FrontierMemory(
                        frontierId: "f-1",
                        goal: "Fix build",
                        openClaim: "Need to confirm shared scheme",
                        uncertaintyType: .tooling,
                        impactLevel: .high,
                        suggestedProbe: "Run xcodebuild -list",
                        stopCondition: "Scheme confirmed"
                    )
                ]
            ),
            influenceTrace: MemoryInfluenceTrace(activatedMemoryIDs: ["f-1"], rankedActionIDs: ["Run xcodebuild -list"]),
            coordinator: MemoryRuntimeCoordinator.makeForTests(unifiedRecords: [
                MemoryRecord.fixture(id: "task-1", layer: .task, scope: .session(id: "s1"), title: "Known failure")
            ])
        )

        #expect(context?.epistemicState.frontiers.first?.frontierId == "f-1")
        #expect(context?.renderedPrompt.contains("Need to confirm shared scheme") == true)
        #expect(context?.runtimeSnapshot?.influenceTrace.rankedActionIDs == ["Run xcodebuild -list"])
    }

    @Test func taskMemoryEpisodeDeltaRecordsStillRenderIntoBootstrapPrompt() async throws {
        let service = ClaudeService()
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)

        try service.persistTaskMemoryExtraction(
            sessionId: "session-episode",
            extracted: {
                var memory = TaskMemory(sessionId: "session-episode")
                memory.confirmedFacts = ["Build uses xcodebuild"]
                memory.failedAttempts = [FailedAttempt(action: "Run tests", reason: "Scheme missing")]
                return memory
            }(),
            store: store,
            timestamp: Date(timeIntervalSince1970: 100)
        )

        let prompt = try service.taskMemoryPromptText(sessionId: "session-episode", store: store)

        #expect(prompt.contains("Build uses xcodebuild"))
        #expect(prompt.contains("Scheme missing"))
    }

    @Test func prepareContextSynthesizesWorkingMemoryWhenNoWorkingRecordsExist() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            unifiedRecords: [MemoryRecord.fixture(id: "semantic-1", layer: .semantic, kind: .semantic, title: "North tower curfew")]
        )

        let context = try await coordinator.prepareContext(for: .init(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Continue the chapter and keep the night curfew consistent",
            taskKind: .creativeWriting,
            projectId: "project-1",
            workspaceRoot: nil,
            contextBudget: 4000
        ))

        #expect(context.records.contains {
            $0.layer == .working &&
            $0.tags.contains("runtime-working") &&
            $0.summary.contains("Continue the chapter")
        })
    }

    @Test func unifiedBootstrapRespectsFeatureFlag() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        settings.enableUnifiedMemoryRuntime = false

        let context = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: nil,
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix build"))],
            modelContext: try makeModelContext()
        )

        #expect(context == nil)
    }

    @Test func memoryRuntimeSupportsRMSPathWithoutBreakingCompatibilityFallback() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        settings.enableUnifiedMemoryRuntime = true
        settings.enableEpistemicExtraction = true
        settings.enableRMSRetrieval = true
        settings.enableBridgeExpansion = true
        settings.enableLegacyMemoryCompatibility = false

        let coordinator = MemoryRuntimeCoordinator(
            featureConfiguration: .init(
                enableAdmissionV2: true,
                enableGoalConditionedRetrieval: true,
                enableBridgeExpansion: true,
                enableLifecycleManager: true,
                enableExperienceDistillation: false
            ),
            unifiedRecordsProvider: { _ in
                [
                    MemoryRecord.fixture(
                        id: "failure-1",
                        layer: .task,
                        kind: .working,
                        scope: .session(id: "s1"),
                        title: "Build failure",
                        summary: "xcodebuild scheme failure",
                        verificationStatus: .verified,
                        tags: ["failed-attempt"],
                        evidenceAnchors: [
                            MemoryEvidenceAnchor(kind: .toolCall, identifier: "tool-1", summary: "Ran xcodebuild test")
                        ],
                        admissionExplanation: MemoryAdmissionExplanation(
                            score: MemoryAdmissionScore(total: 0.92, route: .hotPath),
                            featureVector: MemoryAdmissionFeatureVector(
                                futureUtility: 0.8,
                                factualConfidence: 1,
                                novelty: 0.6,
                                temporalRecency: 1,
                                taskRelevance: 1,
                                verificationSupport: 1,
                                privacyRisk: 0,
                                driftRisk: 0.1
                            ),
                            reasons: ["verified tool evidence"]
                        ),
                        lifecycleTier: .hot,
                    ),
                    MemoryRecord.fixture(
                        id: "recovery-1",
                        layer: .task,
                        kind: .working,
                        scope: .session(id: "s1"),
                        title: "Re-run with shared scheme",
                        summary: "Share the scheme before building",
                        verificationStatus: .verified,
                        tags: ["tactic-kernel"],
                        lifecycleTier: .warm
                    )
                ]
            }
        )

        let context = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: nil,
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix failing build and verify tests"))],
            modelContext: try makeModelContext(),
            coordinator: coordinator
        )

        let snapshot = try #require(context?.runtimeSnapshot)
        #expect(snapshot.selectedRecords.isEmpty == false)
        #expect(snapshot.plan.retrievalIntent?.phase == .verification)
        #expect(snapshot.bridgeExpansions.isEmpty == false)
        #expect(snapshot.metrics.workingSetCost > 0)

        let legacyCoordinator = MemoryRuntimeCoordinator(
            featureConfiguration: .init(
                enableAdmissionV2: false,
                enableGoalConditionedRetrieval: false,
                enableBridgeExpansion: false,
                enableLifecycleManager: false,
                enableExperienceDistillation: false
            ),
            unifiedRecordsProvider: { _ in
                [
                    MemoryRecord.fixture(
                        id: "legacy-1",
                        layer: .task,
                        kind: .working,
                        scope: .session(id: "s1"),
                        title: "Legacy build fact",
                        summary: "Build uses xcodebuild",
                        verificationStatus: .verified,
                        tags: ["failed-attempt"],
                        lifecycleTier: .hot
                    )
                ]
            }
        )

        let legacyContext = try await service.buildUnifiedMemoryBootstrap(
            settings: settings,
            session: nil,
            sessionId: "s1",
            messages: [MessageParameter.Message(role: .user, content: .text("Fix failing build and verify tests"))],
            modelContext: try makeModelContext(),
            coordinator: legacyCoordinator
        )

        let legacySnapshot = try #require(legacyContext?.runtimeSnapshot)
        #expect(legacySnapshot.plan.retrievalIntent == nil)
        #expect(legacySnapshot.bridgeExpansions.isEmpty)
        #expect(legacySnapshot.metrics.workingSetCost == 0)
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