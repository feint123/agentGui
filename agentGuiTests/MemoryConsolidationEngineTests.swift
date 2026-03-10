import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryConsolidationEngineTests {
    @Test func codingOutcomePromotesVerifiedFactsAndFailures() async throws {
        let outcome = MemoryRuntimeOutcome(
            request: MemoryRuntimeRequest(
                sessionId: "s1",
                threadId: "t1",
                workflowRunId: nil,
                userRequest: "Fix build",
                taskKind: .coding,
                projectId: nil,
                workspaceRoot: "/tmp/repo",
                contextBudget: 4000
            ),
            records: [
                MemoryRecord.fixture(
                    layer: .working,
                    kind: .working,
                    title: "Build uses xcodebuild",
                    verificationStatus: .verified,
                    tags: ["confirmed-fact"]
                ),
                MemoryRecord.fixture(
                    layer: .task,
                    kind: .working,
                    title: "Attempt 1",
                    summary: "Undefined symbol persists",
                    verificationStatus: .failed,
                    tags: ["failed-attempt"]
                ),
                MemoryRecord.fixture(
                    layer: .task,
                    kind: .working,
                    title: "Attempt 2",
                    summary: "Undefined symbol persists",
                    verificationStatus: .failed,
                    tags: ["failed-attempt"]
                )
            ]
        )

        let candidates = try await MemoryConsolidationEngine().consolidate(outcome)

        #expect(candidates.contains { $0.layer == .task && $0.title == "Build uses xcodebuild" })
        #expect(candidates.contains { $0.layer == .episodic && $0.kind == .episodic })
    }

    @Test func creativeOutcomeKeepsSpeculativeFactsOutOfSemanticLayer() async throws {
        let outcome = MemoryRuntimeOutcome(
            request: MemoryRuntimeRequest(
                sessionId: "s1",
                threadId: "t1",
                workflowRunId: nil,
                userRequest: "Continue chapter",
                taskKind: .creativeWriting,
                projectId: "project-1",
                workspaceRoot: nil,
                contextBudget: 4000
            ),
            records: [
                MemoryRecord.fixture(
                    layer: .semantic,
                    kind: .semantic,
                    domainProfile: "creative-writing",
                    scope: .project(id: "project-1"),
                    title: "顾沉爱上林澈",
                    summary: "顾沉可能爱上林澈",
                    verificationStatus: .unverified
                ),
                MemoryRecord.fixture(
                    layer: .episodic,
                    kind: .episodic,
                    domainProfile: "creative-writing",
                    scope: .project(id: "project-1"),
                    title: "北塔夜巡",
                    verificationStatus: .verified
                )
            ]
        )

        let candidates = try await MemoryConsolidationEngine().consolidate(outcome)

        #expect(!candidates.contains { $0.layer == .semantic && $0.title == "顾沉爱上林澈" })
        #expect(candidates.contains { $0.layer == .episodic && $0.title == "北塔夜巡" })
    }
}