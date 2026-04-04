import XCTest
@testable import agentGui

/// 验证 AgentMemoryPathResolver 在 user scope 下的基目录与
/// ConfigDirectoryManager 的 agentGuiDir 对齐。
final class AgentMemoryPathResolverIntegrationTests: XCTestCase {

    func test_userScope_baseDir_matchesConfigDirectoryManager() {
        let configBase = ConfigDirectoryManager.shared.agentGuiDir

        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: configBase,
            workspaceRoot: nil
        )
        let memDir = resolver.memoryDir(agentType: "explore", scope: .user)

        // 期望路径：~/.agentgui/agent-memory/explore
        let expected = configBase
            .appendingPathComponent("agent-memory")
            .appendingPathComponent("explore")

        XCTAssertEqual(
            memDir.standardizedFileURL.path,
            expected.standardizedFileURL.path,
            "user scope 记忆目录应位于 ConfigDirectoryManager.agentGuiDir/agent-memory/<agentType>"
        )
    }

    func test_userScope_memoryIndexURL_isUnderAgentguiDir() {
        let configBase = ConfigDirectoryManager.shared.agentGuiDir
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: configBase,
            workspaceRoot: nil
        )
        let indexURL = resolver.memoryIndexURL(agentType: "explore", scope: .user)

        XCTAssertTrue(
            indexURL.path.hasPrefix(configBase.path),
            "MEMORY.md 路径应在 ~/.agentgui/ 树下"
        )
        XCTAssertEqual(indexURL.lastPathComponent, "MEMORY.md")
    }

    func test_userScope_doesNotConflictWithGlobalMemoryDir() {
        // 确认子代理记忆目录与主代理记忆目录（~/.agentgui/memory/）不重叠
        let configBase = ConfigDirectoryManager.shared.agentGuiDir
        let globalMemoryDir = ConfigDirectoryManager.shared.memoryDir  // ~/.agentgui/memory/

        let resolver = AgentMemoryPathResolver(agentguiBaseDir: configBase, workspaceRoot: nil)
        let agentMemDir = resolver.memoryDir(agentType: "explore", scope: .user)

        XCTAssertNotEqual(
            agentMemDir.standardizedFileURL.path,
            globalMemoryDir.standardizedFileURL.path,
            "子代理 user scope 目录（agent-memory/）不应与主代理全局记忆目录（memory/）相同"
        )
        XCTAssertFalse(
            agentMemDir.path.hasPrefix(globalMemoryDir.path),
            "子代理记忆目录不应是主代理记忆目录的子目录"
        )
    }
}
