# Feature 11 — Gutter Lane 架构 实现计划

**前置完成**: F10（行高度精确度量系统）✅  
**文档日期**: 2026-04-07  
**预计 Story 数**: 4 task（参考 F9/F10 规模）  
**对应设计文档**: `docs/plans/2026-04-07-code-editor-iteration-design.md` § F11

---

## 1. 背景与目标

### 1.1 问题

当前 `CodeEditorGutterView` 是单体实现：
- `CodeEditorGutterRenderer` 将行号、诊断圆点、分隔线混合绘制在同一个 `draw()` 中
- 宽度计算基于"最大行号位数"的单一公式，没有扩展点
- 无法注册新的 gutter 元素类型（折叠指示符、git 差异色条、断点图标等）
- Hit testing 直接在 `mouseDown` 里做坐标计算，与渲染逻辑耦合

### 1.2 目标

将 gutter 拆分为**有序 Lane 阵列**：每个 Lane 是一个独立列，拥有自己的宽度、绘制职责和命中测试逻辑。`CodeEditorGutterView` 变为 **Lane Host**，将 draw/hit-test 分发给各 lane。

### 1.3 为什么需要这个先做

| 后续 Feature | 依赖 F11 |
|---|---|
| F12 折叠 Chevron Lane | 需要独立列 + 折叠状态快照字段 |
| F13 Git Diff Stripe Lane | 需要独立列 + gitDiff 状态快照字段 |
| 断点 Lane | 需要命中回调机制 |
| Code Action Lane | 需要 hover 状态 + 命中回调 |

---

## 2. 外部参考调研

### 2.1 VSCode — `GlyphMarginWidgets` / `GlyphMarginLane`

**来源**: `src/vs/editor/browser/viewParts/glyphMargin/glyphMargin.ts`

VSCode 的 glyph margin 采用 lane 索引乘以行高来计算每个 lane 的 X 偏移：

```typescript
// VSCode 核心逻辑（简化）
export enum GlyphMarginLane {
    Left = 1,
    Center = 2,
    Right = 3
}

// X 偏移 = marginLeft + laneIndex * lineHeight
const x = glyphMarginLeft + laneIndex * lineHeight;
```

每个渲染请求携带 `{ lineNumber, laneIndex, zIndex }` 三元组，按 `(lineNumber ASC, laneIndex ASC, zIndex DESC)` 排序后绘制，确保：
- 同行多 lane 不重叠
- 同 lane 多装饰按 zIndex 叠放

VSCode 的 `_glyphMarginDecorationLaneCount` 记录总 lane 宽度倍数，驱动整个 gutter 列宽 = `laneCount × lineHeight`。

**借鉴点（AppKit 适配）**:
- Lane 宽度由 `preferredWidth` 属性声明（AppKit 无 DOM，需用 CG 矩形）
- Lane X 偏移 = 所有前置 lane 的 `preferredWidth` 之和（累加而非 `laneIndex × lineHeight`）
- zIndex 机制在本 F11 阶段仅保留接口，留给 F12+ 实际使用

### 2.2 VSCode — `model.ts` `GlyphMarginLane` 枚举

```typescript
export enum GlyphMarginLane {
    Left = 1,
    Center = 2,
    Right = 3
}
```

VSCode 是静态枚举，每个 lane 在枚举里注册。  
**agentGui 不采用静态枚举**，改为动态注册的协议实例数组，更易扩展。

### 2.3 Zed — `element.rs` Gutter 渲染架构

Zed 的 gutter 渲染在 `element.rs` 中拆分为清晰的独立函数：
- `layout_line_numbers()` — 行号布局
- `layout_crease_toggles()` — 折叠 chevron（即 F12 对应功能）
- `layout_gutter_diff_hunks()` — git diff 色条（即 F13）
- `layout_breakpoints()` — 断点
- `prepaint_gutter_button()` — 通用 gutter 按钮定位辅助

