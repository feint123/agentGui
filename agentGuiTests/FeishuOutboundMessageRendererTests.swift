import Foundation
import Testing
@testable import agentGui

struct FeishuOutboundMessageRendererTests {
    @Test func rendererBuildsTextPayload() throws {
        let payload = try FeishuOutboundMessageRenderer().render(
            text: "你好，世界",
            format: .text,
            title: nil
        )

        #expect(payload.msgType == "text")
        #expect(payload.content == #"{"text":"你好，世界"}"#)
    }

    @Test func rendererBuildsPostPayloadUsingOnlyMarkdownTag() throws {
        let payload = try FeishuOutboundMessageRenderer().render(
            text: "**第一段**\n\n第二段",
            format: .post,
            title: nil
        )

        #expect(payload.msgType == "post")
        #expect(payload.content.contains("zh_cn"))
        #expect(payload.content.contains("\"tag\":\"md\""))
        #expect(payload.content.contains("**第一段**"))
        #expect(payload.content.contains("第二段"))
        #expect(payload.content.contains("\"content\":[[{"))
    }

    @Test func rendererBuildsPostPayloadWithTitleAndMarkdownBody() throws {
        let payload = try FeishuOutboundMessageRenderer().render(
            text: "- item1\n- item2",
            format: .post,
            title: "飞书 Bot"
        )

        #expect(payload.content.contains("飞书 Bot"))
        #expect(payload.content.contains("\"tag\":\"md\""))
        #expect(payload.content.contains("- item1"))
    }

    @Test func rendererBuildsInteractivePayloadWithCardJSON2Body() throws {
        let payload = try FeishuOutboundMessageRenderer().render(
            text: "卡片正文",
            format: .interactive,
            title: "飞书 Bot"
        )

        #expect(payload.msgType == "interactive")
        #expect(payload.content.contains("飞书 Bot"))
        #expect(payload.content.contains("卡片正文"))
        #expect(payload.content.contains("\"schema\":\"2.0\""))
        #expect(payload.content.contains("\"body\""))
        #expect(payload.content.contains("\"tag\":\"markdown\""))
    }

    @Test func rendererFallsBackToDefaultInteractiveTitleWhenTitleMissing() throws {
        let payload = try FeishuOutboundMessageRenderer().render(
            text: "卡片正文",
            format: .interactive,
            title: nil
        )

        #expect(payload.content.contains("Agent Reply"))
    }

    @Test func rendererBuildsInteractivePayloadWithDedicatedTableSection() throws {
        let payload = try FeishuOutboundMessageRenderer().render(
            text: """
            简介

            | A | B |
            | --- | --- |
            | 1 | 2 |

            结尾
            """,
            format: .interactive,
            title: "飞书 Bot"
        )

        #expect(payload.msgType == "interactive")
        #expect(payload.content.contains("\"schema\":\"2.0\""))
        #expect(payload.content.contains("| A | B |"))
        #expect(markdownElementCount(in: payload.content) == 3)
    }

    @Test func rendererBuildsInteractivePayloadWithMultipleTableSections() throws {
        let payload = try FeishuOutboundMessageRenderer().render(
            text: """
            表一前文

            | A | B |
            | --- | --- |
            | 1 | 2 |

            表间说明

            | C | D |
            | --- | --- |
            | 3 | 4 |
            """,
            format: .interactive,
            title: nil
        )

        #expect(markdownElementCount(in: payload.content) == 4)
        #expect(payload.content.contains("| C | D |"))
    }
}

private func markdownElementCount(in json: String) -> Int {
    json.components(separatedBy: "\"tag\":\"markdown\"").count - 1
}