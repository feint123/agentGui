import XCTest
import SwiftAnthropic
@testable import agentGui

final class ForkSubagentDefinitionTests: XCTestCase {
    // MARK: - Constants
    func test_forkSubagentType_isLiteralFork() {
        XCTAssertEqual(FORK_SUBAGENT_TYPE, "fork")
    }
    func test_forkBoilerplateTag_isNonEmpty() {
        XCTAssertFalse(FORK_BOILERPLATE_TAG.isEmpty)
    }
    func test_forkPlaceholderResult_isNonEmpty() {
        XCTAssertFalse(FORK_PLACEHOLDER_RESULT.isEmpty)
    }
    // MARK: - ForkSubagentDefinition 静态属性
    func test_forkDefinition_agentType() {
        XCTAssertEqual(ForkSubagentDefinition.agentType, FORK_SUBAGENT_TYPE)
    }
    func test_forkDefinition_modelPreference_isInherit() {
        XCTAssertEqual(ForkSubagentDefinition.modelPreference, .inherit)
    }
    func test_forkDefinition_tools_containsWildcard() {
        XCTAssertTrue(ForkSubagentDefinition.tools.contains("*"))
    }
    func test_forkDefinition_permissionMode_isBubble() {
        XCTAssertEqual(ForkSubagentDefinition.permissionMode, "bubble")
    }
    func test_forkDefinition_maxTurns_isLarge() {
        XCTAssertGreaterThanOrEqual(ForkSubagentDefinition.maxTurns, 100)
    }
    func test_forkDefinition_permitsForking_isFalse() {
        XCTAssertFalse(ForkSubagentDefinition.permitsFork)
    }
    func test_forkDefinition_notRegisteredInCatalog() {
        let catalog = AgentCatalog.shared
        XCTAssertNil(catalog.find(named: FORK_SUBAGENT_TYPE))
    }
}

// MARK: - isInForkChild

final class IsInForkChildTests: XCTestCase {
    // MARK: 辅助方法
    /// 构造包含 fork boilerplate 标记的 .text 消息
    private func forkBotMessage() -> MessageParameter.Message {
        let content = "...\n<\(FORK_BOILERPLATE_TAG)>\nSTOP. READ THIS FIRST.\n</\(FORK_BOILERPLATE_TAG)>\n..."
        return MessageParameter.Message(role: .user, content: .text(content))
    }
    /// 构造纯文本（非 fork）user 消息
    private func plainUserMsg(_ text: String = "hello") -> MessageParameter.Message {
        MessageParameter.Message(role: .user, content: .text(text))
    }
    /// 构造 .list 格式的 user 消息，包含一个文本块
    private func listUserMsg(text: String) -> MessageParameter.Message {
        MessageParameter.Message(
            role: .user,
            content: .list([.text(text)])
        )
    }
    /// 构造 .list 格式的 user 消息，包含一个 toolResult 块（内含文本）
    private func toolResultMsg(text: String, toolUseId: String = "tc-1") -> MessageParameter.Message {
        MessageParameter.Message(
            role: .user,
            content: .list([
                .toolResult(toolUseId, text)
            ])
        )
    }
    // MARK: 空消息列表
    func test_emptyMessages_returnsFalse() {
        XCTAssertFalse(isInForkChild([]))
    }
    // MARK: 无 boilerplate 消息
    func test_plainMessages_returnsFalse() {
        let msgs = [plainUserMsg("do some work"), plainUserMsg("continue")]
        XCTAssertFalse(isInForkChild(msgs))
    }
    // MARK: .text 消息含 boilerplate
    func test_textMessageWithBoilerplate_returnsTrue() {
        let msgs = [forkBotMessage()]
        XCTAssertTrue(isInForkChild(msgs))
    }
    // MARK: .list 文本块含 boilerplate
    func test_listTextBlockWithBoilerplate_returnsTrue() {
        let tag = "<\(FORK_BOILERPLATE_TAG)>"
        let msgs = [listUserMsg(text: "Scope: \(tag) done")]
        XCTAssertTrue(isInForkChild(msgs))
    }
    // MARK: .list toolResult 块内文本含 boilerplate
    func test_toolResultBlockWithBoilerplate_returnsTrue() {
        let tag = "<\(FORK_BOILERPLATE_TAG)>"
        let msgs = [toolResultMsg(text: "result \(tag) end")]
        XCTAssertTrue(isInForkChild(msgs))
    }
    // MARK: assistant 消息中的 boilerplate 不应触发守卫
    func test_assistantMessageWithBoilerplate_returnsFalse() {
        // isInForkChild 只检查 user 消息
        let content = "<\(FORK_BOILERPLATE_TAG)>STOP</\(FORK_BOILERPLATE_TAG)>"
        let msg = MessageParameter.Message(role: .assistant, content: .text(content))
        XCTAssertFalse(isInForkChild([msg]))
    }
    // MARK: 混合消息列表
    func test_mixedMessages_detectsBoilerplate() {
        let msgs: [MessageParameter.Message] = [
            plainUserMsg("task"),
            MessageParameter.Message(role: .assistant, content: .text("thinking...")),
            forkBotMessage(),
            plainUserMsg("continue"),
        ]
        XCTAssertTrue(isInForkChild(msgs))
    }
    // MARK: boilerplate 在最后一条消息时仍能检测
    func test_boilerplateInLastMessage_returnsTrue() {
        let msgs = [
            plainUserMsg("a"),
            plainUserMsg("b"),
            forkBotMessage(),
        ]
        XCTAssertTrue(isInForkChild(msgs))
    }
}

// MARK: - AgentLoopPendingTool.isForkSubagent

final class AgentLoopPendingToolForkAnnotationTests: XCTestCase {
    func test_defaultPendingTool_isForkSubagent_isFalse() {
        let tool = AgentLoopPendingTool(id: "t1", name: "bash")
        XCTAssertFalse(tool.isForkSubagent)
    }
    func test_forkAnnotatedTool_isForkSubagent_isTrue() {
        var tool = AgentLoopPendingTool(id: "t2", name: "run_subagent")
        tool.isForkSubagent = true
        XCTAssertTrue(tool.isForkSubagent)
    }
    func test_forkAnnotation_doesNotAffectEquality_byDefault() {
        // 两个完全相同的工具（isForkSubagent 均为默认 false）应该相等
        let a = AgentLoopPendingTool(id: "t3", name: "bash")
        let b = AgentLoopPendingTool(id: "t3", name: "bash")
        XCTAssertEqual(a, b)
    }
}
