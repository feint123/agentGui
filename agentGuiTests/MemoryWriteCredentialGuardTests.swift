import XCTest
import SwiftAnthropic
@testable import agentGui

/// S-D4: memory_write 凭证防护测试
@MainActor
final class MemoryWriteCredentialGuardTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredGuardTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func buildInput(content: String, title: String = "Test") -> MessageResponse.Content.Input {
        ["content": .string(content), "title": .string(title)]
    }

    func test_credentialContent_anthropicKey_isRejected() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "My key is sk-ant-api03-XXXXXXXXXXXX"),
            memoryDir: tempDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "含 sk-ant- 开头的内容应被拒绝: \(result)")
    }

    func test_credentialContent_bearerToken_isRejected() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "Authorization: Bearer ghp_XXXXXXXXXXXXXXXXXX"),
            memoryDir: tempDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "含 Bearer token 的内容应被拒绝: \(result)")
    }

    func test_credentialContent_apiKeyAssignment_isRejected() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "api_key = 'supersecretvalue123'"),
            memoryDir: tempDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "含 api_key 赋值的内容应被拒绝: \(result)")
    }

    func test_normalContent_withWordApiKey_inNarrativeContext_isAllowed() async {
        // "API Key" 出现在正常叙述中，不含具体凭证值，应允许
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "Settings page requires the user to enter their API key in the text field."),
            memoryDir: tempDir
        )
        XCTAssertFalse(result.hasPrefix("Error:"), "普通叙述内容不应被误判为凭证: \(result)")
    }

    func test_normalContent_noCredential_isAllowed() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "ClaudeService.swift should not be edited directly."),
            memoryDir: tempDir
        )
        XCTAssertFalse(result.hasPrefix("Error:"), "普通内容不应被拒绝: \(result)")
    }

    func test_credentialContent_passwordAssignment_isRejected() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "password: hunter2"),
            memoryDir: tempDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "含 password 赋值的内容应被拒绝: \(result)")
    }
}