Zed 的 `GutterDimensions` 结构体汇总各 lane 宽度：
```rust
pub struct GutterDimensions {
    pub left_padding: Pixels,      // 行号左边距
    pub right_padding: Pixels,     // 行号右边距（折叠区域在这里）
    pub width: Pixels,             // 总宽度
    pub margin: Pixels,            // 文本区左边距
    pub fold_area_width: Pixels,   // 折叠指示符区域宽度
    pub git_blame_entries_width: Option<Pixels>,
}
```
这与 F11 的"Lane 宽度求和"同构。

**借鉴点**:
- 折叠状态不在 Gutter 里维护，通过 snapshot 字段注入（`is_line_folded()`）
- 每个 lane 函数独立接收 `gutter_hitbox: &Hitbox` 而非共享状态
- `prepaint_gutter_button()` 通用定位 → 我们对应 `laneRect(forLane:atLine:)` 辅助方法

### 2.4 AppKit 约束

与 VSCode（DOM 元素逐 lane 插入）和 Zed（GPUI 元素树）不同：
- AppKit `NSView` 不能廉价地插入数百个子 view（每行一个）
- **所有 lane 必须在 `draw(_:)` 的单次 CG 绘图调用里完成**
- hit testing 需要在 `mouseDown` 里手动对 lane 矩形做坐标查询
- 这驱动了"每个 Lane 是绘图协议而非视图"的决策

---

## 3. 核心协议设计

### 3.1 `CodeEditorGutterLane` 协议

```swift
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
    ///   - laneRect: 此 lane 在 gutter 坐标系中的矩形（已含 line 高度信息）
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
}
```

**设计说明**:
- `draw()` 接收当前 gutter 坐标系的 `laneRect`（已由 host 算好），lane 内部直接在此矩形内绘图
- `hitTest()` 同样工作在 lane 局部矩形内，简化各 lane 的坐标计算
- `onPreferredWidthChange` 委托链：lane 内部状态变化 → 触发此回调 → host 重新计算总宽度

### 3.2 `CodeEditorGutterHitResult` 值类型

```swift
/// Gutter 命中测试结果
struct CodeEditorGutterHitResult: Equatable {
    /// 被命中的行号（1-based）
    let lineNumber: Int
    /// 响应命中的 Lane 标识符
    let laneID: String
}
```

---

## 4. 内置 Lane 实现

### 4.1 `CodeEditorLineNumberLane`

从现有 `CodeEditorGutterRenderer` 中抽取行号绘制逻辑。

**关键属性**:
- `id = "lineNumber"`
- `preferredWidth`: 与现有 `CodeEditorGutterRenderer.requiredWidth()` 相同，使用 digits × 等宽字体宽度 + 20pt padding

**绘制内容** (直接迁移):
- 当前行高亮背景
- 行号字符串（`NSAttributedString` drawing）
- **不再绘制分隔线**（分隔线移到 `CodeEditorGutterView.draw()` 作为 host 级装饰）

**Hit testing**:
- 返回对应行号
- 可用于 F12 触发折叠（但折叠命中在 F12 的专有 lane 处理，行号 lane 仅返回行号）

**缓存迁移**:
- 原 `WidthCacheKey { digits, appearanceName }` → 移入此 lane 内部
- 原 `AttributeCacheKey { isCurrentLine }` → 同上

### 4.2 `CodeEditorDiagnosticDotLane`

从现有 `CodeEditorGutterRenderer` 中抽取诊断圆点绘制逻辑。

**关键属性**:
- `id = "diagnosticDot"`
- `preferredWidth`: 固定为 `lineHeight × 0.6`（当 snapshot 中有诊断时为此值，否则为 `0` 或最小保留宽度）

> **注**: F11 阶段宽度可先硬编码为固定值（如 16pt），F14 再细化。

**绘制内容** (直接迁移):
- `NSBezierPath` oval 绘制诊断色圆点
- 颜色映射（error/warning/info → 红/黄/蓝）

**Hit testing**:
- 诊断点通常不需要命中测试（tooltip 由 hover 层处理）
- 返回 `nil`，或仅返回行号用于外部 hover 处理

---

## 5. `CodeEditorGutterView` 重构

### 5.1 新的核心属性

