import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct AgentLoopBuiltInHookFactoryTests {

    @Test func builtInHookFactoryCreatesExpectedHookSetInOrder() async throws {
        let factory = AgentLoopBuiltInHookFactory()
        let state = AgentLoopBuiltInHookFactory.State()

        let hooks = factory.makeHooks(
            dependencies: .testValue(),
            state: state
        )

        #expect(hooks.map(\.id) == [
            "stream-projection",
            "memory-bootstrap",
            "tool-audit",
            "failure-classification",
            "reflection-handling",
            "business-observability"
        ])
    }

    @Test func memoryBootstrapHookMutatesSharedState() async throws {
        let factory = AgentLoopBuiltInHookFactory()
        let state = AgentLoopBuiltInHookFactory.State()
        let hooks = factory.makeHooks(
            dependencies: .testValue(
                memoryBootstrapLoader: { state in
                    state.memoryRuntimeProfiles = ["coding"]
                    state.memoryRuntimeLayers = ["task"]
                    return AgentLoopMessagePatch(
                        insertions: [
                            .init(
                                index: 0,
                                message: .init(role: .user, content: .text("bootstrap"))
                            )
                        ],
                        metadata: ["source": "test"]
                    )
                }
            ),
            state: state
        )

        let hook = try #require(hooks.first(where: { $0.id == "memory-bootstrap" }))
        let result = try await hook.perform(
            stage: .prepareRun,
            context: .testFactoryContext()
        )

        #expect(result == .messagePatch(.init(
            insertions: [
                .init(index: 0, message: .init(role: .user, content: .text("bootstrap")))
            ],
            metadata: ["source": "test"]
        )))
        #expect(state.memoryRuntimeProfiles == ["coding"])
        #expect(state.memoryRuntimeLayers == ["task"])
    }

    @Test func toolAuditHookReadsSharedRuntimeMetadata() async throws {
        let factory = AgentLoopBuiltInHookFactory()
        let state = AgentLoopBuiltInHookFactory.State()
        state.memoryRuntimeProfiles = ["coding"]
        state.memoryRuntimeLayers = ["task"]
        state.memoryRuntimeWarnings = ["warning"]
        state.memoryRuntimeSnapshotID = "snapshot-1"

        let hooks = factory.makeHooks(
            dependencies: .testValue(
                createToolCallRecord: { context, state in
                    let record = ToolCall(toolCallId: "call-1", kind: .execute)
                    record.title = context.pendingToolName
                    record.memoryRuntimeProfiles = state.memoryRuntimeProfiles
                    record.memoryRuntimeLayers = state.memoryRuntimeLayers
                    record.memoryRuntimeWarnings = state.memoryRuntimeWarnings
                    record.memoryRuntimeSnapshotID = state.memoryRuntimeSnapshotID
                    return record
                }
            ),
            state: state
        )

        let hook = try #require(hooks.first(where: { $0.id == "tool-audit" }))
        let result = try await hook.perform(
            stage: .willExecuteTool,
            context: .testFactoryToolContext()
        )

        switch result {
        case .toolCallRecord(let record):
            #expect(record.title == "bash")
            #expect(record.memoryRuntimeProfiles == ["coding"])
            #expect(record.memoryRuntimeLayers == ["task"])
            #expect(record.memoryRuntimeWarnings == ["warning"])
            #expect(record.memoryRuntimeSnapshotID == "snapshot-1")
        default:
            Issue.record("Expected tool call record")
        }
    }

    @Test func reflectionHandlingHookUsesSharedLastRound() async throws {
        let factory = AgentLoopBuiltInHookFactory()
        let state = AgentLoopBuiltInHookFactory.State()
        state.lastRound = AgentRound(roundIndex: 1)

        let hooks = factory.makeHooks(
            dependencies: .testValue(
                reflectionResolver: { _, state in
                    let roundIndex = state.lastRound?.roundIndex ?? -1
                    return AgentLoopReflectionResolution(
                        shouldRetry: true,
                        correctionPrompt: "round-\(roundIndex)"
                    )
                }
            ),
            state: state
        )

        let hook = try #require(hooks.first(where: { $0.id == "reflection-handling" }))
        let result = try await hook.perform(
            stage: .processReflection,
            context: .testFactoryReflectionContext()
        )

        #expect(result == .reflection(.init(shouldRetry: true, correctionPrompt: "round-1")))
    }
}

private extension AgentLoopBuiltInHookFactory.Dependencies {
    static func testValue(
        businessLogSink: BusinessLogSink? = nil,
        memoryBootstrapLoader: @escaping (AgentLoopBuiltInHookFactory.State) async throws -> AgentLoopMessagePatch? = { _ in nil },
        createToolCallRecord: @escaping (AgentLoopHookContext, AgentLoopBuiltInHookFactory.State) async throws -> ToolCall = { _, _ in
            ToolCall(toolCallId: "call-default", kind: .execute)
        },
        updateToolCallRecord: @escaping (AgentLoopHookContext, AgentLoopBuiltInHookFactory.State) async throws -> Void = { _, _ in },
        reflectionResolver: @escaping (AgentLoopHookContext, AgentLoopBuiltInHookFactory.State) async throws -> AgentLoopReflectionResolution? = { _, _ in
            nil
        }
    ) -> AgentLoopBuiltInHookFactory.Dependencies {
        AgentLoopBuiltInHookFactory.Dependencies(
            businessLogSink: businessLogSink,
            memoryBootstrapLoader: memoryBootstrapLoader,
            createToolCallRecord: createToolCallRecord,
            updateToolCallRecord: updateToolCallRecord,
            reflectionResolver: reflectionResolver
        )
    }
}

private extension AgentLoopHookContext {
    static func testFactoryContext() -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 0,
            phase: "executing"
        )
    }

    static func testFactoryToolContext() -> AgentLoopHookContext {
        var context = AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 0,
            phase: "awaitingToolResults"
        )
        context.pendingToolName = "bash"
        return context
    }

    static func testFactoryReflectionContext() -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 1,
            phase: "reflecting"
        )
    }
}