import Foundation
import Observation

/// M-06 整合进度的 UI 可见状态。
///
/// 供 Footer 或后台任务列表挂入，展示当前 dream phase 和已触碰的文件路径。
/// 生命周期：整合开始时创建，`isCompleted` 变为 `true` 后可安全释放。
@MainActor
@Observable
final class ConsolidationProgressState {

    enum Phase: String {
        case starting   = "starting"
        case updating   = "updating"
        case completed  = "completed"
        case failed     = "failed"
    }

    private(set) var phase: Phase = .starting
    private(set) var sessionCount: Int = 0
    private(set) var filesTouched: [String] = []
    private(set) var isCompleted: Bool = false
    private(set) var errorMessage: String?

    // MARK: - Internal updates (called by MemoryConsolidationService)

    func markUpdating(filePath: String) {
        if !filesTouched.contains(filePath) {
            filesTouched.append(filePath)
        }
        phase = .updating
    }

    func markCompleted() {
        phase = .completed
        isCompleted = true
    }

    func markFailed(error: String) {
        phase = .failed
        errorMessage = error
        isCompleted = true
    }

    func configure(sessionCount: Int) {
        self.sessionCount = sessionCount
    }
}