```swift
final class CodeEditorGutterView: NSView {
    // 有序 lane 数组（显示顺序 = 数组顺序，左 → 右）
    private var lanes: [any CodeEditorGutterLane] = []

    // 每个 lane 在当前布局下的 x 偏移（由 recalculateLaneLayout() 维护）
    private var laneOffsets: [String: CGFloat] = [:]

    // 保持不变
    private var snapshot: CodeEditorGutterViewportSnapshot
    var onRequiredWidthChange: (() -> Void)?
    var onGutterLaneHit: ((CodeEditorGutterHitResult) -> Void)?
    
    // 计算属性，取代 cachedRequiredWidth
    var requiredWidth: CGFloat {
        lanes.reduce(0) { $0 + $1.preferredWidth(for: snapshot, appearance: effectiveAppearance) }
    }
    // ...
}
```

### 5.2 Lane 注册

```swift
extension CodeEditorGutterView {
    /// 注册 lane（按调用顺序排列，左 → 右）
    /// 重复注册同 id 的 lane 会替换旧 lane
    func register(lane: any CodeEditorGutterLane) {
        // 1. 绑定 onPreferredWidthChange 回调
        var lane = lane
        lane.onPreferredWidthChange = { [weak self] in
            self?.handleLaneWidthChange()
        }
        // 2. 替换或追加
        if let idx = lanes.firstIndex(where: { $0.id == lane.id }) {
            lanes[idx] = lane
        } else {
            lanes.append(lane)
        }
        handleLaneWidthChange()
    }
}
```

### 5.3 Lane Rect 计算

```swift
extension CodeEditorGutterView {
    /// 计算指定 lane 在 gutter 坐标系中的全高矩形
    func laneFrame(for lane: any CodeEditorGutterLane) -> NSRect {
        let x = laneOffsets[lane.id, default: 0]
        let w = lane.preferredWidth(for: snapshot, appearance: effectiveAppearance)
        return NSRect(x: x, y: 0, width: w, height: bounds.height)
    }

    private func recalculateLaneLayout() {
        var x: CGFloat = 0
        for lane in lanes {
            laneOffsets[lane.id] = x
            x += lane.preferredWidth(for: snapshot, appearance: effectiveAppearance)
        }
    }

    private func handleLaneWidthChange() {
        let previous = requiredWidth
        recalculateLaneLayout()
        let current = requiredWidth
        if previous != current {
            invalidateIntrinsicContentSize()
            onRequiredWidthChange?()
        }
        setNeedsDisplay(bounds)
    }
}
```

### 5.4 Draw 分发

```swift
override func draw(_ dirtyRect: NSRect) {
    // Host 级：绘制分隔线
    let separatorRect = NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height)
    NSColor.separatorColor.setFill()
    separatorRect.integral.fill()

    // 分发给各 lane
    for lane in lanes {
        let frame = laneFrame(for: lane)
        guard frame.intersects(dirtyRect) else { continue }
        lane.draw(
            snapshot: snapshot,
            laneRect: frame,
            dirtyRect: dirtyRect,
            appearance: effectiveAppearance
        )
    }
}
```

### 5.5 Hit Testing

```swift
override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    for lane in lanes {
        let frame = laneFrame(for: lane)
        guard frame.contains(point) else { continue }
        let localPoint = CGPoint(x: point.x - frame.origin.x, y: point.y - frame.origin.y)
        if let lineNumber = lane.hitTest(point: localPoint, snapshot: snapshot, laneRect: frame) {
            onGutterLaneHit?(CodeEditorGutterHitResult(lineNumber: lineNumber, laneID: lane.id))
            return
        }
    }
    super.mouseDown(with: event)
}
```

---

## 6. Snapshot 扩展（F12/F13 预埋）

F11 阶段向 `CodeEditorGutterViewportSnapshot` 新增两个字段，数据在本阶段均为空/默认值：

