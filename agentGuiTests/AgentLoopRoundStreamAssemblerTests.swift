import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

struct AgentLoopRoundStreamAssemblerTests {

    @Test func assemblerCollectsTextThinkingSignatureToolJsonAndStopReason() {
        var assembler = AgentLoopRoundStreamAssembler()

        let events = [
            decodeRoundStreamEvent(
                """
                {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-1","name":"bash"}}
                """
            ),
            decodeRoundStreamEvent(
                """
                {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}
                """
            ),
            decodeRoundStreamEvent(
                """
                {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-1"}}
                """
            ),
            decodeRoundStreamEvent(
                """
                {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"command\\\":\\\"echo hi\\\"}"}}
                """
            ),
            decodeRoundStreamEvent(
                """
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"done"}}
                """
            ),
            decodeRoundStreamEvent(
                """
                {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
                """
            )
        ]

        for event in events {
            _ = assembler.consume(event)
        }

        let snapshot = assembler.snapshot
        #expect(snapshot.text == "done")
        #expect(snapshot.thinkingContent == "plan")
        #expect(snapshot.thinkingSignature == "sig-1")
        #expect(snapshot.stopReason == "tool_use")
        #expect(snapshot.pendingTools.count == 1)
        #expect(snapshot.pendingTools.first?.id == "tool-1")
        #expect(snapshot.pendingTools.first?.name == "bash")
        #expect(snapshot.pendingTools.first?.partialJson.contains("command") == true)
    }
}

private func decodeRoundStreamEvent(_ json: String) -> MessageStreamResponse {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(MessageStreamResponse.self, from: Data(json.utf8))
}