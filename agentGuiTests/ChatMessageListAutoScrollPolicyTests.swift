import Testing
@testable import agentGui

struct ChatMessageListAutoScrollPolicyTests {

    // MARK: - ChatScrollState transitions

    @Test func trackingState_isTrackingBottom() {
        let state = ChatScrollState.tracking
        #expect(state.isTrackingBottom == true)
        #expect(state.isPaused == false)
    }

    @Test func pausedState_isNotTrackingBottom() {
        let state = ChatScrollState.paused(unseenCount: 3)
        #expect(state.isTrackingBottom == false)
        #expect(state.isPaused == true)
        #expect(state.unseenCount == 3)
    }

    @Test func pausedState_unseenCountZeroMeansNoBadge() {
        let state = ChatScrollState.paused(unseenCount: 0)
        #expect(state.showsBadge == false)
    }

    @Test func pausedState_unseenCountPositiveShowsBadge() {
        let state = ChatScrollState.paused(unseenCount: 2)
        #expect(state.showsBadge == true)
    }

    // MARK: - shouldScrollOnMessageAppend

    @Test func shouldScroll_whenTracking_andNewMessageArrives() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
            scrollState: .tracking,
            lastMessageIsUser: false
        ) == true)
    }

    @Test func shouldNotScroll_whenPaused_andAgentReply() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
            scrollState: .paused(unseenCount: 0),
            lastMessageIsUser: false
        ) == false)
    }

    @Test func shouldScroll_whenPaused_butNewMessageIsUser() {
        // User sent message → always scroll to show their own message
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
            scrollState: .paused(unseenCount: 1),
            lastMessageIsUser: true
        ) == true)
    }

    // MARK: - shouldScrollForStreaming

    @Test func shouldStream_whenTracking() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(
            scrollState: .tracking,
            isStreaming: true
        ) == true)
    }

    @Test func shouldNotStream_whenPaused() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(
            scrollState: .paused(unseenCount: 0),
            isStreaming: true
        ) == false)
    }

    @Test func shouldNotStream_whenNotStreaming() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollForStreaming(
            scrollState: .tracking,
            isStreaming: false
        ) == false)
    }

    // MARK: - incrementUnseenCount

    @Test func incrementUnseen_fromTracking_returnsPaused_count1() {
        let next = ChatMessageListAutoScrollPolicy.incrementUnseenCount(state: .tracking)
        #expect(next == .paused(unseenCount: 1))
    }

    @Test func incrementUnseen_fromPaused_incrementsCount() {
        let next = ChatMessageListAutoScrollPolicy.incrementUnseenCount(state: .paused(unseenCount: 4))
        #expect(next == .paused(unseenCount: 5))
    }

    @Test func incrementUnseen_capped_at99() {
        let next = ChatMessageListAutoScrollPolicy.incrementUnseenCount(state: .paused(unseenCount: 99))
        #expect(next == .paused(unseenCount: 99))
    }

    // MARK: - Edge cases

    @Test func shouldScroll_userMessage_alwaysTrue_evenWhenPaused_highUnseenCount() {
        #expect(ChatMessageListAutoScrollPolicy.shouldScrollOnMessageAppend(
            scrollState: .paused(unseenCount: 50),
            lastMessageIsUser: true
        ) == true)
    }

    @Test func incrementUnseen_fromPaused_count0_becomesCount1() {
        let next = ChatMessageListAutoScrollPolicy.incrementUnseenCount(state: .paused(unseenCount: 0))
        #expect(next == .paused(unseenCount: 1))
    }

    @Test func badgeLabel_belowCap() {
        let state = ChatScrollState.paused(unseenCount: 7)
        #expect(state.badgeLabel == "7")
    }

    @Test func badgeLabel_atCap() {
        let state = ChatScrollState.paused(unseenCount: 99)
        #expect(state.badgeLabel == "99+")
    }
}
