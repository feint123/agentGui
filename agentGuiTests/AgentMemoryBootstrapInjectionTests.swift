//
//  AgentMemoryBootstrapInjectionTests.swift
//  agentGuiTests
//
//  S-D3: Tests for subagent memory bootstrap injection and global memory leak guard.
//

import XCTest
@testable import agentGui

final class AgentMemoryBootstrapInjectionTests: XCTestCase {

    // MARK: - 辅助

    private func makeTmpDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sd3-tests-\(UUID().uuidString)")
    }

    private func makeRole(
        name: String = "explore",
        memoryScope: AgentMemoryScope? = .user
    ) -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: name,
            displayName: "Test",
            systemPrompt: "You are test.",
            memoryScope: memoryScope
        )
    }

    // MARK: - composeSubagentMemorySection 基础行为

    func test_noScope_returnsNil() {
        let tmpDir = makeTmpDir()
        let role = makeRole(memoryScope: nil)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )
        XCTAssertNil(result, "memoryScope nil 时不应生成 memory 节")
    }

    func test_userScope_emptyMemoryDir_returnsNil() throws {
        let tmpDir = makeTmpDir()
        // 不写 MEMORY.md，但目录会被 compose 创建
        let role = makeRole(memoryScope: .user)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )
        XCTAssertNil(result, "MEMORY.md 为空或不存在时不应生成 memory 节")
    }

    func test_userScope_populatedMemory_returnsSection() throws {
        let tmpDir = makeTmpDir()
        // 在 user scope 路径手动写 MEMORY.md
        let memDir = tmpDir.appendingPathComponent("agent-memory/explore")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        let indexURL = memDir.appendingPathComponent("MEMORY.md")
        try "- ClaudeService.swift should not be edited directly".write(
            to: indexURL, atomically: true, encoding: .utf8
        )

        let role = makeRole(name: "explore", memoryScope: .user)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )

        XCTAssertNotNil(result, "MEMORY.md 有内容时应生成 memory 节")
        XCTAssertTrue(result!.contains("## Your Memory"),
                      "节标题应包含 '## Your Memory'")
        XCTAssertTrue(result!.contains("ClaudeService.swift"),
                      "节内容应包含记忆文本")
    }

    func test_projectScope_usesWorkspaceRoot() throws {
        let tmpDir = makeTmpDir()
        let workspaceRoot = makeTmpDir()
        // project scope 路径：<workspaceRoot>/.agentgui/agent-memory/<name>/
        let memDir = workspaceRoot
            .appendingPathComponent(".agentgui/agent-memory/explore")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        let indexURL = memDir.appendingPathComponent("MEMORY.md")
        try "- Use project scope memory".write(to: indexURL, atomically: true, encoding: .utf8)

        let role = makeRole(name: "explore", memoryScope: .project)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,   // agentguiBaseDir 未含 MEMORY.md
            workspaceRoot: workspaceRoot
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("project scope memory"))
    }

    func test_agentMemoryDirCreated_whenMemoryScopeSet() {
        let tmpDir = makeTmpDir()
        let role = makeRole(name: "explore", memoryScope: .user)
        _ = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )
        let expectedDir = tmpDir.appendingPathComponent("agent-memory/explore")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedDir.path),
            "调用后代理专属目录应已创建（确保 memory_write 工具可写）"
        )
    }

    func test_invalidAgentName_returnsNil() {
        // 名称含 "/" 无法 sanitize，应静默返回 nil
        let tmpDir = makeTmpDir()
        let role = makeRole(name: "foo/bar", memoryScope: .user)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )
        XCTAssertNil(result, "非法代理名称应静默返回 nil，不崩溃")
    }
}
