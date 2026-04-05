import Foundation
import SwiftData

/// 为流式写路径提供基于时间窗口的 ModelContext.save() 节流。
///
/// - `saveIfNeeded()`: 距上次 save() 超过 `intervalSeconds` 才真正调用 save；
///   在窗口内重复调用为空操作。适合在每个流式 delta 后调用。
/// - `forceSave()`: 无条件调用 save()，并重置节流计时器。适合在轮次/循环边界调用。
///
/// **线程安全：** 必须在 @MainActor 上使用，与 ModelContext 的隔离域一致。
@MainActor
final class StreamingThrottledSave {
    private let intervalSeconds: TimeInterval
    private let saveFn: () -> Void
    private var lastSaveTime: Date = .distantPast

    /// 生产环境 init：直接传入 ModelContext。
    convenience init(modelContext: ModelContext, intervalSeconds: TimeInterval = 0.5) {
        self.init(intervalSeconds: intervalSeconds) {
            try? modelContext.save()
        }
    }

    /// 测试用 init：注入 save 函数，避免依赖 ModelContext。
    init(intervalSeconds: TimeInterval, saveFn: @escaping @MainActor () -> Void) {
        self.intervalSeconds = intervalSeconds
        self.saveFn = saveFn
    }

    /// 流式路径调用点：距上次 save 超过 interval 才触发。
    func saveIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastSaveTime) >= intervalSeconds else { return }
        lastSaveTime = now
        saveFn()
    }

    /// 轮次/循环边界调用点：无条件触发，并重置计时器。
    func forceSave() {
        lastSaveTime = Date()
        saveFn()
    }
}
