import XCTest
@testable import agentGui

final class RelevantMemorySideQueryTests: XCTestCase {

    // MARK: - Prompt Builder

    func test_buildPrompt_containsQueryAndManifest() {
        let prompt = RelevantMemorySideQuery.buildUserPrompt(
            query: "How do I configure the API key?",
            manifest: "- [user] api_key_abc12345.md (2024-01-01): API key setup notes",
            recentTools: []
        )
        XCTAssertTrue(prompt.contains("How do I configure the API key?"))
        XCTAssertTrue(prompt.contains("api_key_abc12345.md"))
    }

    func test_buildPrompt_withRecentTools_includesToolsSection() {
        let prompt = RelevantMemorySideQuery.buildUserPrompt(
            query: "run tests",
            manifest: "- testing_notes_abc1.md: testing patterns",
            recentTools: ["bash", "file_write"]
        )
        XCTAssertTrue(prompt.contains("bash"))
        XCTAssertTrue(prompt.contains("file_write"))
    }

    func test_buildPrompt_noRecentTools_omitsToolsSection() {
        let prompt = RelevantMemorySideQuery.buildUserPrompt(
            query: "test",
            manifest: "manifest",
            recentTools: []
        )
        XCTAssertFalse(prompt.contains("Recently used tools"))
    }

    // MARK: - parseResponse

    func test_parseResponse_validJSON_returnsFilenames() throws {
        let json = """
        {"selected_memories": ["foo_abc12345.md", "bar_def67890.md"]}
        """
        let filenames = RelevantMemorySideQuery.parseResponse(
            json,
            validFilenames: ["foo_abc12345.md", "bar_def67890.md", "other_aabb1122.md"]
        )
        XCTAssertEqual(filenames, ["foo_abc12345.md", "bar_def67890.md"])
    }

    func test_parseResponse_invalidFilenameFiltered() throws {
        let json = """
        {"selected_memories": ["legitimate_abc12345.md", "injected_filename.md"]}
        """
        let filenames = RelevantMemorySideQuery.parseResponse(
            json,
            validFilenames: ["legitimate_abc12345.md"]
        )
        XCTAssertEqual(filenames, ["legitimate_abc12345.md"],
                       "validFilenames 白名单外的文件名必须被过滤")
    }

    func test_parseResponse_capsAtFive() {
        let jsonFilenames = (0..<8).map { "file\($0)_aabb\(String(format: "%04d", $0)).md" }
        let jsonArray = jsonFilenames.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = "{\"selected_memories\": [\(jsonArray)]}"
        let filenames = RelevantMemorySideQuery.parseResponse(
            json,
            validFilenames: Set(jsonFilenames)
        )
        XCTAssertLessThanOrEqual(filenames.count, 5)
    }

    func test_parseResponse_malformedJSON_returnsEmpty() {
        let filenames = RelevantMemorySideQuery.parseResponse(
            "not json at all",
            validFilenames: ["file_abc12345.md"]
        )
        XCTAssertTrue(filenames.isEmpty)
    }
}
