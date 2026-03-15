import Foundation
import Testing
@testable import agentGui

struct AgentDefinitionLoaderTests {

    @Test func loadsThreeBuiltInAgentDocuments() throws {
        let loader = AgentDefinitionLoader()
        let documents = try loader.loadBuiltInDocuments(from: Bundle.main)

        #expect(documents.map(\.name).sorted() == ["explore", "verifier", "worker"])
    }

    @Test func verifierDocumentDescribesStepByStepEvidenceDrivenVerification() throws {
        let loader = AgentDefinitionLoader()
        let documents = try loader.loadBuiltInDocuments(from: Bundle.main)
        let verifier = try #require(documents.first(where: { $0.name == "verifier" }))

        #expect(verifier.toolGroupNames == ["read_only_editor", "web", "shell"])
        #expect(verifier.body.contains("Step 1"))
        #expect(verifier.body.contains("Step 2"))
        #expect(verifier.body.contains("Step 3"))
        #expect(verifier.body.contains("read files"))
        #expect(verifier.body.contains("web"))
        #expect(verifier.body.contains("shell"))
        #expect(verifier.body.contains("real evidence"))
    }

    @Test func exploreDocumentPrioritizesStepByStepWorkspaceFirstSearchWithBoundedWebUse() throws {
        let loader = AgentDefinitionLoader()
        let documents = try loader.loadBuiltInDocuments(from: Bundle.main)
        let explore = try #require(documents.first(where: { $0.name == "explore" }))

        #expect(explore.toolGroupNames == ["read_only_editor", "web"])
        #expect(explore.body.contains("step by step"))
        #expect(explore.body.contains("workspace"))
        #expect(explore.body.contains("web"))
        #expect(explore.body.contains("Only use web"))
        #expect(explore.body.contains("local"))
    }

    @Test func rejectsUnknownToolGroup() throws {
        let loader = AgentDefinitionLoader()

        #expect(throws: AgentValidationError.self) {
            try loader.parseDocument(named: "bad.agent.md", raw: """
            ---
            name: explore
            display-name: 探索者
            description: desc
            argument-hint: hint
            tools: [imaginary_group]
            max-turns: 6
            user-invocable: false
            subagent-invocable: true
            output-contract: exploration_report
            ---
            # Role
            body
            """)
        }
    }

    @Test func rejectsEmptyBody() throws {
        let loader = AgentDefinitionLoader()

        #expect(throws: AgentValidationError.self) {
            try loader.parseDocument(named: "empty.agent.md", raw: """
            ---
            name: verifier
            display-name: 验证者
            description: desc
            argument-hint: hint
            tools: [read_only_editor]
            max-turns: 4
            user-invocable: false
            subagent-invocable: true
            output-contract: verification_report
            ---

            """)
        }
    }
}