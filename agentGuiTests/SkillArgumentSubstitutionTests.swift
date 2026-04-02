// agentGuiTests/SkillArgumentSubstitutionTests.swift
import XCTest
@testable import agentGui

final class SkillArgumentSubstitutionTests: XCTestCase {

    private func sub(_ content: String, args: String? = nil,
                     skillDir: String = "/tmp/my-skill",
                     sessionId: String = "test-session") -> String {
        SkillArgumentSubstitution.substitute(
            content: content,
            args: args,
            skillDirectory: URL(fileURLWithPath: skillDir),
            sessionId: sessionId
        )
    }

    // $ARGUMENTS 替换
    func test_arguments_dollarSign() {
        XCTAssertEqual(sub("Review $ARGUMENTS", args: "PR #123"), "Review PR #123")
    }

    func test_arguments_curlyBrace() {
        XCTAssertEqual(sub("Review ${ARGUMENTS}", args: "PR #123"), "Review PR #123")
    }

    func test_arguments_nil_replacedWithEmpty() {
        XCTAssertEqual(sub("Review $ARGUMENTS for issues", args: nil), "Review  for issues")
    }

    func test_arguments_empty_replacedWithEmpty() {
        XCTAssertEqual(sub("Task: $ARGUMENTS.", args: ""), "Task: .")
    }

    // ${CLAUDE_SKILL_DIR} 替换
    func test_skillDir_substituted() {
        let result = sub("cd ${CLAUDE_SKILL_DIR} && bash run.sh", skillDir: "/home/user/.claude/skills/foo")
        XCTAssertEqual(result, "cd /home/user/.claude/skills/foo && bash run.sh")
    }

    // ${CLAUDE_SESSION_ID} 替换
    func test_sessionId_substituted() {
        let result = sub("Session: ${CLAUDE_SESSION_ID}", sessionId: "abc-123")
        XCTAssertEqual(result, "Session: abc-123")
    }

    // 无占位符时内容原样返回
    func test_noPlaceholder_unchanged() {
        let content = "No placeholders here."
        XCTAssertEqual(sub(content, args: "ignored"), content)
    }

    // 多次出现都被替换
    func test_multipleOccurrences() {
        let result = sub("$ARGUMENTS and also $ARGUMENTS", args: "hello")
        XCTAssertEqual(result, "hello and also hello")
    }
}
