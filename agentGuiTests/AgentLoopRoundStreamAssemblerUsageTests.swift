import XCTest
import SwiftAnthropic
@testable import agentGui

final class AgentLoopRoundStreamAssemblerUsageTests: XCTestCase {

    // 辅助：构造 message_start 事件的 JSON
    private func messageStartEvent(inputTokens: Int) -> MessageStreamResponse {
        let object: [String: Any] = [
            "type": "message_start",
            "message": [
                "id": "msg_01",
                "type": "message",
                "role": "assistant",
                "content": [],
                "model": "claude-opus-4-5",
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": [
                    "input_tokens": inputTokens,
                    "output_tokens": 0
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(MessageStreamResponse.self, from: data)
    }

    func test_consumeMessageStart_capturesInputTokens() {
        var assembler = AgentLoopRoundStreamAssembler()
        let event = messageStartEvent(inputTokens: 12_345)
        assembler.consume(event)
        XCTAssertEqual(assembler.snapshot.usage?.inputTokens, 12_345)
    }

    func test_snapshotUsageNil_beforeMessageStart() {
        var assembler = AgentLoopRoundStreamAssembler()
        XCTAssertNil(assembler.snapshot.usage)
    }

    func test_consumeTextDelta_doesNotClearUsage() {
        var assembler = AgentLoopRoundStreamAssembler()
        assembler.consume(messageStartEvent(inputTokens: 999))
        assembler.consume(TerminalInteractiveFixtures.textDelta("hello"))
        XCTAssertEqual(assembler.snapshot.usage?.inputTokens, 999)
    }
}
