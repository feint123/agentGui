import Foundation
import Testing
@testable import agentGui

struct AgentDefinitionLoaderTests {

    @Test func loadsThreeBuiltInAgentDocuments() throws {
        let loader = AgentDefinitionLoader()
        let documents = try loader.loadBuiltInDocuments(from: Bundle.main)

        #expect(documents.map(\.name).sorted() == ["explore", "verifier", "worker"])
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