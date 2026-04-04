import XCTest
@testable import agentGui

final class AgentMemoryPathResolverTests: XCTestCase {

    // MARK: - 测试用根路径（避免污染真实目录）

    private var fakeHome: URL!
    private var fakeWorkspace: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
        fakeHome = tmp.appendingPathComponent("FakeHome_\(UUID().uuidString)", isDirectory: true)
        fakeWorkspace = tmp.appendingPathComponent("FakeWorkspace_\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - memoryDir — user scope

    func test_memoryDir_userScope_usesAgentguiDir() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryDir(agentType: "explore", scope: .user)
        // ~fakeHome/.agentgui/agent-memory/explore/
        XCTAssertEqual(
            result.path,
            fakeHome.appendingPathComponent(".agentgui/agent-memory/explore").path
        )
    }

    func test_memoryDir_userScope_trailingDirectoryFlag() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryDir(agentType: "explore", scope: .user)
        XCTAssertTrue(result.hasDirectoryPath, "memoryDir URL 应有 isDirectory=true 语义")
    }

    // MARK: - memoryDir — project scope

    func test_memoryDir_projectScope_usesWorkspaceRoot() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryDir(agentType: "worker", scope: .project)
        // <workspace>/.agentgui/agent-memory/worker/
        XCTAssertEqual(
            result.path,
            fakeWorkspace.appendingPathComponent(".agentgui/agent-memory/worker").path
        )
    }

    // MARK: - memoryDir — local scope

    func test_memoryDir_localScope_usesAgentMemoryLocal() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryDir(agentType: "verifier", scope: .local)
        // <workspace>/.agentgui/agent-memory-local/verifier/
        XCTAssertEqual(
            result.path,
            fakeWorkspace.appendingPathComponent(".agentgui/agent-memory-local/verifier").path
        )
    }

    // MARK: - memoryIndexURL

    func test_memoryIndexURL_appendsMEMORYmd() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryIndexURL(agentType: "explore", scope: .user)
        XCTAssertEqual(result.lastPathComponent, "MEMORY.md")
        XCTAssertTrue(result.path.hasSuffix("/explore/MEMORY.md"))
    }

    // MARK: - sanitize — 正常情况

    func test_sanitize_noSpecialChars_returnsUnchanged() {
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("explore"),  "explore")
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("worker"),   "worker")
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("my-agent"), "my-agent")
    }

    func test_sanitize_colonReplacedWithDash() {
        // 对齐 Claude Code sanitizeAgentTypeForPath: "my-plugin:my-agent" → "my-plugin-my-agent"
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("my-plugin:my-agent"), "my-plugin-my-agent")
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("ns:explore"), "ns-explore")
    }

    // MARK: - sanitize — 路径遍历防护（安全约束）

    func test_sanitize_slashIsRejected() {
        XCTAssertNil(AgentMemoryPathResolver.sanitize("foo/bar"),
                     "含 / 的代理类型名应拒绝（路径遍历防护）")
    }

    func test_sanitize_dotDotIsRejected() {
        XCTAssertNil(AgentMemoryPathResolver.sanitize("../evil"))
        XCTAssertNil(AgentMemoryPathResolver.sanitize(".."))
        XCTAssertNil(AgentMemoryPathResolver.sanitize("a/../b"))
    }

    func test_sanitize_dotPrefixIsRejected() {
        // 防止隐藏文件名攻击，如 ".env"
        XCTAssertNil(AgentMemoryPathResolver.sanitize(".hidden"))
        XCTAssertNil(AgentMemoryPathResolver.sanitize(".agent"))
    }

    func test_sanitize_emptyStringIsRejected() {
        XCTAssertNil(AgentMemoryPathResolver.sanitize(""))
    }

    func test_sanitize_whitespaceOnlyIsRejected() {
        XCTAssertNil(AgentMemoryPathResolver.sanitize("   "))
    }

    // MARK: - memoryDir 使用 sanitized 名称

    func test_memoryDir_sanitizesAgentType() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        // "ns:explore" 中的 : 被替换为 -
        let result = resolver.memoryDir(agentType: "ns:explore", scope: .user)
        XCTAssertTrue(result.path.hasSuffix("/ns-explore"), "代理类型名应经过 sanitize 处理")
    }

    func test_memoryDir_invalidAgentType_returnsNil() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        // "../evil" 含路径遍历，memoryDir 应返回 nil
        let result = resolver.memoryDirOrNil(agentType: "../evil", scope: .user)
        XCTAssertNil(result, "非法代理类型名应返回 nil，不允许路径遍历")
    }

    // MARK: - workspaceRoot nil 时 fallback 到当前目录

    func test_memoryDir_nilWorkspaceRoot_fallsBackToCwd() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: nil
        )
        // project scope 时 workspaceRoot nil → cwd
        let result = resolver.memoryDir(agentType: "explore", scope: .project)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let expected = cwd.appendingPathComponent(".agentgui/agent-memory/explore")
        XCTAssertEqual(result.path, expected.path)
    }

    // MARK: - Sendable

    func test_isSendable() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let _: @Sendable () -> URL = { resolver.memoryDir(agentType: "explore", scope: .user) }
    }
}
