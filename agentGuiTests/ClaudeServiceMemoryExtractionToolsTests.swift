import XCTest
@testable import agentGui

@MainActor
final class ClaudeServiceMemoryExtractionToolsTests: XCTestCase {

    func test_buildExtractionTools_containsMemoryWrite() throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { tool -> String? in
            service.toolNameForExtraction(from: tool)
        }
        XCTAssertTrue(names.contains("memory_write"), "Extraction tools must include memory_write")
    }

    func test_buildExtractionTools_doesNotContainSubagentTool() throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { tool -> String? in
            service.toolNameForExtraction(from: tool)
        }
        XCTAssertFalse(names.contains("run_subagent"), "Extraction tools must not include run_subagent")
    }
}
