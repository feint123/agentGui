import Foundation

enum ChatMessageListAutoScrollPolicy {
    static let bottomAnchorID = "chat.messageList.bottomAnchor"

    static func shouldScrollForStreaming(isStreaming: Bool, isPinnedToBottom: Bool) -> Bool {
        isStreaming && isPinnedToBottom
    }

    static func shouldScrollOnMessageAppend(lastMessageIsUser: Bool, isPinnedToBottom: Bool) -> Bool {
        lastMessageIsUser || isPinnedToBottom
    }
}