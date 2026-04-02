import XCTest
@testable import agentGui

@MainActor
final class ClaudeServiceMemoryExtractionToolsTests: XCTestCase {

    func test_buildExtractionTools_containsMemoryWrite() throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { service.toolNameForExtraction(from: $0) }
        XCTAssertTrue(names.contains("memory_write"),
                      "Extraction tools must include memory_write")
    }

    func test_buildExtractionTools_doesNotContainSubagentTool() throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { service.toolNameForExtraction(from: $0) }
        XCTAssertFalse(names.contains("run_subagent"),
                       "Extraction tools must not include run_subagent")
    }

    func test_buildExtractionTools_doesNotContainBashOrEditor() throws {
        // bash / str_replace_based_edit_tool 不在授权集合内
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { service.toolNameForExtraction(from: $0) }
        XCTAssertFalse(names.contains("bash"),
                       "Extraction tools must not include bash")
        XCTAssertFalse(names.contains("str_replace_based_edit_tool"),
                       "Extraction tools must not include str_replace_based_edit_tool")
    }

    func test_buildExtractionTools_exactlyMemoryWrite() throws {
        // M-06: 授权集合收窄为 memory_write only
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { service.toolNameForExtraction(from: $0) }
        XCTAssertEqual(Set(names), ["memory_write"],
                       "Extraction tools should contain exactly memory_write")
    }
}
