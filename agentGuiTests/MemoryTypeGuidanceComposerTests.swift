import XCTest
@testable import agentGui

final class MemoryTypeGuidanceComposerTests: XCTestCase {

    private let composer = MemoryTypeGuidanceComposer()

    // MARK: - typesSection

    func test_typesSection_containsH2Header() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("## Types of memory"),
                      "应包含 H2 标题")
    }

    func test_typesSection_containsAllFourTypeNames() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("<name>user</name>"),      "缺少 user 类型")
        XCTAssertTrue(section.contains("<name>feedback</name>"),  "缺少 feedback 类型")
        XCTAssertTrue(section.contains("<name>project</name>"),   "缺少 project 类型")
        XCTAssertTrue(section.contains("<name>reference</name>"), "缺少 reference 类型")
    }

    func test_typesSection_containsWhenToSave_forUser() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("<when_to_save>"),
                      "应包含 when_to_save 标签")
    }

    func test_typesSection_containsHowToUse_forEachType() {
        let section = composer.typesSection()
        let tagCount = section.components(separatedBy: "<how_to_use>").count - 1
        XCTAssertEqual(tagCount, 4, "四种类型都应有 how_to_use，实际 \(tagCount) 个")
    }

    func test_typesSection_containsExamples() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("<examples>"), "应包含 examples 标签")
    }

    func test_typesSection_feedbackContainsBodyStructure() {
        let section = composer.typesSection()
        XCTAssertTrue(section.contains("<body_structure>"),
                      "feedback 和 project 类型应有 body_structure")
    }

    // MARK: - whatNotToSaveSection

    func test_whatNotToSaveSection_containsH2Header() {
        let section = composer.whatNotToSaveSection()
        XCTAssertTrue(section.contains("## What NOT to save in memory"))
    }

    func test_whatNotToSaveSection_mentionsCodePatterns() {
        let section = composer.whatNotToSaveSection()
        XCTAssertTrue(section.contains("Code patterns"),
                      "应明确排除代码模式等可推导内容")
    }

    func test_whatNotToSaveSection_mentionsGitHistory() {
        let section = composer.whatNotToSaveSection()
        XCTAssertTrue(section.contains("Git history") || section.contains("git log"),
                      "应明确排除 git 历史")
    }

    // MARK: - compose（整合输出）

    func test_compose_returnsBothSections() {
        let full = composer.compose()
        XCTAssertTrue(full.contains("## Types of memory"))
        XCTAssertTrue(full.contains("## What NOT to save in memory"))
    }

    func test_compose_typesSection_precedesWhatNotToSave() {
        let full = composer.compose()
        let typesRange    = full.range(of: "## Types of memory")!
        let whatNotRange  = full.range(of: "## What NOT to save in memory")!
        XCTAssertLessThan(typesRange.lowerBound, whatNotRange.lowerBound,
                          "Types 节应在 What NOT to save 节之前")
    }

    func test_compose_isNotEmpty() {
        XCTAssertFalse(composer.compose().isEmpty)
    }
}
