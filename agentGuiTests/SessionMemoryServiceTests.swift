import XCTest
import SwiftAnthropic
@testable import agentGui

final class SessionMemoryServiceTests: XCTestCase {

    // MARK: - Token Estimation

    func test_estimateTokens_emptyMessages_returnsZero() {
        let messages: [MessageParameter.Message] = []
        XCTAssertEqual(SessionMemoryService.estimateTokens(from: messages), 0)
    }

    func test_estimateTokens_singleTextMessage_approximatesCharDividedByFour() {
        let text = String(repeating: "a", count: 400)
        let messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text(text))
        ]
        let estimate = SessionMemoryService.estimateTokens(from: messages)
        XCTAssertEqual(estimate, 100, accuracy: 10)   // 400 chars / 4 ≈ 100
    }

    // MARK: - Summary File Initialization

    func test_ensureSummaryFileExists_createsFileWithTemplate() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-init-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let summaryURL = tmpDir.appendingPathComponent("summary.md")
        let template = "# Test Template\n_placeholder_"

        try await SessionMemoryService.ensureSummaryFileExists(at: summaryURL, template: template)

        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
        let content = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertEqual(content, template)
    }

    func test_ensureSummaryFileExists_doesNotOverwriteExistingFile() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-nooverwrite-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let summaryURL = tmpDir.appendingPathComponent("summary.md")
        let existingContent = "# Existing Content\n\nSome notes"
        try existingContent.write(to: summaryURL, atomically: true, encoding: .utf8)

        let template = "# Fresh Template"
        try await SessionMemoryService.ensureSummaryFileExists(at: summaryURL, template: template)

        let content = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertEqual(content, existingContent, "Existing file must not be overwritten")
    }

    func test_readSummaryContent_returnsNilForMissingFile() async {
        let nonExistent = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)/summary.md")
        let content = await SessionMemoryService.readSummaryContent(at: nonExistent)
        XCTAssertNil(content)
    }

    func test_readSummaryContent_returnsFileContent() async throws {
        let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("summary-test-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        try "# My Notes\n\nContent here".write(to: tmpFile, atomically: true, encoding: .utf8)

        let content = await SessionMemoryService.readSummaryContent(at: tmpFile)
        XCTAssertEqual(content, "# My Notes\n\nContent here")
    }
}
