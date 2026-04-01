import XCTest
@testable import agentGui

// MARK: - OneShotSubagentTrailerTests
//
// 验证 S-A2 的核心行为：buildSubagentTrailer 函数根据 isOneShot 标记
// 决定是否产生 trailer 文本。

final class OneShotSubagentTrailerTests: XCTestCase {

    // MARK: - buildSubagentTrailer

    func test_nonOneShotAgent_returnsNonEmptyTrailer() {
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: "worker",
            rounds: 4,
            elapsed: 12.34,
            isOneShot: false
        )
        XCTAssertNotNil(trailer, "非 one-shot 代理应产生 trailer")
        XCTAssertTrue(trailer!.contains("worker"),    "trailer 应含代理名称")
        XCTAssertTrue(trailer!.contains("rounds: 4"), "trailer 应含轮次")
        XCTAssertTrue(trailer!.contains("elapsed"),   "trailer 应含耗时")
    }

    func test_oneShotAgent_returnsNilTrailer() {
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: "explore",
            rounds: 8,
            elapsed: 5.0,
            isOneShot: true
        )
        XCTAssertNil(trailer, "one-shot 代理不应产生 trailer")
    }

    func test_trailerIsWrappedInXMLTag() {
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: "verifier",
            rounds: 2,
            elapsed: 3.1,
            isOneShot: false
        )!
        XCTAssertTrue(trailer.contains("<agent_execution>"),  "trailer 应使用 <agent_execution> XML 包裹")
        XCTAssertTrue(trailer.contains("</agent_execution>"), "trailer 应有闭合标签")
    }

    func test_trailerLeadingNewline() {
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: "worker",
            rounds: 1,
            elapsed: 0.5,
            isOneShot: false
        )!
        XCTAssertTrue(trailer.hasPrefix("\n"), "trailer 应以换行开头，与正文分隔")
    }

    // MARK: - applyTrailerToOutput

    func test_applyTrailer_nonOneShotAppendsTrailer() {
        let output = "Found 3 relevant files."
        let result = ClaudeService.applyTrailerToOutput(
            output: output,
            trailer: "\n<agent_execution>agent: worker | rounds: 1 | elapsed: 0.50s</agent_execution>"
        )
        XCTAssertTrue(result.hasPrefix("Found 3 relevant files."))
        XCTAssertTrue(result.contains("<agent_execution>"))
    }

    func test_applyTrailer_nilTrailerReturnsOutputUnchanged() {
        let output = "Exploration complete.\n\n## Files Found\n- src/main.swift"
        let result = ClaudeService.applyTrailerToOutput(output: output, trailer: nil)
        XCTAssertEqual(result, output, "nil trailer 时输出不应改变")
    }
}