```swift
struct CodeEditorGutterViewportSnapshot: Equatable, Sendable {
    // 现有字段（不变）
    let lineCount: Int
    let visibleLineRange: ClosedRange<Int>
    let currentLine: Int?
    let lineMetrics: [CodeEditorVisibleLineMetric]
    let diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]

    // F12 预留：可折叠行号集合（1-based），host 填充，供折叠 lane 读取
    // F11 阶段始终为空集合
    let foldableLines: Set<Int>        // default: []
    let foldedLines: Set<Int>          // default: []

    // F13 预留：每行 git diff 状态，供 git diff lane 读取
    // F11 阶段始终为空字典
    let gitDiffByLine: [Int: CodeEditorGitDiffKind]  // default: [:]
}

/// F13 预留类型（F11 阶段定义但不使用）
enum CodeEditorGitDiffKind: Equatable, Sendable {
    case added
    case modified
    case deleted
}
```

**迁移兼容性**：新增字段提供默认值，所有现有调用方无需修改：
```swift
// 现有创建方式保持编译：
CodeEditorGutterViewportSnapshot(
    lineCount: n,
    visibleLineRange: range,
    currentLine: nil,
    lineMetrics: metrics,
    diagnosticsByLine: diagnostics
)
// 编译器报错后新增缺失参数，或提供 memberwise 默认扩展
```

> **建议**: 为新字段提供默认值 via `init` 扩展，避免改动所有创建处。

---

## 7. `CodeEditorGutterRenderer` 迁移策略

### 7.1 保留并降级

`CodeEditorGutterRenderer` **不删除**，改为 `LineNumberLane` 的内部实现细节：

```
Before F11:
  CodeEditorGutterView
    └── CodeEditorGutterRenderer  (对外暴露)

After F11:
  CodeEditorGutterView
    ├── CodeEditorLineNumberLane
    │     └── (内部使用 CodeEditorGutterRenderer 的绘制/缓存逻辑)
    └── CodeEditorDiagnosticDotLane
          └── (内部实现，直接绘制)
```

- `CodeEditorGutterRenderer` 的 `requiredWidth()` 方法迁移为 `LineNumberLane.preferredWidth()`
- `CodeEditorGutterRenderer` 的 `draw()` 行号绘制逻辑迁移为 `LineNumberLane.draw()`
- `CodeEditorGutterRenderer.invalidationPlan()` 迁移为新的失效策略（见 §8）
- 完成迁移后 `CodeEditorGutterRenderer` 作为 internal struct 保留或以 `@available(*, deprecated)` 标注

### 7.2 失效路径

原来的 `invalidationPlan()` 返回全局 gutter 的 plan。F11 改为**per-lane 失效**：

```swift
// Lane 协议扩展（optional requirement）
protocol CodeEditorGutterLane {
    // ...（基础协议如 §3.1）

    /// Lane 计算自身的失效计划（基于前后 snapshot diff）
    /// 默认实现返回 .full（安全退路）
    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan
}

enum CodeEditorGutterLaneInvalidationPlan {
    /// 整个 lane 需要重绘
    case full
    /// 仅特定行需要重绘
    case lines(Set<Int>)
    /// 无变化，无需重绘
    case none
}
```

Host 合并各 lane 计划：
```swift
private func apply(_ snapshot: CodeEditorGutterViewportSnapshot) {
    let previous = self.snapshot
    self.snapshot = snapshot

    // 计算哪些 lane 需要重绘、哪些行
    for lane in lanes {
        switch lane.invalidationPlan(from: previous, to: snapshot) {
        case .full:
            setNeedsDisplay(laneFrame(for: lane))
        case .lines(let lines):
            for line in lines {
                if let m = snapshot.lineMetrics.first(where: { $0.line == line }) {
                    let lineInLane = NSRect(
                        x: laneFrame(for: lane).origin.x,
                        y: m.rect.minY,
                        width: laneFrame(for: lane).width,
                        height: m.rect.height
                    ).integral
                    setNeedsDisplay(lineInLane)
                }
            }
        case .none:
            break
        }
    }
}
```

---

## 8. 容器联动：`CodeEditorViewportContainerView`

`CodeEditorViewportContainerView.layout()` 已使用 `gutterView.requiredWidth`：

```swift
// 现有（无需修改，只是 requiredWidth 将由 lanes 求和驱动）
override func layout() {
    let gutterWidth = gutterView.requiredWidth  // 现在由若干 lane 宽度之和给出
    gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height).integral
    scrollView.frame = NSRect(
        x: gutterWidth, y: 0,
        width: max(0, bounds.width - gutterWidth),
        height: bounds.height
    ).integral
}
```

