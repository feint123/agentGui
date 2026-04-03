import XCTest
import SwiftAnthropic
@testable import agentGui

final class SubagentActivityClassifierTests: XCTestCase {
    let classifier = SubagentActivityClassifier()

    // MARK: - str_replace_based_edit_tool

    func test_editor_view_isRead() {
        let input: MessageResponse.Content.Input = [
            "command": .string("view"),
            "path": .string("/Users/dev/Project/ClaudeService.swift")
        ]
        let activity = classifier.classify(toolName: "str_replace_based_edit_tool", input: input)
        XCTAssertTrue(activity.isRead)
        XCTAssertFalse(activity.isSearch)
        XCTAssertEqual(activity.activityDescription, "Reading ClaudeService.swift")
    }

    func test_editor_strReplace_isNotRead() {
        let input: MessageResponse.Content.Input = [
            "command": .string("str_replace"),
            "path": .string("/Foo/Bar.swift")
        ]
        let activity = classifier.classify(toolName: "str_replace_based_edit_tool", input: input)
        XCTAssertFalse(activity.isRead)
        XCTAssertEqual(activity.activityDescription, "Editing Bar.swift")
    }

    func test_editor_create_description() {
        let input: MessageResponse.Content.Input = [
            "command": .string("create"),
            "path": .string("/Foo/New.swift")
        ]
        let activity = classifier.classify(toolName: "str_replace_based_edit_tool", input: input)
        XCTAssertEqual(activity.activityDescription, "Creating New.swift")
    }

    func test_editor_noPath_fallback() {
        let input: MessageResponse.Content.Input = ["command": .string("view")]
        let activity = classifier.classify(toolName: "str_replace_based_edit_tool", input: input)
        XCTAssertEqual(activity.activityDescription, "Reading file")
    }

    // MARK: - bash

    func test_bash_normalCommand() {
        let input: MessageResponse.Content.Input = [
            "command": .string("swift test 2>&1")
        ]
        let activity = classifier.classify(toolName: "bash", input: input)
        XCTAssertFalse(activity.isRead)
        XCTAssertFalse(activity.isSearch)
        XCTAssertTrue(activity.activityDescription?.hasPrefix("Running:") == true)
    }

    func test_bash_grepIsSearch() {
        let input: MessageResponse.Content.Input = [
            "command": .string("grep -rn 'SubagentTaskRecord' .")
        ]
        let activity = classifier.classify(toolName: "bash", input: input)
        XCTAssertTrue(activity.isSearch)
    }

    func test_bash_emptyCommand_fallback() {
        let input: MessageResponse.Content.Input = [:]
        let activity = classifier.classify(toolName: "bash", input: input)
        XCTAssertEqual(activity.activityDescription, "Running command")
    }

    // MARK: - web_search

    func test_webSearch_isSearch() {
        let input: MessageResponse.Content.Input = ["query": .string("Swift actor isolation")]
        let activity = classifier.classify(toolName: "web_search", input: input)
        XCTAssertTrue(activity.isSearch)
        XCTAssertFalse(activity.isRead)
        XCTAssertEqual(activity.activityDescription, "Searching for Swift actor isolation")
    }

    func test_webSearchBrave_isSearch() {
        let input: MessageResponse.Content.Input = ["query": .string("SwiftData performance")]
        let activity = classifier.classify(toolName: "web_search_brave", input: input)
        XCTAssertTrue(activity.isSearch)
    }

    // MARK: - web_fetch

    func test_webFetch_isRead() {
        let input: MessageResponse.Content.Input = ["url": .string("https://example.com/docs")]
        let activity = classifier.classify(toolName: "web_fetch", input: input)
        XCTAssertTrue(activity.isRead)
        XCTAssertFalse(activity.isSearch)
    }

    // MARK: - read_tool_payload

    func test_readToolPayload_isRead() {
        let input: MessageResponse.Content.Input = [:]
        let activity = classifier.classify(toolName: "read_tool_payload", input: input)
        XCTAssertTrue(activity.isRead)
        XCTAssertEqual(activity.activityDescription, "Reading payload")
    }

    // MARK: - LSP tools

    func test_lspTool_isRead() {
        let input: MessageResponse.Content.Input = [:]
        let activity = classifier.classify(toolName: "lsp_definition", input: input)
        XCTAssertTrue(activity.isRead)
        XCTAssertTrue(activity.activityDescription?.hasPrefix("LSP:") == true)
    }

    // MARK: - run_subagent

    func test_runSubagent_description() {
        let input: MessageResponse.Content.Input = ["agent_name": .string("explore")]
        let activity = classifier.classify(toolName: "run_subagent", input: input)
        XCTAssertEqual(activity.activityDescription, "Launching explore")
    }

    // MARK: - unknown tool fallback

    func test_unknownTool_nilDescription() {
        let input: MessageResponse.Content.Input = [:]
        let activity = classifier.classify(toolName: "some_unknown_tool_xyz", input: input)
        XCTAssertNil(activity.activityDescription)
        XCTAssertFalse(activity.isRead)
        XCTAssertFalse(activity.isSearch)
    }
}
