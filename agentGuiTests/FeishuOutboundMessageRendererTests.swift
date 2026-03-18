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

    @Test func rendererBuildsInteractivePayloadWithTitleAndBody() throws {
        let payload = try FeishuOutboundMessageRenderer().render(
            text: "卡片正文",
            format: .interactive,
            title: "飞书 Bot"
        )

        #expect(payload.msgType == "interactive")
        #expect(payload.content.contains("飞书 Bot"))
        #expect(payload.content.contains("卡片正文"))
        #expect(payload.content.contains("lark_md"))
    }

    @Test func rendererFallsBackToDefaultInteractiveTitleWhenTitleMissing() throws {
        let payload = try FeishuOutboundMessageRenderer().render(
            text: "卡片正文",
            format: .interactive,
            title: nil
        )

        #expect(payload.content.contains("Agent Reply"))
    }
}