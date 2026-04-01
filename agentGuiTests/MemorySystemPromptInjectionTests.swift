import XCTest
@testable import agentGui

final class MemorySystemPromptInjectionTests: XCTestCase {

    // MARK: - MemoryTypeGuidanceComposer 两步保存说明

    func test_guidanceComposer_containsSavingInstructions_step1() {
        let section = MemoryTypeGuidanceComposer().compose()
        XCTAssertTrue(section.contains("Step 1") || section.contains("step 1"),
                      "保存说明应包含 Step 1（写话题文件）")
    }

    func test_guidanceComposer_containsSavingInstructions_step2() {
        let section = MemoryTypeGuidanceComposer().compose()
        XCTAssertTrue(section.contains("Step 2") || section.contains("step 2"),
                      "保存说明应包含 Step 2（更新 MEMORY.md 索引）")
    }

    func test_guidanceComposer_mentionsMEMORY_md() {
        let section = MemoryTypeGuidanceComposer().compose()
        XCTAssertTrue(section.contains("MEMORY.md"),
                      "保存说明应提到 MEMORY.md 索引文件")
    }

    func test_guidanceComposer_mentionsMemoryDir() {
        // system prompt 中应出现记忆目录路径信息
        let section = MemoryTypeGuidanceComposer().howToSaveSection()
        XCTAssertTrue(section.contains(".agentgui/memory") || section.contains("memory/"),
                      "应告知 agent 记忆目录位置")
    }

    // MARK: - buildSystemPrompt 中含 MEMORY.md 节（空索引场景）

    func test_buildSystemPrompt_containsMemorySystemSection() {
        let prompt = ClaudeService.memoryGuidanceSection()
        XCTAssertTrue(prompt.contains("## Memory System"),
                      "system prompt 应包含 ## Memory System 节")
    }

    func test_buildSystemPrompt_memoryIndexSectionKey() {
        // 当 MEMORY.md 存在时，system prompt 应包含 ## Your Memory Index
        // 使用纯文本静态测试：memoryIndexSection() 方法
        let section = ClaudeService.memoryIndexSection(content: "- [Test](t.md) — hook")
        XCTAssertTrue(section.contains("## Your Memory Index"))
        XCTAssertTrue(section.contains("- [Test]"))
    }

    func test_buildSystemPrompt_emptyMemoryIndex_sectionIsEmpty() {
        let section = ClaudeService.memoryIndexSection(content: "")
        XCTAssertTrue(section.isEmpty,
                      "索引内容为空时 memoryIndexSection 应返回空字符串")
    }
}
