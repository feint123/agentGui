import Foundation

struct FeishuEventEnvelope: Codable, Equatable, Sendable {
    let header: Header
    let event: Event

    struct Header: Codable, Equatable, Sendable {
        let eventType: String
    }

    struct Event: Codable, Equatable, Sendable {
        let sender: Sender
        let message: Message
    }

    struct Sender: Codable, Equatable, Sendable {
        let senderID: SenderID
    }

    struct SenderID: Codable, Equatable, Sendable {
        let openID: String
    }

    struct Message: Codable, Equatable, Sendable {
        let messageID: String
        let chatID: String
        let messageType: String
        let chatType: String
        let content: String
    }
}

struct FeishuTextContent: Codable, Equatable, Sendable {
    let text: String
}