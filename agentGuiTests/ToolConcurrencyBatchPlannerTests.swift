import XCTest
@testable import agentGui

final class ToolConcurrencyBatchPlannerTests: XCTestCase {

    // MARK: - Helpers

    private func safeTool(_ name: String) -> AgentLoopPendingTool {
        AgentLoopPendingTool(id: name + "-id", name: name)
    }

    private func unsafeTool(_ name: String) -> AgentLoopPendingTool {
        AgentLoopPendingTool(id: name + "-id", name: name)
    }

    private func makePlanner(safeToolNames: Set<String>) -> ToolConcurrencyBatchPlanner {
        ToolConcurrencyBatchPlanner(isConcurrencySafe: { safeToolNames.contains($0) })
    }

    // MARK: - Empty input

    func test_empty_returnsEmpty() {
        let planner = makePlanner(safeToolNames: ["web_search"])
        let batches = planner.partition([])
        XCTAssertTrue(batches.isEmpty)
    }

    // MARK: - Single tool

    func test_singleSafeTool_returnsConcurrentBatch() {
        let planner = makePlanner(safeToolNames: ["web_search"])
        let batches = planner.partition([safeTool("web_search")])
        XCTAssertEqual(batches.count, 1)
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "web_search")
    }

    func test_singleUnsafeTool_returnsSerialBatch() {
        let planner = makePlanner(safeToolNames: [])
        let batches = planner.partition([unsafeTool("bash")])
        XCTAssertEqual(batches.count, 1)
        guard case .serial(let tool) = batches[0] else {
            return XCTFail("Expected serial batch")
        }
        XCTAssertEqual(tool.name, "bash")
    }

    // MARK: - Consecutive safe tools merge

    func test_twoSafeTools_returnsSingleConcurrentBatch() {
        let planner = makePlanner(safeToolNames: ["web_search", "lsp_hover"])
        let batches = planner.partition([
            safeTool("web_search"),
            safeTool("lsp_hover")
        ])
        XCTAssertEqual(batches.count, 1)
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.count, 2)
    }

    func test_threeSafeTools_returnsSingleConcurrentBatch() {
        let planner = makePlanner(safeToolNames: ["web_search", "lsp_hover", "read_tool_payload"])
        let batches = planner.partition([
            safeTool("web_search"),
            safeTool("lsp_hover"),
            safeTool("read_tool_payload")
        ])
        XCTAssertEqual(batches.count, 1)
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.count, 3)
    }

    // MARK: - Mixed sequences

    func test_safeUnsafe_returnsTwoBatches() {
        let planner = makePlanner(safeToolNames: ["web_search"])
        let batches = planner.partition([
            safeTool("web_search"),
            unsafeTool("bash")
        ])
        XCTAssertEqual(batches.count, 2)
        guard case .concurrent(let safeTools) = batches[0] else {
            return XCTFail("Expected first batch to be concurrent")
        }
        XCTAssertEqual(safeTools[0].name, "web_search")
        guard case .serial(let unsafeTool) = batches[1] else {
            return XCTFail("Expected second batch to be serial")
        }
        XCTAssertEqual(unsafeTool.name, "bash")
    }

    func test_unsafeSafeSafe_returnsSerialThenConcurrent() {
        let planner = makePlanner(safeToolNames: ["web_search", "lsp_hover"])
        let batches = planner.partition([
            unsafeTool("bash"),
            safeTool("web_search"),
            safeTool("lsp_hover")
        ])
        XCTAssertEqual(batches.count, 2)
        guard case .serial(let first) = batches[0] else {
            return XCTFail("Expected first batch to be serial")
        }
        XCTAssertEqual(first.name, "bash")
        guard case .concurrent(let concurrent) = batches[1] else {
            return XCTFail("Expected second batch to be concurrent")
        }
        XCTAssertEqual(concurrent.count, 2)
    }

    func test_safeSafeUnsafeSafe_returnsThreeBatches() {
        let planner = makePlanner(safeToolNames: ["web_search", "read_tool_payload", "lsp_hover"])
        let batches = planner.partition([
            safeTool("web_search"),
            safeTool("read_tool_payload"),
            unsafeTool("str_replace_based_edit_tool"),
            safeTool("lsp_hover")
        ])
        XCTAssertEqual(batches.count, 3)
        // batch[0]: concurrent([web_search, read_tool_payload])
        // batch[1]: serial(str_replace_based_edit_tool)
        // batch[2]: concurrent([lsp_hover])
        guard case .concurrent(let first) = batches[0] else {
            return XCTFail("Expected first batch to be concurrent")
        }
        XCTAssertEqual(first.count, 2)
        guard case .serial(let second) = batches[1] else {
            return XCTFail("Expected second batch to be serial")
        }
        XCTAssertEqual(second.name, "str_replace_based_edit_tool")
        guard case .concurrent(let third) = batches[2] else {
            return XCTFail("Expected third batch to be concurrent")
        }
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third[0].name, "lsp_hover")
    }

    func test_twoUnsafeTools_returnsTwoSerialBatches() {
        let planner = makePlanner(safeToolNames: [])
        let batches = planner.partition([
            unsafeTool("bash"),
            unsafeTool("str_replace_based_edit_tool")
        ])
        XCTAssertEqual(batches.count, 2)
        guard case .serial(let first) = batches[0],
              case .serial(let second) = batches[1] else {
            return XCTFail("Expected two serial batches")
        }
        XCTAssertEqual(first.name, "bash")
        XCTAssertEqual(second.name, "str_replace_based_edit_tool")
    }

    // MARK: - Original order preservation in concurrent batch

    func test_concurrentBatchPreservesInputOrder() {
        let planner = makePlanner(safeToolNames: ["a", "b", "c"])
        let input = ["a", "b", "c"].map { safeTool($0) }
        let batches = planner.partition(input)
        guard case .concurrent(let tools) = batches[0] else {
            return XCTFail("Expected concurrent batch")
        }
        XCTAssertEqual(tools.map(\.name), ["a", "b", "c"])
    }

    // MARK: - isConcurrencySafe exception handling

    func test_whenSafetyCheckThrows_treatsAsUnsafe() {
        // Planner with a throwing closure: tool "boom" throws, must be treated as serial
        let planner = ToolConcurrencyBatchPlanner(isConcurrencySafe: { name in
            if name == "boom" { throw NSError(domain: "test", code: 1) }
            return true
        })
        let batches = planner.partition([safeTool("boom")])
        XCTAssertEqual(batches.count, 1)
        guard case .serial = batches[0] else {
            return XCTFail("Expected serial batch after safety check exception")
        }
    }
}
