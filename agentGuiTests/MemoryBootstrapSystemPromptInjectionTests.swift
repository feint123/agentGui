import XCTest
@testable import agentGui

final class MemoryBootstrapSystemPromptInjectionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BootstrapTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_compose_noMemoryFile_returnsNilSystemSection() {
        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()
        XCTAssertNil(result.systemPromptSection,
                     "MEMORY.md 不存在时 systemPromptSection 应为 nil")
    }

    func test_compose_emptyMemoryFile_returnsNilSystemSection() throws {
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try "   ".write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()
        XCTAssertNil(result.systemPromptSection,
                     "MEMORY.md 为空时 systemPromptSection 应为 nil")
    }

    func test_compose_withMemoryContent_returnsSection() throws {
        let content = "- [User Role](user_role_abc.md) — Senior iOS developer"
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()

        XCTAssertNotNil(result.systemPromptSection, "MEMORY.md 有内容时应返回注入节")
        XCTAssertTrue(result.systemPromptSection!.contains("User Role"),
                      "注入节应包含 MEMORY.md 内容")
    }

    func test_compose_section_containsMemoryTag() throws {
        let content = "- [Fact](fact.md) — test"
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()

        XCTAssertTrue(result.systemPromptSection!.contains("<memory>"),
                      "注入节应包含 <memory> 标签，对齐 Claude Code 格式")
        XCTAssertTrue(result.systemPromptSection!.contains("</memory>"),
                      "注入节应包含 </memory> 闭合标签")
    }

    func test_compose_section_containsYourMemoryHeader() throws {
        let content = "- [Fact](fact.md) — test"
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()

        XCTAssertTrue(result.systemPromptSection!.contains("## Your Memory"),
                      "注入节应以 ## Your Memory 开头")
    }

    func test_compose_section_containsDirExistsGuidance() throws {
        let content = "- [Fact](fact.md) — test"
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()

        XCTAssertTrue(result.systemPromptSection!.contains("memory_write"),
                      "注入节应提示使用 memory_write 工具")
    }
}
