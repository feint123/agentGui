import AppKit

// MARK: - CodeEditorGutterLane Protocol

/// 代表 Gutter 中的一个纵向列（Lane）
/// 每个 Lane 拥有独立宽度、绘制逻辑、命中测试逻辑
/// 线程约束：所有方法在主线程调用
@MainActor
protocol CodeEditorGutterLane: AnyObject {

    /// Lane 的唯一标识符，用于查找和命中回调
    var id: String { get }

    /// Lane 偏好的列宽（points），由 lane 自身根据 snapshot 计算
    /// Host 调用此值来计算各 lane 的 frame
    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat

    /// 绘制此 Lane 的内容
    /// - Parameters:
    ///   - snapshot: 当前 gutter 状态快照
    ///   - laneRect: 此 lane 在 gutter 坐标系中的矩形
    ///   - dirtyRect: 本次 draw(_:) 的 dirty 矩形，用于提前 bail-out
    ///   - appearance: 当前 NSAppearance
    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    )

    /// 对点坐标（在 laneRect 坐标系内）进行命中测试
    /// 返回被命中的行号（1-based），若无命中返回 nil
    func hitTest(
        point: CGPoint,
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect
    ) -> Int?

    /// Lane 在宽度变化时通知 host 重新计算布局
    /// host 在注册 lane 后设置此回调
    var onPreferredWidthChange: (() -> Void)? { get set }

    /// Lane 计算自身的失效计划（基于前后 snapshot diff）
    /// 默认实现返回 .full（安全退路）
    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan
}

// MARK: - Default Implementation

extension CodeEditorGutterLane {
    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan {
        .full
    }
}

// MARK: - CodeEditorGutterLaneInvalidationPlan

enum CodeEditorGutterLaneInvalidationPlan {
    /// 整个 lane 需要重绘
    case full
    /// 仅特定行需要重绘
    case lines(Set<Int>)
    /// 无变化，无需重绘
    case none
}

// MARK: - CodeEditorGutterHitResult

/// Gutter 命中测试结果
struct CodeEditorGutterHitResult: Equatable {
    /// 被命中的行号（1-based）
    let lineNumber: Int
    /// 响应命中的 Lane 标识符
    let laneID: String
}
