import Foundation

struct ChannelMessagePresentation: Equatable, Sendable {
    let text: String

    init(text: String) {
        self.text = text
    }

    init(message: Message) {
        self.text = message.textContent ?? ""
    }
}