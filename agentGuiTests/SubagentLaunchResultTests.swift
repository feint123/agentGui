// agentGuiTests/SubagentLaunchResultTests.swift
import XCTest
@testable import agentGui

final class SubagentLaunchResultTests: XCTestCase {

    func test_asyncVariant_hasCorrectFields() {
        let agentID = UUID()
        let result = SubagentLaunchResult.async(agentID: agentID, description: "Running tests")

        guard case .async(let id, let desc) = result else {
            return XCTFail("Expected .async case")
        }
        XCTAssertEqual(id, agentID)
        XCTAssertEqual(desc, "Running tests")
    }

    func test_syncVariant_hasCorrectMessage() {
        let msg = AgentMessage.text("done", sender: "explore", metadata: [:])
        let result = SubagentLaunchResult.sync(message: msg)

        guard case .sync(let m) = result else {
            return XCTFail("Expected .sync case")
        }
        XCTAssertEqual(m.content.rawText, "done")
    }

    func test_asyncVariant_toolResultText_containsAgentID() {
        let agentID = UUID()
        let result = SubagentLaunchResult.async(agentID: agentID, description: "Verifying")
        XCTAssertTrue(result.toolResultText.contains(agentID.uuidString))
    }

    func test_syncVariant_toolResultText_isMessageText() {
        let msg = AgentMessage.text("finished", sender: "worker", metadata: [:])
        let result = SubagentLaunchResult.sync(message: msg)
        XCTAssertEqual(result.toolResultText, "finished")
    }
}
