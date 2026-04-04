import XCTest
import SwiftAnthropic
import SwiftData
@testable import agentGui

/// S-D4 验收测试：子代理 memory_write 目录作用域隔离
/// - 验证路由逻辑：subagentMemoryDir 存在时写入专属目录，nil 时写入全局目录
/// - 验证 AgentLoopRuntime 能携带 subagentMemoryDir
/// - 验证凭证内容被拒绝（凭证细节见 MemoryWriteCredentialGuardTests）
@MainActor
final class SubagentMemoryWriteIsolationTests: XCTestCase {

    // MARK: - 辅助

    private var globalMemDir: URL!
    private var agentMemDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd4-isolation-\(UUID().uuidString)")
        globalMemDir = base.appendingPathComponent("global-memory")
        agentMemDir  = base.appendingPathComponent("agent-memory/explore")
        try FileManager.default.createDirectory(at: globalMemDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentMemDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base = globalMemDir?.deletingLastPathComponent()
                                   .deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func buildInput(content: String, title: String = "Test") -> MessageResponse.Content.Input {
        ["content": .string(content), "title": .string(title)]
    }

    // MARK: - 路由测试（直接通过 executeFileMemoryWriteForTests 验证）

    func test_withAgentMemDir_writesFileToAgentDir() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "ClaudeService.swift is the main service class.", title: "ClaudeService knowledge"),
            memoryDir: agentMemDir
        )
        let filesInAgent = try FileManager.default.contentsOfDirectory(at: agentMemDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        let filesInGlobal = try FileManager.default.contentsOfDirectory(at: globalMemDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }

        XCTAssertEqual(filesInAgent.count, 1, "探索代理记忆应写入 agentMemDir")
        XCTAssertEqual(filesInGlobal.count, 0, "全局目录不应有文件泄漏")
    }

    func test_withGlobalMemDir_writesFileToGlobalDir() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "General project knowledge.", title: "General"),
            memoryDir: globalMemDir
        )
        let filesInGlobal = try FileManager.default.contentsOfDirectory(at: globalMemDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        let filesInAgent = try FileManager.default.contentsOfDirectory(at: agentMemDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }

        XCTAssertEqual(filesInGlobal.count, 1, "全局 memory_write 应写入 globalMemDir")
        XCTAssertEqual(filesInAgent.count, 0, "代理目录不应有文件泄漏")
    }

    // MARK: - AgentLoopRuntime 字段测试

    func test_agentLoopRuntime_subagentMemoryDir_propagates() throws {
        let schema = Schema([Session.self, Message.self, ToolCall.self, AgentRound.self, AppSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)

        let settings = AppSettings()
        settings.apiKey = "sk-ant-test"

        let expectedDir = agentMemDir!
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: "test-session",
            modelContext: ctx,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            subagentMemoryDir: expectedDir  // S-D4
        )

        XCTAssertEqual(runtime.subagentMemoryDir, expectedDir,
                       "AgentLoopRuntime 应正确携带 subagentMemoryDir")
    }

    func test_agentLoopRuntime_withoutSubagentMemoryDir_isNil() throws {
        let schema = Schema([Session.self, Message.self, ToolCall.self, AgentRound.self, AppSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        let settings = AppSettings()
        settings.apiKey = "sk-ant-test"

        // 默认构造不传 subagentMemoryDir
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: "test-session",
            modelContext: ctx,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil
        )

        XCTAssertNil(runtime.subagentMemoryDir,
                     "主代理 AgentLoopRuntime 应携带 nil 的 subagentMemoryDir（向后兼容）")
    }

    // MARK: - AgentMemoryPathResolver 集成验证

    func test_pathResolver_userScope_computesCorrectDir() {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd4-resolver-\(UUID().uuidString)")
        let resolver = AgentMemoryPathResolver(agentguiBaseDir: tmpBase, workspaceRoot: nil)
        let dir = resolver.memoryDir(agentType: "explore", scope: .user)
        XCTAssertTrue(dir.path.hasSuffix("agent-memory/explore"),
                      "user scope 应解析到 agent-memory/explore 目录：\(dir.path)")
    }

    func test_pathResolver_projectScope_computesCorrectDir() {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd4-resolver-project-\(UUID().uuidString)")
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd4-workspace-\(UUID().uuidString)")
        let resolver = AgentMemoryPathResolver(agentguiBaseDir: tmpBase, workspaceRoot: workspaceRoot)
        let dir = resolver.memoryDir(agentType: "explore", scope: .project)
        XCTAssertTrue(dir.path.contains(".agentgui/agent-memory/explore"),
                      "project scope 应解析到 .agentgui/agent-memory/explore：\(dir.path)")
    }

    // MARK: - S-D4 凭证保护快捷验证（详细测试见 MemoryWriteCredentialGuardTests）

    func test_credentialContent_isRejectedByExecute() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: ["content": .string("My key: sk-ant-api03-secretvalue")],
            memoryDir: agentMemDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"),
                      "凭证内容应被 executeFileMemoryWrite 拒绝: \(result)")
    }
}
