import Foundation
import Testing
@testable import agentGui

struct ChatMessageListAutoScrollPolicyTests {

    @Test func streamingScrollRequiresPinnedBottom() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(isStreaming: true, isPinnedToBottom: true))
        #expect(!ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(isStreaming: true, isPinnedToBottom: false))
        #expect(!ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(isStreaming: false, isPinnedToBottom: true))
    }

    @Test func appendedUserMessageAlwaysScrollsToBottom() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(lastMessageIsUser: true, isPinnedToBottom: false))
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(lastMessageIsUser: true, isPinnedToBottom: true))
    }

    @Test func appendedAgentMessageRespectsPinnedBottomState() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(lastMessageIsUser: false, isPinnedToBottom: true))
        #expect(!ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(lastMessageIsUser: false, isPinnedToBottom: false))
    }
}