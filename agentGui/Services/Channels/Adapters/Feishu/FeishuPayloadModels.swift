import Foundation

struct FeishuEventEnvelope: Codable, Equatable, Sendable {
    let header: Header
    let event: Event

    struct Header: Codable, Equatable, Sendable {
        let eventType: String

        init(eventType: String) {
            self.eventType = eventType
        }

        enum CodingKeys: String, CodingKey {
            case eventType = "event_type"
        }
    }

    struct Event: Codable, Equatable, Sendable {
        let sender: Sender
        let message: Message

        init(sender: Sender, message: Message) {
            self.sender = sender
            self.message = message
        }
    }

    struct Sender: Codable, Equatable, Sendable {
        let senderID: SenderID
        let senderType: String?
        let tenantKey: String?

        init(senderID: SenderID, senderType: String? = nil, tenantKey: String? = nil) {
            self.senderID = senderID
            self.senderType = senderType
            self.tenantKey = tenantKey
        }

        enum CodingKeys: String, CodingKey {
            case senderID = "sender_id"
            case senderType = "sender_type"
            case tenantKey = "tenant_key"
        }
    }

    struct SenderID: Codable, Equatable, Sendable {
        let openID: String?
        let userID: String?
        let unionID: String?

        init(openID: String?, userID: String? = nil, unionID: String? = nil) {
            self.openID = openID
            self.userID = userID
            self.unionID = unionID
        }

        enum CodingKeys: String, CodingKey {
            case openID = "open_id"
            case userID = "user_id"
            case unionID = "union_id"
        }
    }

    struct Message: Codable, Equatable, Sendable {
        let messageID: String
        let chatID: String
        let messageType: String
        let chatType: String
        let content: String
        let rootID: String?
        let parentID: String?
        let createTime: Int64?
        let updateTime: Int64?
        let threadID: String?
        let mentions: [Mention]
        let userAgent: String?

        init(
            messageID: String,
            chatID: String,
            messageType: String,
            chatType: String,
            content: String,
            rootID: String? = nil,
            parentID: String? = nil,
            createTime: Int64? = nil,
            updateTime: Int64? = nil,
            threadID: String? = nil,
            mentions: [Mention] = [],
            userAgent: String? = nil
        ) {
            self.messageID = messageID
            self.chatID = chatID
            self.messageType = messageType
            self.chatType = chatType
            self.content = content
            self.rootID = rootID
            self.parentID = parentID
            self.createTime = createTime
            self.updateTime = updateTime
            self.threadID = threadID
            self.mentions = mentions
            self.userAgent = userAgent
        }

        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case chatID = "chat_id"
            case messageType = "message_type"
            case chatType = "chat_type"
            case content
            case rootID = "root_id"
            case parentID = "parent_id"
            case createTime = "create_time"
            case updateTime = "update_time"
            case threadID = "thread_id"
            case mentions
            case userAgent = "user_agent"
        }
    }

    struct Mention: Codable, Equatable, Sendable {
        let key: String?
        let id: SenderID?
        let name: String?
        let tenantKey: String?

        init(key: String?, id: SenderID?, name: String?, tenantKey: String?) {
            self.key = key
            self.id = id
            self.name = name
            self.tenantKey = tenantKey
        }

        enum CodingKeys: String, CodingKey {
            case key
            case id
            case name
            case tenantKey = "tenant_key"
        }
    }
}

extension FeishuEventEnvelope.Message {
    var isDirectChat: Bool {
        chatType == "p2p"
    }

    var isGroupChat: Bool {
        chatType == "group"
    }

    var mentionsBot: Bool {
        !mentions.isEmpty
    }

    func decodeContent<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: Data(content.utf8))
    }
}

struct FeishuTextContent: Codable, Equatable, Sendable {
    let text: String
}