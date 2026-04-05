import Foundation
import Testing
@testable import agentGui

@MainActor
struct StreamingThrottledSaveTests {
    @Test
    func saveIfNeededIsIdempotentWithinWindow() async {
        var saveCount = 0
        let throttle = StreamingThrottledSave(
            intervalSeconds: 0.5,
            saveFn: { saveCount += 1 }
        )
        throttle.saveIfNeeded()
        throttle.saveIfNeeded()
        throttle.saveIfNeeded()
        // 三次调用在相同时刻，只有第一次应触发 save
        #expect(saveCount == 1)
    }

    @Test
    func saveIfNeededFiresAgainAfterWindowElapses() async throws {
        var saveCount = 0
        let throttle = StreamingThrottledSave(
            intervalSeconds: 0.05,  // 50 ms 便于测试
            saveFn: { saveCount += 1 }
        )
        throttle.saveIfNeeded()
        #expect(saveCount == 1)

        try await Task.sleep(for: .milliseconds(60))
        throttle.saveIfNeeded()
        #expect(saveCount == 2)
    }

    @Test
    func forceSaveAlwaysFires() async {
        var saveCount = 0
        let throttle = StreamingThrottledSave(
            intervalSeconds: 60.0,  // 很长的窗口
            saveFn: { saveCount += 1 }
        )
        throttle.saveIfNeeded()
        #expect(saveCount == 1)
        throttle.forceSave()
        #expect(saveCount == 2)
        throttle.forceSave()
        #expect(saveCount == 3)
    }

    @Test
    func forceSaveResetsThrottleWindow() async throws {
        var saveCount = 0
        let throttle = StreamingThrottledSave(
            intervalSeconds: 0.5,
            saveFn: { saveCount += 1 }
        )
        throttle.forceSave()
        #expect(saveCount == 1)
        // forceSave 之后立即 saveIfNeeded，应被节流（窗口已被 forceSave 重置）
        throttle.saveIfNeeded()
        #expect(saveCount == 1)
    }
}
