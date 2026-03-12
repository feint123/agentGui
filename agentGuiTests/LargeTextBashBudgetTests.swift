import Foundation
import Testing
@testable import agentGui

@MainActor
struct LargeTextBashBudgetTests {

    @Test func oversizedBashOutputBecomesReferencedPayload() async throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let result = await service.wrapLargeTextToolResultForTests(
            rawText: String(repeating: "build output\n", count: 2000),
            toolName: "bash",
            sourceKind: .bash,
            sourceDescriptor: "xcodebuild test",
            settings: settings
        )

        #expect(result.envelope?.injectionMode == .referenced)
        #expect(result.envelope?.payloadRef != nil)
        #expect(result.envelope?.rawCharCount ?? 0 > result.envelope?.injectedCharCount ?? 0)
    }
}