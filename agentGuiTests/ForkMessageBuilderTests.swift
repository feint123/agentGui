// agentGuiTests/ForkMessageBuilderTests.swift
// S-F2: ForkMessageBuilder unit tests.
// Written first per TDD; expected to fail until ForkMessageBuilder is implemented (Task 2).

import XCTest
import SwiftAnthropic
@testable import agentGui

final class ForkMessageBuilderTests: XCTestCase {

    func test_buildForkedMessages_withToolUses_returnsAssistantAndUserMessages() {
        let assistant = MessageParameter.Message(
            role: .assistant,
            content: .list([
                .text("I will delegate."),
                .toolUse("tu-1", "run_subagent", ["task": .string("A")]),
                .toolUse("tu-2", "run_subagent", ["task": .string("B")])
            ])
        )

        let result = ForkMessageBuilder().buildForkedMessages(
            directive: "Analyze auth flow",
            parentHistory: [],
            assistantMessage: assistant
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].role, "assistant")
        XCTAssertEqual(result[1].role, "user")
    }

    func test_buildForkedMessages_placeholderIsIdenticalForAllToolResults() {
        let assistant = MessageParameter.Message(
            role: .assistant,
            content: .list([
                .toolUse("tu-1", "run_subagent", ["task": .string("A")]),
                .toolUse("tu-2", "run_subagent", ["task": .string("B")])
            ])
        )

        let result = ForkMessageBuilder().buildForkedMessages(
            directive: "Find callsites",
            parentHistory: [],
            assistantMessage: assistant
        )

        guard case .list(let userBlocks) = result[1].content else {
            return XCTFail("expected user .list")
        }

        let placeholders = userBlocks.compactMap { block -> String? in
            guard case .toolResult(_, let content, _, _) = block else { return nil }
            return content
        }

        XCTAssertEqual(placeholders.count, 2)
        XCTAssertTrue(placeholders.allSatisfy { $0 == FORK_PLACEHOLDER_RESULT })
    }

    func test_buildForkedMessages_whenNoToolUse_fallsBackToSingleUserMessage() {
        let assistant = MessageParameter.Message(
            role: .assistant,
            content: .list([.text("no tool calls")])
        )

        let result = ForkMessageBuilder().buildForkedMessages(
            directive: "Summarize architecture",
            parentHistory: [],
            assistantMessage: assistant
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].role, "user")
    }

    func test_buildChildMessage_containsBoilerplateTagAndDirectivePrefix() {
        let text = ForkMessageBuilder.buildChildMessage(directive: "Trace regression")
        XCTAssertTrue(text.contains("<\(FORK_BOILERPLATE_TAG)>"))
        XCTAssertTrue(text.contains(FORK_DIRECTIVE_PREFIX))
        XCTAssertTrue(text.contains("STOP. READ THIS FIRST."))
    }

    func test_buildForkedMessages_keepsParentHistoryPrefix() {
        let history: [MessageParameter.Message] = [
            .init(role: .user, content: .text("parent user")),
            .init(role: .assistant, content: .text("parent assistant"))
        ]
        let assistant = MessageParameter.Message(
            role: .assistant,
            content: .list([.toolUse("tu-1", "run_subagent", ["task": .string("A")])])
        )

        let result = ForkMessageBuilder().buildForkedMessages(
            directive: "Do X",
            parentHistory: history,
            assistantMessage: assistant
        )

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].role, "user")
        XCTAssertEqual(result[1].role, "assistant")
        XCTAssertEqual(result[2].role, "assistant")
        XCTAssertEqual(result[3].role, "user")
    }
}
