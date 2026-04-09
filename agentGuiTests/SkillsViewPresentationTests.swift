// agentGuiTests/SkillsViewPresentationTests.swift
import XCTest
@testable import agentGui

final class SkillsViewPresentationTests: XCTestCase {

    // MARK: - toggleIsVisible

    func test_toggleIsVisible_userSkill_true() {
        let skill = makeSkill(loadedFrom: .user)
        XCTAssertTrue(SkillRowPresentation(skill: skill).toggleIsVisible)
    }

    func test_toggleIsVisible_projectSkill_true() {
        let skill = makeSkill(loadedFrom: .project)
        XCTAssertTrue(SkillRowPresentation(skill: skill).toggleIsVisible)
    }

    func test_toggleIsVisible_managedSkill_true() {
        let skill = makeSkill(loadedFrom: .managed)
        XCTAssertTrue(SkillRowPresentation(skill: skill).toggleIsVisible)
    }

    func test_toggleIsVisible_bundledSkill_false() {
        let skill = makeSkill(loadedFrom: .bundled)
        XCTAssertFalse(SkillRowPresentation(skill: skill).toggleIsVisible)
    }

    // MARK: - sourceLabel

    func test_sourceLabel_user() {
        XCTAssertEqual(SkillRowPresentation(skill: makeSkill(loadedFrom: .user)).sourceLabel, "用户")
    }

    func test_sourceLabel_project() {
        XCTAssertEqual(SkillRowPresentation(skill: makeSkill(loadedFrom: .project)).sourceLabel, "项目")
    }

    func test_sourceLabel_managed() {
        XCTAssertEqual(SkillRowPresentation(skill: makeSkill(loadedFrom: .managed)).sourceLabel, "管理")
    }

    func test_sourceLabel_bundled() {
        XCTAssertEqual(SkillRowPresentation(skill: makeSkill(loadedFrom: .bundled)).sourceLabel, "内置")
    }

    // MARK: - showForkBadge

    func test_showForkBadge_inlineContext_false() {
        let skill = makeSkill(executionContext: .inline)
        XCTAssertFalse(SkillRowPresentation(skill: skill).showForkBadge)
    }

    func test_showForkBadge_forkContext_true() {
        let skill = makeSkill(executionContext: .fork)
        XCTAssertTrue(SkillRowPresentation(skill: skill).showForkBadge)
    }

    // MARK: - versionText

    func test_versionText_nil_whenNoVersion() {
        let skill = makeSkill(version: nil)
        XCTAssertNil(SkillRowPresentation(skill: skill).versionText)
    }

    func test_versionText_present_whenVersionSet() {
        let skill = makeSkill(version: "1.2.3")
        XCTAssertEqual(SkillRowPresentation(skill: skill).versionText, "v1.2.3")
    }

    // MARK: - showArgumentHintTag

    func test_showArgumentHintTag_false_whenNil() {
        let skill = makeSkill(argumentHint: nil)
        XCTAssertFalse(SkillRowPresentation(skill: skill).showArgumentHintTag)
    }

    func test_showArgumentHintTag_true_whenPresent() {
        let skill = makeSkill(argumentHint: "分支名称")
        XCTAssertTrue(SkillRowPresentation(skill: skill).showArgumentHintTag)
    }

    // MARK: - showConditionalPathsBadge

    func test_showConditionalPathsBadge_false_whenPathsNil() {
        let skill = makeSkill(paths: nil)
        XCTAssertFalse(SkillRowPresentation(skill: skill).showConditionalPathsBadge)
    }

    func test_showConditionalPathsBadge_true_whenPathsPresent() {
        let skill = makeSkill(paths: ["**/*.swift"])
        XCTAssertTrue(SkillRowPresentation(skill: skill).showConditionalPathsBadge)
    }

    // MARK: - showWhenToUseDisclosure

    func test_showWhenToUseDisclosure_false_whenNil() {
        let skill = makeSkill(whenToUse: nil)
        XCTAssertFalse(SkillRowPresentation(skill: skill).showWhenToUseDisclosure)
    }

    func test_showWhenToUseDisclosure_false_whenEmpty() {
        let skill = makeSkill(whenToUse: "")
        XCTAssertFalse(SkillRowPresentation(skill: skill).showWhenToUseDisclosure)
    }

    func test_showWhenToUseDisclosure_true_whenPresent() {
        let skill = makeSkill(whenToUse: "当用户请求代码审查时")
        XCTAssertTrue(SkillRowPresentation(skill: skill).showWhenToUseDisclosure)
    }

    // MARK: - Helpers

    private func makeSkill(
        loadedFrom: SkillSource = .user,
        executionContext: SkillExecutionContext = .inline,
        version: String? = nil,
        argumentHint: String? = nil,
        paths: [String]? = nil,
        whenToUse: String? = nil
    ) -> Skill {
        let root = URL(fileURLWithPath: "/tmp/skills/test-skill")
        return Skill(
            directoryName: "test-skill",
            name: "Test Skill",
            description: "A test skill",
            path: root,
            contentURL: root.appendingPathComponent("SKILL.md"),
            whenToUse: whenToUse,
            argumentHint: argumentHint,
            executionContext: executionContext,
            version: version,
            paths: paths,
            loadedFrom: loadedFrom
        )
    }
}
