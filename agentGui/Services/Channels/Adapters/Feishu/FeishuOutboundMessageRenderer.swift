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
    private let interactiveCardPlanner: FeishuInteractiveCardPlanner

    init(
        encoder: JSONEncoder = JSONEncoder(),
        interactiveCardPlanner: FeishuInteractiveCardPlanner = FeishuInteractiveCardPlanner()
    ) {
        self.encoder = encoder
        self.interactiveCardPlanner = interactiveCardPlanner
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
        let plan = interactiveCardPlanner.makePlan(text: text, title: title)

        return InteractiveCard(
            schema: "2.0",
            config: InteractiveCardConfig(updateMulti: true, widthMode: "fill"),
            header: InteractiveCardHeader(
                title: InteractiveCardHeaderTitle(tag: "plain_text", content: plan.title ?? "Agent Reply")
            ),
            body: InteractiveCardBody(
                direction: "vertical",
                elements: plan.sections.map { section in
                    InteractiveCardMarkdownElement(tag: "markdown", content: section.markdownText)
                }
            )
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
    let schema: String
    let config: InteractiveCardConfig
    let header: InteractiveCardHeader
    let body: InteractiveCardBody
}

private struct InteractiveCardConfig: Encodable {
    let updateMulti: Bool
    let widthMode: String

    enum CodingKeys: String, CodingKey {
        case updateMulti = "update_multi"
        case widthMode = "width_mode"
    }
}

private struct InteractiveCardHeader: Encodable {
    let title: InteractiveCardHeaderTitle
}

private struct InteractiveCardHeaderTitle: Encodable {
    let tag: String
    let content: String
}

private struct InteractiveCardBody: Encodable {
    let direction: String
    let elements: [InteractiveCardMarkdownElement]
}

private struct InteractiveCardMarkdownElement: Encodable {
    let tag: String
    let content: String
}