**无需修改此文件**。Lane 注册时触发 `onRequiredWidthChange` → `CodeEditorViewportContainerView` 响应 → 调用 `layout()` → 更新 frame。

---

## 9. 文件变更清单

### 新建文件

| 文件路径 | 说明 |
|---|---|
| `agentGui/Views/CodeEditor/CodeEditorGutterLane.swift` | `CodeEditorGutterLane` 协议 + `CodeEditorGutterHitResult` + `CodeEditorGutterLaneInvalidationPlan` |
| `agentGui/Views/CodeEditor/Lanes/CodeEditorLineNumberLane.swift` | 行号 Lane 实现 |
| `agentGui/Views/CodeEditor/Lanes/CodeEditorDiagnosticDotLane.swift` | 诊断圆点 Lane 实现 |

### 修改文件

| 文件路径 | 变更说明 |
|---|---|
| `CodeEditorGutterViewportSnapshot.swift` | 新增 `foldableLines`, `foldedLines`, `gitDiffByLine` 字段（有默认值）|
| `CodeEditorGutterView.swift` | 重构为 Lane Host：`lanes` 数组、lane 注册、`laneFrame()`、draw 分发、hit-test 路由 |
| `CodeEditorGutterRenderer.swift` | 降级为 `CodeEditorLineNumberLane` 的内部实现，移除对外暴露的 draw/requiredWidth |

### 不变文件

- `CodeEditorViewportContainerView.swift` — 无需修改
- `CodeEditorGutterViewportSnapshot.swift` 的 `CodeEditorGutterInvalidationPlan` 枚举 — 暂保留，在 §7.2 所述的 per-lane plan 完整替代后于 F11 后续删除

---

## 10. 初始化顺序

在 `CodeEditorViewportContainerView` 或其父 view 创建 `CodeEditorGutterView` 后，注册内置 lane：

```swift
let gutterView = CodeEditorGutterView(lineCount: initialLineCount)

// 注册内置 lane（左 → 右顺序）
gutterView.register(lane: CodeEditorLineNumberLane())
gutterView.register(lane: CodeEditorDiagnosticDotLane())

// 连接命中回调
gutterView.onGutterLaneHit = { [weak self] hit in
    self?.handleGutterHit(hit)
}
```

---

## 11. 测试计划

### 11.1 单元测试

**文件**: `agentGuiTests/CodeEditorGutterLaneTests.swift`（新建）

| 测试名 | 验证点 |
|---|---|
| `testLaneTotalWidth` | 注册 2 个 lane 后 `requiredWidth` = lane1.width + lane2.width |
| `testLaneFrameNonOverlap` | 相邻 lane 的 frame 不重叠（x 连续且不交叉） |
| `testHitTestRouting` | 点在 lane1 区域内 → 触发 lane1 的 hitTest，不触发 lane2 |
| `testHitTestNoLane` | 点落在所有 lane 之外 → `onGutterLaneHit` 不触发 |
| `testLaneRegistrationReplace` | 注册同 id lane 两次 → lanes 数组长度不变，以新 lane 替代旧 lane |
| `testWidthChangeCallback` | lane 内部调用 `onPreferredWidthChange` → `onRequiredWidthChange` 触发 |
| `testSnapshotNewFields` | 已有 snapshot 构建方式编译通过（新字段有默认值） |

### 11.2 集成测试

**文件**: `agentGuiTests/CodeEditorGutterViewIntegrationTests.swift`（扩展现有或新建）

| 测试名 | 验证点 |
|---|---|
| `testLineNumberLaneDrawsCorrectly` | 修改 snapshot 后，行号 lane 触发正确 dirty rect（基于 F10 行高度 metric）|
| `testDiagnosticDotLaneWidth` | 无诊断时宽度不为 0（预留空间）；有诊断时宽度不变（固定宽度） |
| `testF10Compatibility` | 基于 F10 `CodeEditorTextViewIntegrationTests` 的行高度精度不受 lane 拆分影响 |

### 11.3 保回归测试

