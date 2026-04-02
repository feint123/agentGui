import XCTest
@testable import agentGui

final class SkillCatalogPromptRendererTests: XCTestCase {

    // MARK: - Constants

    func test_defaultCharBudget_is8000() {
        XCTAssertEqual(SkillCatalogPromptRenderer.defaultCharBudget, 8_000)
    }

    func test_maxListingDescChars_is250() {
        XCTAssertEqual(SkillCatalogPromptRenderer.maxListingDescChars, 250)
    }

    func test_renderer_init_defaultBudget() {
        let renderer = SkillCatalogPromptRenderer()
        XCTAssertEqual(renderer.charBudget, SkillCatalogPromptRenderer.defaultCharBudget)
    }

    func test_renderer_init_customBudget() {
        let renderer = SkillCatalogPromptRenderer(charBudget: 500)
        XCTAssertEqual(renderer.charBudget, 500)
    }

    // MARK: - entryDescription

    func test_entryDescription_noWhenToUse_returnsDescription() {
        let renderer = SkillCatalogPromptRenderer()
        let skill = Skill.fixture(description: "Review code quality")
        XCTAssertEqual(renderer.entryDescription(skill), "Review code quality")
    }

    func test_entryDescription_withWhenToUse_appendsWithDash() {
        let renderer = SkillCatalogPromptRenderer()
        let skill = Skill.fixture(
            description: "Review PR",
            whenToUse: "当用户请求代码审查时"
        )
        XCTAssertEqual(renderer.entryDescription(skill), "Review PR - 当用户请求代码审查时")
    }

    func test_entryDescription_truncatedAt250Chars() {
        let renderer = SkillCatalogPromptRenderer()
        let longDesc = String(repeating: "a", count: 300)
        let skill = Skill.fixture(description: longDesc)
        let result = renderer.entryDescription(skill)
        XCTAssertEqual(result.count, 250)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func test_entryDescription_exactlyAt250_notTruncated() {
        let renderer = SkillCatalogPromptRenderer()
        let desc = String(repeating: "b", count: 250)
        let skill = Skill.fixture(description: desc)
        let result = renderer.entryDescription(skill)
        XCTAssertEqual(result.count, 250)
        XCTAssertFalse(result.hasSuffix("…"))
    }

    // MARK: - renderSkillListing — 基础路径

    func test_renderSkillListing_emptyList_returnsEmpty() {
        let renderer = SkillCatalogPromptRenderer()
        XCTAssertEqual(renderer.renderSkillListing([]), "")
    }

    func test_renderSkillListing_singleSkill_formattedCorrectly() {
        let renderer = SkillCatalogPromptRenderer()
        let skill = Skill.fixture(name: "code-review", description: "Reviews code quality")
        let result = renderer.renderSkillListing([skill])
        XCTAssertEqual(result, "- code-review: Reviews code quality")
    }

    func test_renderSkillListing_multipleSkills_separatedByNewlines() {
        let renderer = SkillCatalogPromptRenderer()
        let skills = [
            Skill.fixture(name: "alpha", description: "Alpha skill"),
            Skill.fixture(name: "beta",  description: "Beta skill"),
        ]
        let result = renderer.renderSkillListing(skills)
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "- alpha: Alpha skill")
        XCTAssertEqual(lines[1], "- beta: Beta skill")
    }

    func test_renderSkillListing_withinBudget_noTruncation() {
        // budget = 1000 chars, two skills with short descriptions
        let renderer = SkillCatalogPromptRenderer(charBudget: 1_000)
        let skills = [
            Skill.fixture(name: "a", description: "Short desc A"),
            Skill.fixture(name: "b", description: "Short desc B"),
        ]
        let result = renderer.renderSkillListing(skills)
        XCTAssertTrue(result.contains("Short desc A"))
        XCTAssertTrue(result.contains("Short desc B"))
        XCTAssertLessThanOrEqual(result.count, 1_000)
    }

    // MARK: - renderSkillListing — 预算超出路径

    func test_renderSkillListing_overBudget_bundledSkillPreservedFull() {
        // budget = 80 chars: 一个 bundled skill(entry ~50 chars) + 一个 user skill(entry ~50 chars)
        // bundled 应保留完整，user 被截断或仅名称
        let renderer = SkillCatalogPromptRenderer(charBudget: 80)
        let bundledSkill = Skill.fixture(
            name: "bundled-tool",
            description: "Short",
            loadedFrom: .bundled
        )
        let userSkill = Skill.fixture(
            name: "user-tool",
            description: String(repeating: "x", count: 200),
            loadedFrom: .user
        )
        let result = renderer.renderSkillListing([bundledSkill, userSkill])
        // bundled 条目应完整存在
        XCTAssertTrue(result.contains("- bundled-tool: Short"),
                      "bundled skill entry should be preserved verbatim")
        // 整体长度不超过预算（generous slack for separator）
        XCTAssertLessThanOrEqual(result.count, 80 + 80)
    }

    func test_renderSkillListing_overBudget_nonBundledDescriptionTruncated() {
        // budget = 60 chars
        // skill name="abc" (3), desc=100 chars → full entry = "- abc: " + 100 = 107 chars > 60
        let renderer = SkillCatalogPromptRenderer(charBudget: 60)
        let skill = Skill.fixture(
            name: "abc",
            description: String(repeating: "y", count: 100),
            loadedFrom: .user
        )
        let result = renderer.renderSkillListing([skill])
        // must be ≤ budget (or close, given separator accounting)
        XCTAssertLessThanOrEqual(result.count, 65)
        // should still contain skill name
        XCTAssertTrue(result.contains("abc"))
    }

    func test_renderSkillListing_extremelyOverBudget_nonBundledNamesOnly() {
        // budget = 20 chars (even minDescLength=20 can't fit), forces names-only for non-bundled
        let renderer = SkillCatalogPromptRenderer(charBudget: 20)
        let userSkill = Skill.fixture(
            name: "my-skill",
            description: String(repeating: "z", count: 200),
            loadedFrom: .user
        )
        let result = renderer.renderSkillListing([userSkill])
        // names-only: "- my-skill" (no colon, no description)
        XCTAssertEqual(result, "- my-skill",
                       "extremely over-budget non-bundled skill → names-only, got: \(result)")
    }

    func test_renderSkillListing_onlyBundledSkills_allPreservedEvenOverBudget() {
        // budget = 10, but all skills are bundled → preserve full descriptions
        let renderer = SkillCatalogPromptRenderer(charBudget: 10)
        let s1 = Skill.fixture(name: "b1", description: "Long bundled desc", loadedFrom: .bundled)
        let s2 = Skill.fixture(name: "b2", description: "Another bundled desc", loadedFrom: .bundled)
        let result = renderer.renderSkillListing([s1, s2])
        XCTAssertTrue(result.contains("Long bundled desc"))
        XCTAssertTrue(result.contains("Another bundled desc"))
    }
}
