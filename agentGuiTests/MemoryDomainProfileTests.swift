import Foundation
import Testing
@testable import agentGui

struct MemoryDomainProfileTests {
    @Test func registryExposesCreativeCodingAndUserPreferenceProfiles() async throws {
        let registry = MemoryDomainProfileRegistry()
        let ids = registry.allProfiles.map(\.id)

        #expect(ids.contains("creative-writing"))
        #expect(ids.contains("coding-task"))
        #expect(ids.contains("user-preferences"))
    }

    @Test func codingRequestSelectsCodingAndUserPreferenceProfiles() async throws {
        let registry = MemoryDomainProfileRegistry()
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix the failing build and rerun tests",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 6000
        )

        let selected = registry.profiles(for: request).map(\.id)
        #expect(selected == ["coding-task", "user-preferences"])
    }

    @Test func codingProfileExposesConsolidationRulesAndReadMostlyPolicy() async throws {
        let profile = try #require(MemoryDomainProfileRegistry().allProfiles.first(where: { $0.id == "coding-task" }))
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        #expect(profile.writePolicy(for: request) == .readMostly)
        #expect(profile.consolidationRules().contains { $0.id == "coding-failure-chain" })
    }
}