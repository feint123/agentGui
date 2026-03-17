import Foundation
import SwiftAnthropic
@testable import agentGui

enum TerminalInteractiveFixtures {
    static let createVueFeatureSelectionScreen = """
    ◆  请选择要包含的功能： (↑/↓ 切换，空格选择，a 全选，回车确认)
    │  ◻ JSX 支持
    │  ◻ Router（单页面应用开发）
    │  ◻ Pinia（状态管理）
    │  ◻ Vitest（单元测试）
    """

    static let createNextAppOverwritePrompt = "File exists. Overwrite? [y/N]"
    static let passwordPrompt = "Password:"
    static let simpleReplPrompt = ">>>"

    static func toolUseStart(id: String, name: String, index: Int = 0) -> MessageStreamResponse {
        decode([
            "type": "content_block_start",
            "index": index,
            "content_block": [
                "type": "tool_use",
                "id": id,
                "name": name
            ]
        ])
    }

    static func inputJSONDelta(_ partialJSON: String, index: Int = 0) -> MessageStreamResponse {
        decode([
            "type": "content_block_delta",
            "index": index,
            "delta": [
                "type": "input_json_delta",
                "partial_json": partialJSON
            ]
        ])
    }

    static func textDelta(_ text: String, index: Int? = nil) -> MessageStreamResponse {
        var payload: [String: Any] = [
            "type": "content_block_delta",
            "delta": [
                "type": "text_delta",
                "text": text
            ]
        ]

        if let index {
            payload["index"] = index
        }

        return decode(payload)
    }

    static func stopReason(_ reason: String) -> MessageStreamResponse {
        decode([
            "type": "message_delta",
            "delta": [
                "stop_reason": reason
            ]
        ])
    }

    private static func decode(_ object: [String: Any]) -> MessageStreamResponse {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(MessageStreamResponse.self, from: data)
    }
}