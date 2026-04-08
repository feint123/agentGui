import Testing
import Foundation
@testable import agentGui

struct StreamProjectionHookThrottleTests {

    @Test
    func hookDoesNotProjectTwiceWithinMinInterval() throws {
        let hook = StreamProjectionHook(
            state: StreamProjectionHook.State(),
            textThreshold: 1,       // 每字必触发（贪婪）
            thinkingThreshold: 1,
            minInterval: 9999       // 超大间隔 → 强制跳过
        )
        // 第一次：上次投影时间为 .distantPast，应该通过
        #expect(hook.shouldProjectForTest(
            currentLength: 10,
            lastProjectedLength: 0,
            threshold: 1,
            forceProjection: false,
            now: Date()
        ) == true)
        // 立即第二次：时间未到 minInterval
        let now = Date()
        var state = StreamProjectionHook.State()
        state.lastProjectionDate = now
        let hookBusy = StreamProjectionHook(
            state: state,
            textThreshold: 1,
            thinkingThreshold: 1,
            minInterval: 9999
        )
        #expect(hookBusy.shouldProjectForTest(
            currentLength: 20,
            lastProjectedLength: 10,
            threshold: 1,
            forceProjection: false,
            now: now.addingTimeInterval(0.001)  // 1ms 后，远小于 9999s
        ) == false)
    }

    @Test
    func hookProjectsImmediatelyWhenForceProjectionSet() {
        let now = Date()
        var state = StreamProjectionHook.State()
        state.lastProjectionDate = now
        let hook = StreamProjectionHook(state: state, textThreshold: 1, minInterval: 9999)
        #expect(hook.shouldProjectForTest(
            currentLength: 5,
            lastProjectedLength: 0,
            threshold: 1,
            forceProjection: true,       // forceProjection 绕过时间门控
            now: now.addingTimeInterval(0.001)
        ) == true)
    }
}
