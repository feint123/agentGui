import Foundation

/// 可复用的测试异步"门"：调用 `wait()` 会阻塞，直到 `open()` 被调用。
/// 用于在单元测试中精确控制 actor 的执行时序。
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 打开门：唤醒所有等待的协程。
    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    /// 等待门打开；若门已打开则立即返回。
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
