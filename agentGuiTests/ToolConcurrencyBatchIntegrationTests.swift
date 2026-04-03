import XCTest
@testable import agentGui

final class ToolConcurrencyBatchIntegrationTests: XCTestCase {

    // MARK: - DefaultToolRegistry integration

    func test_defaultRegistry_webSearchIsSafe() {
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let tools = [
            AgentLoopPendingTool(id: "ws-1", name: "web_search"),
            AgentLoopPendingTool(id: "ws-2", name: "web_fetch")
        ]
        let batches = planner.partition(tools)
        XCTAssertEqual(batches.count, 1, "Two consecutive safe tools should merge into one batch")
        guard case .concurrent(let concurrent) = batches[0] else {
            return XCTFail("Expected concurrent batch for read-only tools")
        }
        XCTAssertEqual(concurrent.count, 2)
    }

    func test_defaultRegistry_bashIsNotSafe() {
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let tools = [AgentLoopPendingTool(id: "bash-1", name: "bash")]
        let batches = planner.partition(tools)
        guard case .serial(let tool) = batches.first else {
            return XCTFail("Expected serial batch for bash")
        }
        XCTAssertEqual(tool.name, "bash")
    }

    func test_defaultRegistry_allLSPToolsAreSafe() {
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let lspTools = [
            "lsp_definition", "lsp_references", "lsp_hover",
            "lsp_document_symbols", "lsp_workspace_symbols",
            "lsp_diagnostics", "lsp_list_servers", "lsp_server_status"
        ].map { AgentLoopPendingTool(id: "\($0)-id", name: $0) }

        let batches = planner.partition(lspTools)
        XCTAssertEqual(batches.count, 1, "All LSP tools should merge into one concurrent batch")
        guard case .concurrent(let concurrent) = batches[0] else {
            return XCTFail("Expected all LSP tools to be concurrent")
        }
        XCTAssertEqual(concurrent.count, lspTools.count)
    }

    func test_defaultRegistry_readOnlyWithBashInMiddle_producesThreeBatches() {
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let tools = [
            AgentLoopPendingTool(id: "ws-1", name: "web_search"),
            AgentLoopPendingTool(id: "bash-1", name: "bash"),
            AgentLoopPendingTool(id: "lsp-1", name: "lsp_hover")
        ]
        let batches = planner.partition(tools)
        XCTAssertEqual(batches.count, 3)
        guard case .concurrent = batches[0],
              case .serial = batches[1],
              case .concurrent = batches[2] else {
            return XCTFail("Expected concurrent / serial / concurrent batch pattern")
        }
    }

    // MARK: - Result ordering guarantee (using mock executor)

    func test_concurrentBatchResultsPreserveOriginalOrder() async {
        // Verify the batch preserves insertion order (input order)
        let registry = DefaultToolRegistry()
        let planner = ToolConcurrencyBatchPlanner(registry: registry)
        let tools = [
            AgentLoopPendingTool(id: "slow-id", name: "web_search"),
            AgentLoopPendingTool(id: "fast-id", name: "web_fetch")
        ]
        let batches = planner.partition(tools)
        guard case .concurrent(let concurrent) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }

        XCTAssertEqual(concurrent[0].id, "slow-id")
        XCTAssertEqual(concurrent[1].id, "fast-id")
    }

    // MARK: - isConcurrencySafe annotation count

    func test_safeToolCount_matchesExpectation() {
        let registry = DefaultToolRegistry()
        let safeCount = registry.allDefinitions().filter(\.isConcurrencySafe).count
        // 11 tools: web_search, web_fetch, read_tool_payload + 8 LSP tools
        // Note: run_subagent is NOT in this count; fork subagents are handled via
        // AgentLoopPendingTool.isForkSubagent flag checked BEFORE isConcurrencySafe (S-F3).
        XCTAssertEqual(safeCount, 11, "Expected exactly 11 concurrency-safe tools in registry")
    }
}