运行 `CodeEditorGutterFixTests`（F10 存量测试套件）确保 gutter 宽度计算行为不变。

---

## 12. 实现步骤（按 Task 拆分）

### Task 1 — 协议与快照扩展（2-3h）

1. 创建 `CodeEditorGutterLane.swift`（协议 + 相关类型）
2. 扩展 `CodeEditorGutterViewportSnapshot`（新增3个字段，有默认值）
3. 写 Task 1 相关单元测试（snapshot 编译兼容性 + 字段读写）

### Task 2 — 内置 Lane 迁移（3-4h）

1. 创建 `CodeEditorLineNumberLane.swift`（从 `CodeEditorGutterRenderer` 迁移行号逻辑）
2. 创建 `CodeEditorDiagnosticDotLane.swift`（从 `CodeEditorGutterRenderer` 迁移诊断圆点逻辑）
3. 各自实现 `invalidationPlan()` 方法
4. 迁移缓存（`WidthCacheKey`, `AttributeCacheKey`）到对应 lane 内部

### Task 3 — `CodeEditorGutterView` 重构（4-5h）

1. 添加 `lanes: [any CodeEditorGutterLane]` 和 `laneOffsets: [String: CGFloat]`
2. 实现 `register(lane:)` + `laneFrame(for:)` + `recalculateLaneLayout()`
3. 重写 `draw(_:)` 为 lane 分发模式
4. 重写 `mouseDown` 为 lane hit-test 路由
5. 将 `onGutterLaneHit` 接入调用方（替换之前的直接 mousedown 处理）
6. 在初始化处注册内置 lane

### Task 4 — 测试与收尾（2-3h）

1. 运行现有 `CodeEditorGutterFixTests` → 不应有回归
2. 编写 `CodeEditorGutterLaneTests.swift`（§11.1 所列测试）
3. 将 `CodeEditorGutterRenderer` 标记 `@available(*, deprecated, message: "Use CodeEditorLineNumberLane")` 
4. 清理孤立代码

---

## 13. 风险与注意事项

| 风险 | 说明 | 缓解措施 |
|---|---|---|
| Lane 绘制顺序 | 叠加绘制时，后注册的 lane 覆盖先注册的（如果 frame 有重叠） | Lane 宽度明确，frame 不重叠，故此风险低；分隔线改为 host 绘制避免覆盖 |
| F10 行高度 metric 精度 | Lane 的 `lineRect` 依赖 `snapshot.lineMetrics` 中的 `rect.minY`/`rect.height`，这是 F10 精确计算的结果 | 测试中验证 line rect 与 F10 行高度系统联通 |
| `preferredWidth` 频繁调用 | `requiredWidth` 是计算属性，每次访问都遍历 lanes 调用 `preferredWidth` | 各 lane 内部做宽度缓存，保持 `preferredWidth` 纯读且 O(1) |
| Snapshot 字段增加编译破坏 | `CodeEditorGutterViewportSnapshot` 是 memberwise initializer，新字段会导致所有创建处编译报错 | 提供一个 internal `init` 兼容扩展（带默认值），或先提供 `withDefaults()` 便利构造器 |
| `[any CodeEditorGutterLane]` 存在量化类型性能 | Swift 存在量化类型在调用 protocol method 时有动态派发 | Lane 数量固定（2-5），性能影响可忽略 |

---

## 14. 后续 Feature 接入指引

F11 完成后，后续 feature 接入 gutter lane 的模式如下：

```swift
// F12 折叠 Chevron Lane 接入示例
let foldLane = CodeEditorFoldChevronLane(foldService: foldService)
gutterView.register(lane: foldLane)

// F12 需要在 snapshot 更新时填充 foldableLines 和 foldedLines：
// CodeEditorGutterViewportSnapshot(
//   ...(现有字段),
//   foldableLines: foldService.foldableLines(in: visibleRange),
//   foldedLines: foldService.foldedLines(in: visibleRange),
// )
```

Snapshot 字段在 F11 阶段已预埋，F12 只需：
1. 填充 snapshot 字段（在构建 snapshot 处）
2. 实现 `CodeEditorFoldChevronLane` 并注册
