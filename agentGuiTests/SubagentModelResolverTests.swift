import XCTest
@testable import agentGui

final class SubagentModelResolverTests: XCTestCase {

    private let parentSonnet = "claude-sonnet-4-6"
    private let parentHaiku  = "claude-haiku-4-5"
    private let parentOpus   = "claude-opus-4-6"

    // MARK: - inherit

    func test_inherit_returnsParentModel() {
        let result = SubagentModelResolver.resolve(
            preference: .inherit,
            parentModelId: parentSonnet
        )
        XCTAssertEqual(result, parentSonnet)
    }

    func test_inherit_withOverride_returnsOverride() {
        let result = SubagentModelResolver.resolve(
            preference: .inherit,
            parentModelId: parentSonnet,
            overrideModelId: "claude-haiku-4-5"
        )
        XCTAssertEqual(result, "claude-haiku-4-5")
    }

    // MARK: - override 最高优先级

    func test_override_precedesPreference() {
        let result = SubagentModelResolver.resolve(
            preference: .haiku,
            parentModelId: parentSonnet,
            overrideModelId: "claude-opus-4-6"
        )
        XCTAssertEqual(result, "claude-opus-4-6")
    }

    func test_override_precedesInherit() {
        let result = SubagentModelResolver.resolve(
            preference: .inherit,
            parentModelId: parentSonnet,
            overrideModelId: "claude-opus-4-6"
        )
        XCTAssertEqual(result, "claude-opus-4-6")
    }

    func test_emptyOverride_treatedAsNil() {
        let result = SubagentModelResolver.resolve(
            preference: .inherit,
            parentModelId: parentSonnet,
            overrideModelId: ""
        )
        // 空字符串应视为 nil，回落到 inherit
        XCTAssertEqual(result, parentSonnet)
    }

    // MARK: - family-match 优化（与 Claude Code getAgentModel 对齐）

    func test_haiku_whenParentIsHaiku_returnsParentModel() {
        // 父代理已经是 haiku 系列 → 直接复用，不切换到 default haiku
        let result = SubagentModelResolver.resolve(
            preference: .haiku,
            parentModelId: parentHaiku
        )
        XCTAssertEqual(result, parentHaiku,
            "父代理已是 haiku 系列，应返回父代理 ID 而非固定默认值")
    }

    func test_sonnet_whenParentIsSonnet_returnsParentModel() {
        let result = SubagentModelResolver.resolve(
            preference: .sonnet,
            parentModelId: parentSonnet
        )
        XCTAssertEqual(result, parentSonnet)
    }

    func test_opus_whenParentIsOpus_returnsParentModel() {
        let result = SubagentModelResolver.resolve(
            preference: .opus,
            parentModelId: parentOpus
        )
        XCTAssertEqual(result, parentOpus)
    }

    // MARK: - preference → 默认 ID 映射（父代理非该系列）

    func test_haiku_whenParentIsSonnet_returnsDefaultHaikuId() {
        let result = SubagentModelResolver.resolve(
            preference: .haiku,
            parentModelId: parentSonnet
        )
        XCTAssertEqual(result, SubagentModelResolver.defaultHaikuModelId,
            "haiku preference，父代理非 haiku 系列，应回落到默认 haiku ID")
    }

    func test_sonnet_whenParentIsHaiku_returnsDefaultSonnetId() {
        let result = SubagentModelResolver.resolve(
            preference: .sonnet,
            parentModelId: parentHaiku
        )
        XCTAssertEqual(result, SubagentModelResolver.defaultSonnetModelId)
    }

    func test_opus_whenParentIsSonnet_returnsDefaultOpusId() {
        let result = SubagentModelResolver.resolve(
            preference: .opus,
            parentModelId: parentSonnet
        )
        XCTAssertEqual(result, SubagentModelResolver.defaultOpusModelId)
    }

    // MARK: - family detection（跨版本 ID）

    func test_haiku_detectsOlderHaikuId() {
        // claude-3-5-haiku-latest 也属于 haiku 系列
        let result = SubagentModelResolver.resolve(
            preference: .haiku,
            parentModelId: "claude-3-5-haiku-latest"
        )
        XCTAssertEqual(result, "claude-3-5-haiku-latest")
    }

    func test_sonnet_detectsLegacySonnetId() {
        let result = SubagentModelResolver.resolve(
            preference: .sonnet,
            parentModelId: "claude-3-5-sonnet-latest"
        )
        XCTAssertEqual(result, "claude-3-5-sonnet-latest")
    }

    // MARK: - 默认常量可读性

    func test_defaultModelIds_areNonEmpty() {
        XCTAssertFalse(SubagentModelResolver.defaultHaikuModelId.isEmpty)
        XCTAssertFalse(SubagentModelResolver.defaultSonnetModelId.isEmpty)
        XCTAssertFalse(SubagentModelResolver.defaultOpusModelId.isEmpty)
    }

    func test_defaultHaikuId_containsHaiku() {
        XCTAssertTrue(SubagentModelResolver.defaultHaikuModelId.contains("haiku"))
    }

    func test_defaultSonnetId_containsSonnet() {
        XCTAssertTrue(SubagentModelResolver.defaultSonnetModelId.contains("sonnet"))
    }

    func test_defaultOpusId_containsOpus() {
        XCTAssertTrue(SubagentModelResolver.defaultOpusModelId.contains("opus"))
    }
}

// MARK: - WorkflowRoleDefinition 集成路径

extension SubagentModelResolverTests {

    private func makeRole(
        preference: SubagentModelPreference
    ) -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "test-agent",
            displayName: "Test Agent",
            systemPrompt: "You are a test.",
            modelPreference: preference
        )
    }

    func test_workflowRole_inheritPreference_returnsParent() {
        let role = makeRole(preference: .inherit)
        let result = ClaudeService.resolvedModelId(
            for: role,
            parentModelId: "claude-sonnet-4-6"
        )
        XCTAssertEqual(result, "claude-sonnet-4-6")
    }

    func test_workflowRole_haikuPreference_whenParentIsSonnet_returnsHaiku() {
        let role = makeRole(preference: .haiku)
        let result = ClaudeService.resolvedModelId(
            for: role,
            parentModelId: "claude-sonnet-4-6"
        )
        XCTAssertEqual(result, SubagentModelResolver.defaultHaikuModelId)
    }

    func test_workflowRole_overrideExceedsTierPreference() {
        let role = makeRole(preference: .haiku)
        let result = ClaudeService.resolvedModelId(
            for: role,
            parentModelId: "claude-sonnet-4-6",
            overrideModelId: "claude-opus-4-6"
        )
        XCTAssertEqual(result, "claude-opus-4-6")
    }
}
