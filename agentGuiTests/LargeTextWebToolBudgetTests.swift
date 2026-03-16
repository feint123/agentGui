import Foundation
import Testing
@testable import agentGui

@MainActor
struct LargeTextWebToolBudgetTests {

    @Test func oversizedWebFetchOutputUsesReferencedPayload() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let result = await service.wrapLargeTextToolResultForTests(
            rawText: String(repeating: "paragraph ", count: 3000),
            toolName: "web_fetch",
            sourceKind: .webFetch,
            sourceDescriptor: "https://example.com/guide",
            settings: settings
        )

        #expect(result.envelope?.injectionMode == .referenced)
        #expect(result.envelope?.payloadRef != nil)
    }

    @Test func shortWebFetchOutputStaysInline() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let result = await service.wrapLargeTextToolResultForTests(
            rawText: "short article body",
            toolName: "web_fetch",
            sourceKind: .webFetch,
            sourceDescriptor: "https://example.com/short",
            settings: settings
        )

        #expect(result.envelope?.injectionMode == .inline)
        #expect(result.envelope?.payloadRef == nil)
        #expect(result.text == "short article body")
    }

    @Test func mediumWebFetchOutputUsesPreviewAndPayloadReference() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let result = await service.wrapLargeTextToolResultForTests(
            rawText: String(repeating: "paragraph ", count: 450),
            toolName: "web_fetch",
            sourceKind: .webFetch,
            sourceDescriptor: "https://example.com/medium",
            settings: settings
        )

        #expect(result.envelope?.injectionMode == .preview)
        #expect(result.envelope?.payloadRef != nil)
        #expect(result.text.contains("payload_ref:"))
    }

    @Test func payloadStorageFailureFallsBackFromReferencedMode() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")
        let blockingURL = try makeBlockingFileURL()
        service.toolPayloadStore = ToolPayloadStore(baseDirectory: blockingURL)

        let result = await service.wrapLargeTextToolResultForTests(
            rawText: String(repeating: "paragraph ", count: 3000),
            toolName: "web_fetch",
            sourceKind: .webFetch,
            sourceDescriptor: "https://example.com/guide",
            settings: settings
        )

        #expect(result.envelope?.injectionMode == .preview)
        #expect(result.envelope?.payloadRef == nil)
        #expect(!result.text.contains("payload_ref:"))
    }

    private func makeBlockingFileURL() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("blocked".utf8).write(to: fileURL)
        return fileURL
    }
}