import Foundation
import Testing
@testable import agentGui

struct MemoryRuntimeCoreTests {
    @Test func memoryLayerOrderMatchesArchitecture() async throws {
        #expect(MemoryLayer.allCases == [.instant, .working, .task, .episodic, .semantic, .proceduralArchive])
    }

    @Test func agentLoopRunStateStartsWithoutVerificationState() async throws {
        let state = AgentLoopRunState()

        #expect(state.verificationState == nil)
        #expect(state.executionEvidence.isEmpty)
    }

    @Test func memoryScopeSupportsProjectAndSessionNamespaces() async throws {
        #expect(MemoryScope.project(id: "p1").namespace == "project:p1")
        #expect(MemoryScope.session(id: "s1").namespace == "session:s1")
    }

    @Test func memoryRecordCarriesRuntimeMetadata() async throws {
        let record = MemoryRecord(
            id: "rec_1",
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            scope: .session(id: "s1"),
            title: "Build failure",
            summary: "xcodebuild fails in agentGuiTests",
            payload: .text("Build failure"),
            source: .tool(name: "xcodebuild"),
            sourceRefs: [],
            confidence: 1.0,
            verificationStatus: .verified,
            retentionPolicy: .sessionBound,
            createdAt: Date(),
            updatedAt: Date(),
            lastAccessedAt: nil,
            supersededBy: nil,
            tags: ["build"]
        )

        #expect(record.layer == .task)
        #expect(record.kind == .working)
        #expect(record.scope.namespace == "session:s1")
    }
}