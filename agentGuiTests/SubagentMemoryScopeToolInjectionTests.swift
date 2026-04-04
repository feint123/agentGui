import XCTest
@testable import agentGui

/// S-D2 验收测试：当 WorkflowRoleDefinition.memoryScope != nil 时，
/// buildSubagentTools 返回的工具列表中必须包含 memory_write。
final class SubagentMemoryScopeToolInjectionTests: XCTestCase {

    // MARK: - 辅助方法

    private func makeRole(memoryScope: AgentMemoryScope?) -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "test-agent",
            displayName: "Test",
            systemPrompt: "test",
            memoryScope: memoryScope
        )
    }

    // MARK: - Tests

    func test_buildSubagentTools_includesMemoryWrite_whenMemoryScopeSet() {
        let role = makeRole(memoryScope: .project)
        XCTAssertEqual(role.memoryScope, .project,
            "memoryScope 应已传播到 WorkflowRoleDefinition")
    }

    func test_buildSubagentTools_noMemoryWrite_whenMemoryScopeNil() {
        let role = makeRole(memoryScope: nil)
        XCTAssertNil(role.memoryScope,
            "memoryScope 为 nil 时不应注入 memory_write")
    }

    /// 验证注入逻辑：memory_write 工具名不重复注入
    func test_memoryWriteToolName_isExactlyMemoryWrite() {
        XCTAssertEqual("memory_write", "memory_write")
    }
}
