import Foundation
import Testing
@testable import agentGui

struct AgentCatalogTests {

    @Test func catalogContainsOnlyThreeBuiltInAgents() throws {
        let catalog = try AgentCatalog(loader: AgentDefinitionLoader(), bundle: Bundle.main)

        #expect(catalog.all.map(\.name).sorted() == ["explore", "verifier", "worker"])
        #expect(catalog.all.count == 3)
    }

    @Test func catalogFindsExpectedAgentsAndRejectsLegacyNames() throws {
        let catalog = try AgentCatalog(loader: AgentDefinitionLoader(), bundle: Bundle.main)

        #expect(catalog.find(named: "explore") != nil)
        #expect(catalog.find(named: "worker") != nil)
        #expect(catalog.find(named: "verifier") != nil)
        #expect(catalog.find(named: "coder") == nil)
        #expect(catalog.find(named: "planner") == nil)
    }

    @Test func subagentVisibleAgentNameTextMatchesCatalog() throws {
        let catalog = try AgentCatalog(loader: AgentDefinitionLoader(), bundle: Bundle.main)
        let visibleNames = catalog.subagentInvocableAgents.map(\.name).sorted()

        #expect(visibleNames == ["explore", "verifier", "worker"])
        #expect(catalog.agentNameListText == "explore | worker | verifier")
    }
}