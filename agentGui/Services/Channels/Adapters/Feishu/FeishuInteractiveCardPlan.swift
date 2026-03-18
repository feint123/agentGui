import Foundation

struct FeishuInteractiveCardPlan: Equatable, Sendable {
    let title: String?
    let sections: [FeishuInteractiveSection]
}

enum FeishuInteractiveSection: Equatable, Sendable {
    case markdown(String)
    case table(markdown: String)
    case codeBlock(markdown: String)
    case callout(markdown: String)
    case divider(markdown: String)

    var markdownText: String {
        switch self {
        case .markdown(let text):
            return text
        case .table(let markdown):
            return markdown
        case .codeBlock(let markdown):
            return markdown
        case .callout(let markdown):
            return markdown
        case .divider(let markdown):
            return markdown
        }
    }
}