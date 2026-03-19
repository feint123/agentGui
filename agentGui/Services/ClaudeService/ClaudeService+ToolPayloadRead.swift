import Foundation
import SwiftAnthropic

extension ClaudeService {

    func executeReadToolPayload(input: MessageResponse.Content.Input) async -> String {
        guard let payloadRef = input["payload_ref"]?.stringValue, !payloadRef.isEmpty else {
            return "Error: missing 'payload_ref' parameter"
        }

        let readMode = ToolPayloadReadMode(rawValue: input["read_mode"]?.stringValue ?? "chunk") ?? .chunk
        let start = input["start"]?.intValue
        let end = input["end"]?.intValue
        let cursor = input["cursor"]?.stringValue
        let maxChars = input["max_chars"]?.intValue

        do {
            let window = try await toolPayloadStore.readWindow(
                payloadID: payloadRef,
                readMode: readMode,
                start: start,
                end: end,
                cursor: cursor,
                maxChars: maxChars
            )
            return renderPayloadReadWindow(payloadRef: payloadRef, window: window)
        } catch let error as ToolPayloadStoreError {
            return error.localizedDescription
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    func renderPayloadReadWindow(payloadRef: String, window: ToolPayloadReadWindow) -> String {
        var lines = [
            "payload_ref: \(payloadRef)",
            "range_summary: \(window.rangeSummary)",
            "chunk_index: \(window.chunkIndex)",
            "chunk_count: \(window.chunkCount)",
            "has_more: \(window.hasMore)"
        ]
        if let cursor = window.cursor {
            lines.append("cursor: \(cursor)")
        }
        if let nextCursor = window.nextCursor {
            lines.append("next_cursor: \(nextCursor)")
        }
        lines.append("")
        lines.append(window.content)
        return lines.joined(separator: "\n")
    }
}