import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct ToolPayloadReadToolTests {

    @Test func registryExposesReadToolPayload() throws {
        let registry = DefaultToolRegistry()

        #expect(registry.definition(for: "read_tool_payload") != nil)
    }

    @Test func payloadReaderReturnsLineRangeAndCursorMetadata() async throws {
        let service = ClaudeService()
        let baseDirectory = try makeTemporaryDirectory()
        service.toolPayloadStore = ToolPayloadStore(baseDirectory: baseDirectory)
        let payload = try await service.toolPayloadStore.createPayload(
            text: (1...10).map { "line \($0)" }.joined(separator: "\n"),
            sourceKind: .file,
            sourceDescriptor: "/tmp/sample.txt"
        )

        let output = await service.executeReadToolPayload(input: [
            "payload_ref": .string(payload.payloadID),
            "read_mode": .string("lines"),
            "start": .integer(2),
            "end": .integer(4)
        ])

        #expect(output.contains("payload_ref: \(payload.payloadID)"))
        #expect(output.contains("range_summary: lines 2-4 of 10"))
        #expect(output.contains("has_more: true"))
        #expect(output.contains("next_cursor: lines:5-7"))
        #expect(output.contains("2\tline 2"))
    }

    @Test func payloadReaderReportsMissingPayload() async throws {
        let service = ClaudeService()
        let output = await service.executeReadToolPayload(input: [
            "payload_ref": .string("payload_missing"),
            "read_mode": .string("lines"),
            "start": .integer(1),
            "end": .integer(2)
        ])

        #expect(output.contains("Error: payload_not_found"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}