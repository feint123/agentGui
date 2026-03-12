import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct LargeTextTextEditorTests {

    @Test func largeViewWithoutRangeReturnsReferencedPayloadEnvelope() async throws {
        let harness = try InMemoryAppHarness.makeConfiguredSettingsScenario()
        harness.settings.enableTextEditorTool = true

        let fileURL = try makeTemporaryFile(
            content: (1...1200).map { "line \($0)" }.joined(separator: "\n")
        )
        let service = ClaudeService()

        let result = await service.executeTool(
            name: "str_replace_based_edit_tool",
            input: [
                "command": .string("view"),
                "path": .string(fileURL.path)
            ],
            settings: harness.settings,
            session: harness.session,
            modelContext: harness.context
        )

        #expect(result.envelope?.injectionMode == .referenced)
        #expect(result.envelope?.payloadRef != nil)
        #expect(result.text.contains("payload_ref:"))
    }

    private func makeTemporaryFile(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}