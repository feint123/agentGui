import Foundation

/// 渐进字符预算追踪器。
/// 通过 60fps Timer 每帧将 `displayedCharBudget` 向 `targetLength` 推进，
/// 产生「打字机」视觉效果。由 `AgentMessageStepFlowView` 持有并驱动。
@Observable
@MainActor
final class StreamingCharBudgetTracker {

    // MARK: - Public State

    private(set) var displayedCharBudget: Int = 0
    private(set) var isTracking: Bool = false

    // MARK: - Config

    let charsPerFrame: Int

    // MARK: - Private

    private var timer: Timer?
    private var currentTargetLength: Int = 0

    // MARK: - Init

    init(charsPerFrame: Int = 8) {
        self.charsPerFrame = charsPerFrame
    }

    // MARK: - API

    /// 开始追踪新一轮 streaming。初始预算归零。
    func startTracking(targetLength: Int) {
        displayedCharBudget = 0
        currentTargetLength = targetLength
        isTracking = true
        ensureTimer()
    }

    /// streaming 结束时调用，立即展示全量文本并停止 timer。
    func stopTracking(finalLength: Int) {
        displayedCharBudget = finalLength
        isTracking = false
        tearDownTimer()
    }

    /// 在测试中手动步进（绕过实际 Timer 计时）。
    func advance(targetLength: Int) {
        currentTargetLength = targetLength
        tick()
    }

    // MARK: - Private

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func tearDownTimer() {
        timer?.invalidate()
        timer = nil
    }

    fileprivate func tick() {
        displayedCharBudget = min(displayedCharBudget + charsPerFrame, currentTargetLength)
    }
}
