import Foundation

struct FeishuRenderedMessagePayload: Equatable, Sendable {
    let msgType: String
    let content: String
}

struct FeishuOutboundMessageRenderer {
    enum RenderError: Error {
        case invalidEncoding
    }

    private let encoder: JSONEncoder

    init(encoder: JSONEncoder = JSONEncoder()) {
        self.encoder = encoder
    }

    func render(
        text: String,
        format: FeishuMessageFormat,
        title: String?
    ) throws -> FeishuRenderedMessagePayload {
        switch format {
        case .text:
            return FeishuRenderedMessagePayload(
                msgType: FeishuMessageFormat.text.rawValue,
                content: try encode(TextContent(text: text))
            )
        case .post:
            return FeishuRenderedMessagePayload(
                msgType: FeishuMessageFormat.post.rawValue,
                content: try encode(makePostContent(text: text, title: title))
            )
        case .interactive:
            return FeishuRenderedMessagePayload(
                msgType: FeishuMessageFormat.interactive.rawValue,
                content: try encode(makeInteractiveCard(text: text, title: title))
            )
        }
    }

    private func makePostContent(text: String, title: String?) -> PostContent {
        return PostContent(
            zhCN: PostLocaleContent(
                title: title ?? "",
                content: [[PostMarkdownNode(tag: "md", text: text)]]
            )
        )
    }

    private func makeInteractiveCard(text: String, title: String?) -> InteractiveCard {
        InteractiveCard(
            config: InteractiveCardConfig(wideScreenMode: true),
            header: InteractiveCardHeader(
                title: InteractiveCardHeaderTitle(tag: "plain_text", content: title ?? "Agent Reply")
            ),
            elements: [
                InteractiveCardElement(
                    tag: "div",
                    text: InteractiveCardMarkdown(tag: "lark_md", content: text)
                )
            ]
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw RenderError.invalidEncoding
        }
        return string
    }
}

private struct TextContent: Encodable {
    let text: String
}

private struct PostContent: Encodable {
    let zhCN: PostLocaleContent

    enum CodingKeys: String, CodingKey {
        case zhCN = "zh_cn"
    }
}

private struct PostLocaleContent: Encodable {
    let title: String
    let content: [[PostMarkdownNode]]
}

private struct PostMarkdownNode: Encodable {
    let tag: String
    let text: String
}

private struct InteractiveCard: Encodable {
    let config: InteractiveCardConfig
    let header: InteractiveCardHeader
    let elements: [InteractiveCardElement]
}

private struct InteractiveCardConfig: Encodable {
    let wideScreenMode: Bool

    enum CodingKeys: String, CodingKey {
        case wideScreenMode = "wide_screen_mode"
    }
}

private struct InteractiveCardHeader: Encodable {
    let title: InteractiveCardHeaderTitle
}

private struct InteractiveCardHeaderTitle: Encodable {
    let tag: String
    let content: String
}

private struct InteractiveCardElement: Encodable {
    let tag: String
    let text: InteractiveCardMarkdown
}

private struct InteractiveCardMarkdown: Encodable {
    let tag: String
    let content: String
}