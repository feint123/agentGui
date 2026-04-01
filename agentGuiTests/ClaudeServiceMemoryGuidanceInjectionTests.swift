import XCTest
@testable import agentGui

/// 验证 buildSystemPrompt 包含记忆类型指导
/// NOTE: 使用 ClaudeService.memoryGuidanceSection() 静态方法避免构造 SwiftData 实例
final class ClaudeServiceMemoryGuidanceInjectionTests: XCTestCase {

    func test_memoryGuidanceSection_containsMemorySystemHeader() {
        let section = ClaudeService.memoryGuidanceSection()
        XCTAssertTrue(section.contains("## Memory System"),
                      "memory guidance 应包含 ## Memory System 节")
    }

    func test_memoryGuidanceSection_containsTypesOfMemoryHeader() {
        let section = ClaudeService.memoryGuidanceSection()
        XCTAssertTrue(section.contains("## Types of memory"),
                      "memory guidance 应包含四类型指导节")
    }

    func test_memoryGuidanceSection_containsWhatNotToSaveHeader() {
        let section = ClaudeService.memoryGuidanceSection()
        XCTAssertTrue(section.contains("## What NOT to save in memory"),
                      "memory guidance 应包含 What NOT to save 节")
    }

    func test_memoryGuidanceSection_containsUserTypeTag() {
        let section = ClaudeService.memoryGuidanceSection()
        XCTAssertTrue(section.contains("<name>user</name>"))
    }

    func test_memoryGuidanceSection_containsFeedbackTypeTag() {
        let section = ClaudeService.memoryGuidanceSection()
        XCTAssertTrue(section.contains("<name>feedback</name>"))
    }

    func test_memoryGuidanceSection_memorySystem_precedesTypesOfMemory() {
        let section = ClaudeService.memoryGuidanceSection()
        guard let memorySystemRange = section.range(of: "## Memory System"),
              let typesRange = section.range(of: "## Types of memory") else {
            XCTFail("找不到 Memory System 或 Types of memory 节")
            return
        }
        XCTAssertLessThan(memorySystemRange.lowerBound, typesRange.lowerBound,
                          "## Memory System 应出现在 ## Types of memory 之前")
    }

    func test_memoryGuidanceSection_isNotEmpty() {
        XCTAssertFalse(ClaudeService.memoryGuidanceSection().isEmpty)
    }
}
