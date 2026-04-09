# 2026-03-30 Code Editor 自定义高性能 Gutter 设计方案

日期：2026-03-30

目标：用编辑器自有的高性能 gutter column 替代当前基于 NSRulerView 的实现，获得可完全控制的背景、分隔线、宽度、交互和增量重绘行为，同时保持现有 NSTextView 输入、选区、IME、撤销和可访问性能力，并为后续 unified diff 与 side-by-side diff 视图预留可复用 gutter 扩展接缝。

关联现状代码：

1. `agentGui/Views/CodeEditor/CodeEditorTextView.swift`
2. `agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
3. `agentGui/Views/CodeEditor/CodeEditorView.swift`
4. `agentGui/ViewModels/CodeEditorViewModel.swift`
5. `agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
6. `agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`

外部参考：

1. Apple AppKit 文档：`NSRulerView`、`NSScrollView`、`NSTextView`、`NSLayoutManager`、`NSTextLayoutManager`
2. VS Code: `Text Buffer Reimplementation`、`Optimizations in Syntax Highlighting`
3. CodeMirror 6: viewport state、generic gutters、merge view / unified merge view、composition support
4. Xi editor: rope science、minimal invalidation、incremental word wrapping
5. Tree-sitter 文档及其列出的增量解析研究论文
6. VS Code Source Control / diff editor: side-by-side diff、editor gutter indicators、merge editor

---

## 1. 结论先行

当前 gutter 的根本问题不是 `drawHashMarksAndLabels(in:)` 里那几行绘制代码不够细，而是它仍然寄生在 `NSScrollView.verticalRulerView / NSRulerView` 这套 AppKit ruler 机制上。

这条路线先天不适合我们要的代码编辑器 gutter：

1. `NSRulerView` 的语义是 ruler，而不是 editor-owned gutter column。
2. 它的布局、背景、zero mark、accessory、marker 生命周期都受 `NSScrollView.tile()` 和 ruler 约定影响。
3. 它天然面向“标尺 + marker”模型，而不是“可见行号 + 当前行高亮 + diagnostics dot + breakpoints/folding 扩展位”。
4. 需要严格限制 gutter 背景、边界线、点击命中区和后续扩展位时，`NSRulerView` 会持续泄漏不需要的宿主行为。

因此，推荐方案不是继续重写 `CodeEditorGutterView: NSRulerView`，而是把 gutter 从 ruler 体系里拿出来，做成编辑器自己的 sibling column：

1. 外层使用自定义容器视图，左侧是 gutter column，右侧是现有 `NSScrollView + NSTextView`。
2. gutter 仅消费一个轻量 viewport snapshot，不直接持有整份 document，也不创建每行子视图。
3. gutter 在自己的 bounds 内裁剪和绘制，完全拥有背景、分隔线、标记和点击语义。
4. 文本输入、IME、选择、撤销、拼写、辅助功能仍然继续留在 `NSTextView` 路线上，不做“大爆炸式自绘编辑器”重写。
5. gutter 的数据模型从第一天就不只服务单编辑器视图，而要能被未来的 unified diff 与双栏 diff 编辑器直接复用。

换句话说，应该把这次改造定义为：

“保留 TextKit 作为文本输入内核，替换 gutter 的宿主与渲染架构。”

这是一条成本可控、收益明确、并且与当前仓库高性能代码编辑器路线一致的方案。

## 2. 现状诊断

### 2.1 当前实现的真实边界

当前代码路径是：

1. `CodeEditorTextView.makeNSView` 创建 `NSScrollView` 与 `CodeEditorPlatformTextView`。
2. coordinator 在 `installGutter(for:textView:)` 中把 `CodeEditorGutterView` 安装到 `scrollView.verticalRulerView`。
3. `updateGutterState(for:)` 把 `lineCount`、`visibleLineRange`、`currentLine`、`diagnosticsByLine` 推给 `NSRulerView` 子类。
4. gutter 再通过 `backgroundRect(forLine:)` 反查 `NSTextView` 的行几何并绘制行号和诊断点。

这套方案目前已经有两点是对的：

1. gutter 没有为每一行建一个 `NSView`，而是按可见区绘制。
2. gutter 状态已经收敛成较小的增量输入，而不是直接把整份文本传进去。

但它仍然有三个结构问题。

### 2.2 结构问题一：所有权错位

`NSRulerView` 的 owner 是 `NSScrollView` 的 ruler 子系统，不是 editor 自己。

这带来几个后果：

1. gutter 的宽度和 tiling 由 scroll view 的 ruler 机制参与决定。
2. gutter 背景与 editor 内容区不是同一层级的自有布局，而是 scroll view 的附属区域。
3. 后续如果要做 breakpoint lane、fold chevron lane、git diff stripe lane，就会继续把编辑器语义塞进 ruler 语义。
4. 未来如果要把同一套 gutter lane 复用到 unified diff 或 side-by-side diff，`NSRulerView` 会让单编辑器与 diff 编辑器的宿主模型分叉。

这不是 API 用法错误，而是架构错位。

### 2.3 结构问题二：无法彻底“空制”背景与边界

用户提出的核心诉求之一是 gutter 要能被完全控制。当前方案很难做到这一点。

Apple 文档明确说明了几件事：

1. `NSScrollView` 会负责 rulers 的可见性和 tiling。
2. `NSRulerView` 自带 measurement、origin offset、markers、accessory view 等概念。
3. `NSTextView` 还会通过 `updateRuler()` 和 ruler-related delegate 路径参与 ruler 体系。

这意味着即使我们当前只重写 `drawHashMarksAndLabels(in:)`，本质上仍在一个不属于代码编辑器的 UI 子系统里工作。对于严格受限的 gutter 边界、背景色块、separator ownership、hover region、hit testing，这会持续制造摩擦。

一旦未来要做 diff 编辑器，这种摩擦会更大，因为普通编辑器 gutter 与 diff gutter 会开始依赖不同的宿主模型。

### 2.4 结构问题三：扩展成本会越来越高

代码编辑器 gutter 很少只停在行号阶段。后续高概率会出现：

1. diagnostics stripe 或 severity bar
2. breakpoint / execution marker
3. fold affordance
4. blame / changed lines stripe
5. selection / multi-cursor lane

如果继续用 `NSRulerView`，这些能力要么都塞进一个越来越奇怪的 ruler subclass，要么拆成 marker / accessory / custom draw 的混搭。这条路线会让未来每加一个能力都更贵。

## 3. Apple 文档调研结论

### 3.1 `NSScrollView`

Apple 文档指出：

1. `NSScrollView` 是 AppKit 滚动体系的中心协调者。
2. 它通过 `documentView`、`contentView`、scroller、ruler views 一起完成布局。
3. ruler 是 scroll view 自带的一等子系统，`hasVerticalRuler`、`verticalRulerView`、`rulersVisible` 都是 scroll view 的固有布局通道。
4. `tile()` 会重新布置 content、scroller 和 ruler。

对本项目的含义是：

如果继续把 gutter 作为 vertical ruler，那么 gutter 的布局生命周期天然和 scroll view 的 ruler 机制绑死，而不是与 editor 自己的 layout contract 绑死。

### 3.2 `NSRulerView`

Apple 文档把 `NSRulerView` 定义为：显示 arbitrary units、markers、accessory view 的 ruler。其核心 API 也是围绕：

1. `clientView`
2. `markers`
3. `accessoryView`
4. `originOffset`
5. `drawHashMarksAndLabels(in:)`

这套模型适合段落样式标尺，不适合代码编辑器 gutter。代码编辑器 gutter 需要的是：

1. 可见行窗口驱动的绘制
2. 多 lane 组合
3. editor-owned hit testing
4. 严格的背景与边界控制
5. 与 diagnostics、breakpoint、folding 的统一扩展协议

这些诉求都不是 `NSRulerView` 的主设计目标。

### 3.3 `NSTextView`

Apple 文档确认 `NSTextView` 仍然是 AppKit text system 的前端入口，负责：

1. 文本显示与编辑
2. selection
3. input management / marked text / IME
4. undo
5. accessibility

同时文档还强调：在 macOS 12 及以后，如果显式访问 `layoutManager`，`NSTextView` 可能回退到 `NSLayoutManager` 兼容模式。

这对我们很关键：当前实现已经明确依赖 `layoutManager`、`glyphRange(forBoundingRect:)`、`lineFragmentRect(...)` 这条 TextKit 1 路线，所以本次 gutter 改造不应顺带尝试全面迁移 TextKit 2。否则会把“替换 gutter 宿主”扩成“替换文本布局内核”，风险完全失控。

### 3.4 `NSLayoutManager`

Apple 文档里对本问题最有价值的点有三个：

1. 可以启用 `allowsNonContiguousLayout`，让大文档不必从头到尾连续 layout。
2. 可以用 `glyphRange(forBoundingRect:in:)`、`characterRange(forGlyphRange:actualGlyphRange:)`、`lineFragmentRect(forGlyphAt:...)`、`enumerateLineFragments(...)` 做几何查询。
3. layout manager 不应跨线程同时使用，显示相关布局仍然应视为主线程资源。

这直接导向本方案的几何策略：

1. gutter 不自己算文本排版。
2. gutter 从 text view / layout manager 拉取可见区行几何。
3. 所有重计算限制在 viewport 及近场区域。

### 3.5 `NSTextLayoutManager`

Apple 文档说明 `NSTextLayoutManager` 和 `NSTextViewportLayoutController` 更适合做现代 viewport 驱动布局，长期方向更优。

但对当前仓库而言，它只能作为未来兼容目标，而不是本期依赖，原因有三：

1. 现有实现已经深度绑定 `NSTextView + NSLayoutManager`。
2. 本期目标是替换 gutter 方案，不是重建排版内核。
3. TextKit 2 迁移要连带改 selection、hover geometry、decorations、reveal request、diagnostics underline 等一整条链路。

因此，TextKit 2 应被设计成“后续兼容接缝”，不是“本期前置依赖”。

## 4. 外部工程实践与算法调研结论

### 4.1 VS Code: text buffer 与按行心智模型

VS Code 的 piece tree 设计说明了两个对本项目很重要的事实：

1. 编辑器的用户心智和大量下游能力本质上是 line-based 的。
2. 真正的热点不一定是 `insert / delete` 本身，往往是 `getLineContent`、viewport 渲染、tokenization 这些读路径。

这对 gutter 的启示不是“现在就换 piece tree”，而是：

1. gutter 设计必须围绕行窗口，而不是整个文档。
2. 所有状态都要预先压缩成对 viewport 渲染友好的结构。
3. 不要在滚动时把 `line -> geometry -> attributed string -> view tree` 全链路重新做一遍。

### 4.2 VS Code: token 与元数据压缩

VS Code 的 syntax highlighting 优化强调：

1. 尽量用二进制或紧凑元数据表达渲染状态。
2. 折叠连续等价区间，减少对象分配。
3. 单次遍历完成更多工作，减少中间对象与 GC 压力。

对 gutter 的直接启发是：

1. 行号显示状态、当前行状态、severity 状态应被压缩为小型 snapshot，而不是字典 + 多层对象在滚动期间反复拼装。
2. gutter renderer 应尽量使用值类型 snapshot 与 cache key，而不是频繁创建 attributed string 与 paragraph style。
3. digits width、颜色、字号、alignment 等样式对象都应该缓存。

### 4.3 CodeMirror 6: viewport-first 与 generic gutter

CodeMirror 6 的经验可以概括成两句：

1. viewport state 不属于 document model，而属于 view state。
2. gutter 应是一个 generic extension surface，而不是写死的单一行号实现。

这与本项目非常契合。我们应把 gutter 输入限制为 view-local snapshot：

1. `visibleLineRange`
2. `currentLine`
3. `displayedLineMetrics`
4. `diagnosticsByLine`
5. 将来可扩展的 `markersByLine`

### 4.4 Xi editor: minimal invalidation

Xi 的 rope science 与 minimal invalidation 相关思路强调：

1. 修改后只重绘受影响区域。
2. 计算与显示都应尽量局部化。
3. viewport 和数据结构之间应该有稳定的摘要层。

这基本上就是本项目 gutter 的核心准则：

1. 诊断变化只失效受影响行。
2. current line 变化只失效 old/new 两行。
3. 滚动只失效新旧 viewport 的差集，不做全 gutter 重绘。

### 4.5 Tree-sitter 与增量解析论文

Tree-sitter 当前文档仍然把其设计建立在一组经典 incremental parsing 论文上，包括：

1. `Practical Algorithms for Incremental Software Development Environments`
2. `Efficient and Flexible Incremental Parsing`
3. `Incremental Analysis of Real Programming Languages`

这组资料的价值不在于让本期去做 parser，而在于提供一个清晰原则：

增量编辑系统的正确方向，是保存可复用状态并把重算边界限制在局部，而不是每次从全局重新开始。

因此，即使 gutter 不是 parser，它也应该遵守同样的方法论：

1. 保存 viewport summary
2. 保存 line geometry cache
3. 保存 stable style cache
4. 用 diff 驱动 invalidate

### 4.6 关于“最新论文”的结论

本次可直接获取且与问题强相关的公开资料里，最可落地的并不是某一篇 2025 或 2026 的新论文，而是：

1. Apple 当前文档给出的平台约束
2. Tree-sitter 持续引用的 incremental parsing 经典研究
3. VS Code、CodeMirror、Xi 这些已经在真实编辑器里被验证过的工程路线

对本项目而言，工程决策权重应当是：

Apple API 约束 > 已验证编辑器工程实践 > 通用增量算法论文 > 追逐较新的但不一定贴题的论文。

## 5. 设计目标

### 5.1 必须达成的目标

1. gutter 脱离 `NSRulerView`，成为 editor-owned column。
2. gutter 背景、边界线、宽度、点击区域完全由编辑器自身控制。
3. 仅按可见区和受影响行增量绘制，不创建 per-line subviews。
4. 保持现有 `NSTextView` 输入、选区、IME、撤销与 accessibility。
5. 为 breakpoint、folding、git stripe 等后续能力预留 lane 扩展位。
6. 大文件与频繁滚动场景下不发生明显掉帧或整列重绘抖动。
7. 同一套 gutter core model 能同时支撑普通代码编辑、unified diff 和 side-by-side diff，而不是未来再做第二套 diff gutter。

### 5.2 非目标

1. 本期不重写文本缓冲内核，不引入 piece tree / rope 替换 `String`。
2. 本期不整体迁移到 TextKit 2。
3. 本期不实现完整 breakpoint / folding / blame 功能，只要为其留出结构。
4. 本期不做完全自绘文本编辑器。
5. 本期不直接实现完整 diff editor，但必须把 gutter、viewport snapshot、lane 配置设计成 diff-ready。

## 6. 方案对比

### 方案 A：继续沿用 `NSRulerView`

做法：保留当前 `CodeEditorGutterView: NSRulerView`，继续打补丁。

优点：

1. 改动最小。
2. 现有测试大多还能复用。

缺点：

1. 所有权仍然错位。
2. gutter 仍不是 editor-owned surface。
3. 后续 lane 扩展越来越别扭。
4. 背景与分隔线所有权仍然不干净。

结论：不推荐。

### 方案 B：在 `NSScrollView` 之上叠加 overlay gutter

做法：保留现有 scroll view，但把 gutter 作为 overlay/floating subview 叠在左侧。

优点：

1. 摆脱 `NSRulerView`。
2. 接入速度较快。

缺点：

1. overlay 与 content inset、hover 命中、横向滚动、clip 边界容易互相污染。
2. 视图层级复杂，后续交互处理会越来越脆。

结论：可作为短期实验，不适合正式架构。

### 方案 C：editor-owned sibling gutter column

做法：建立编辑器容器，左侧固定 gutter column，右侧是现有 `NSScrollView + NSTextView`。

优点：

1. gutter 终于成为编辑器自己的布局区域。
2. 背景、separator、hit testing、lane 都可完全控制。
3. 后续扩展最自然。
4. 能与 viewport snapshot / minimal invalidation 策略很好结合。

缺点：

1. 需要改写容器布局与测试基建。
2. 要重新梳理 gutter 与 text view 的同步接口。

结论：推荐。

### 方案 D：连文本区一起完全自绘

做法：抛弃 `NSTextView`，直接做自绘代码编辑器。

优点：

1. 理论上控制力最强。

缺点：

1. IME、selection、undo、accessibility、text services 成本过高。
2. 明显超出本期边界。

结论：排除。

## 7. 推荐架构

### 7.1 总体结构

推荐引入一个 AppKit 容器视图，例如：

1. `CodeEditorViewportContainerView`
2. `CodeEditorGutterColumnView`
3. `NSScrollView`
4. `CodeEditorPlatformTextView`

布局关系如下：

`[gutter column][editor scroll view]`

其中：

1. gutter column 固定在左侧，自身裁剪绘制。
2. text view 继续在 scroll view 内滚动。
3. gutter 与 text view 共用同一份垂直 viewport 状态，但不共享渲染所有权。
4. 当未来进入 side-by-side diff 时，架构自然扩展为：`[left gutter][left editor][diff spacer / controls][right gutter][right editor]`。
5. 当未来进入 unified diff 时，仍然保持单 editor + 单 gutter，但 gutter lane 的输入会来自 diff chunk snapshot，而不是普通 diagnostics-only snapshot。

### 7.2 推荐的数据分层

推荐新增一层独立 gutter snapshot，而不是让 gutter 直接消费散乱字段：

```swift
struct CodeEditorGutterViewportSnapshot: Equatable, Sendable {
    let documentVersion: Int
    let role: CodeEditorSurfaceRole
    let lineCount: Int
    let visibleLineRange: ClosedRange<Int>
    let currentLine: Int?
    let gutterWidth: CGFloat
    let lineMetrics: [CodeEditorVisibleLineMetric]
    let diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
    let diffByLine: [Int: CodeEditorDiffLineChange]
    let chunkAnchors: [CodeEditorDiffChunkAnchor]
    let lanes: CodeEditorGutterLaneConfiguration
}

struct CodeEditorVisibleLineMetric: Equatable, Sendable {
    let line: Int
    let rect: CGRect
    let baselineY: CGFloat
}

enum CodeEditorSurfaceRole: Equatable, Sendable {
    case standard
    case unifiedDiff(side: CodeEditorDiffSide)
    case sideBySideDiff(side: CodeEditorDiffSide)
}

enum CodeEditorDiffSide: Equatable, Sendable {
    case base
    case modified
}

enum CodeEditorDiffLineChange: Equatable, Sendable {
    case added
    case removed
    case modified
    case unchanged
}

struct CodeEditorDiffChunkAnchor: Equatable, Sendable {
    let id: String
    let lineRange: ClosedRange<Int>
    let kind: CodeEditorDiffLineChange
}
```

关键原则：

1. gutter 不直接访问整份 `document.text`。
2. gutter 不关心 token、高亮或 selection range。
3. gutter 只消费 viewport 内足够画图的摘要。
4. 普通编辑器与 diff 编辑器共享 snapshot 结构，只在 `role`、`diffByLine`、`chunkAnchors` 上表达差异。

### 7.3 几何来源

几何应继续由 `CodeEditorPlatformTextView` 基于 `NSLayoutManager` 查询并导出，原因：

1. 它已经掌握 text container inset、marked text、displayedLineIndex。
2. 它最接近真实排版结果。
3. 可以避免 gutter 重复访问 layout manager 的复杂细节。

推荐把当前零散的 `backgroundRect(forLine:)` 风格 API 升级为批量 viewport API，例如：

```swift
func visibleLineMetrics(in visibleRect: CGRect) -> [CodeEditorVisibleLineMetric]
```

批量查询优于单行回调，原因是：

1. 可以一次性 `ensureLayout`。
2. 可以一次枚举 line fragment。
3. 可以顺手建立本帧 cache。

### 7.4 渲染策略

gutter 渲染应当是 layer-backed 的单视图绘制，而不是子视图列表。

推荐：

1. `CodeEditorGutterColumnView` 负责背景、separator、命中测试。
2. `CodeEditorGutterRenderer` 负责根据 snapshot 画 line number 和 markers。
3. 用 dirty line set 驱动局部 `setNeedsDisplay(_:)`。

这一层不需要直接引入复杂 CALayer 树。首版维持一个 layer-backed `NSView` 即可；只有当 breakpoint/folding lane 需要独立动画时，再拆子 layer。

### 7.5 宽度策略

gutter 宽度不应在每次滚动时重新测量。

推荐规则：

1. 宽度仅由 `lineCount` 位数、lane 配置、marker padding 决定。
2. 文档跨位数阈值时才更新，例如 99 -> 100，999 -> 1000。
3. 字体变化或 dynamic appearance 变化时允许重新测量。

这保证滚动时 gutter width 稳定，不触发布局抖动。

### 7.6 lane 设计

不要把 gutter 固定成“只有一串右对齐行号”。推荐一开始就抽象 lane：

1. number lane
2. marker lane
3. affordance lane

哪怕第一阶段只开启 number + marker，结构也应该先在 API 上留好。

推荐把 lane 语义明确成可组合配置，而不是把 diff 做成特殊 case：

1. number lane：行号、旧/新行号、或 unified diff 的双计数占位
2. marker lane：diagnostics、breakpoint、folding、blame、diff stripe
3. affordance lane：fold chevron、chunk action、revert / accept 入口

这样单编辑器与 diff 编辑器的区别只剩 lane 配置与 snapshot 内容，而不是宿主结构分叉。

### 7.7 为 diff 视图预留的扩展边界

这次设计如果不提前考虑 diff，未来很容易出现“两套 gutter”问题：普通编辑器一套，diff 编辑器另一套。那会直接导致样式、性能策略、命中测试和 accessibility 都分叉。

推荐现在就锁定下面三个边界。

#### A. gutter 依赖 line metrics，不依赖具体 editor 类型

不管未来是普通代码编辑器、unified diff 还是 side-by-side diff，gutter 只应该依赖：

1. 当前 surface role
2. viewport line metrics
3. 行级 marker / diff 状态
4. chunk anchor

而不应该依赖：

1. `GitDiffView` 这种当前的字符串 diff 渲染器
2. `NSRulerView` 或某个特定容器层级
3. “只有一个 text view” 这种隐含假设

#### B. diff 状态必须是 chunk-aware，而不只是逐行着色

仓库里现有 change review 与 git workbench 规划，已经明确会走真正的 hunk/chunk diff 路线，而不是长期停留在整文件字符串 patch 展示。

因此 gutter 不能只预留 `git changed line stripe` 这种逐行颜色位，还要预留 chunk 级别语义：

1. chunk 起止锚点
2. chunk 类型：added / removed / modified
3. unified diff 中的 old/new line 关系
4. side-by-side diff 中左右 editor 的 chunk 对齐信息

这也是为什么 snapshot 里要有 `chunkAnchors`，而不是只有 `diffByLine`。

#### C. side-by-side diff 需要“双 surface，同一 diff session”模型

CodeMirror 的 merge view 和 VS Code 的 diff editor 有一个共同点：不是简单开两个互不相关的编辑器，而是两个 surface 共享同一套 diff session / chunk model。

对本项目的启示是，未来 side-by-side diff 最好建模为：

1. `CodeEditorDiffSessionSnapshot`
2. 左右各自一个 `CodeEditorGutterViewportSnapshot`
3. 左右各自一个 text surface
4. 中间可选 chunk controls / spacer

而不是“把两个普通编辑器拼一起，再各自临时算 diff”。

推荐未来的数据方向类似：

```swift
struct CodeEditorDiffSessionSnapshot: Equatable, Sendable {
    let id: String
    let chunks: [CodeEditorDiffChunk]
    let presentation: CodeEditorDiffPresentationMode
}

struct CodeEditorDiffChunk: Equatable, Sendable {
    let id: String
    let kind: CodeEditorDiffLineChange
    let baseLineRange: ClosedRange<Int>?
    let modifiedLineRange: ClosedRange<Int>?
}

enum CodeEditorDiffPresentationMode: Equatable, Sendable {
    case unified
    case sideBySide
}
```

本期不实现它，但 gutter 的 API 设计要能自然接进去。

## 8. 性能策略

### 8.1 viewport-only

只绘制可见区与近场缓存区，不为全文件建立几何或 display list。

### 8.2 批量几何查询

对单帧滚动更新，优先一次批量拿到 `visibleLineMetrics`，避免 N 次 `backgroundRect(forLine:)`。

### 8.3 minimal invalidation

只重绘：

1. 旧当前行
2. 新当前行
3. 诊断发生变化的行
4. 新旧 visible range 差集
5. 位数变化引起的整列宽度变化

### 8.4 样式缓存

缓存：

1. 数字绘制 attributes
2. severity color
3. digits width measurement
4. paragraph/alignment 对象

### 8.5 大文件降级

当文件极大、实时高亮已降级时，gutter 也应允许启用简化模式：

1. 仅绘制当前 viewport，不保留近场缓冲
2. 诊断 marker 只画 dot，不画复杂 stripe
3. hover affordance 暂不启用

### 8.6 主线程边界

基于 Apple 文档，`NSLayoutManager` 的显示布局查询仍应视为主线程资源。优化重点应该放在：

1. 降低查询次数
2. 降低对象分配
3. 降低无效重绘

而不是尝试把布局几何计算搬到后台线程。

## 9. 交互与可访问性设计

### 9.1 当前阶段交互

第一阶段只要求：

1. 行号显示
2. 当前行高亮
3. diagnostics marker
4. gutter 点击不抢走 text view 的编辑焦点

### 9.2 后续交互扩展位

结构上要能支持：

1. 点击 marker lane 跳转下一条诊断
2. 点击 breakpoint lane 切换断点
3. 点击 fold lane 展开/折叠

### 9.3 accessibility

因为文本区仍然由 `NSTextView` 提供主要 accessibility，所以 gutter 只需要补最小语义：

1. 作为辅助元素暴露当前可见行区间
2. 对 marker 提供可读 label，例如 `Line 42, warning, 2 diagnostics`

不建议第一阶段把每一行都暴露成独立 accessibility element，这会带来不必要的开销。

## 10. 测试策略

### 10.1 需要保留的现有行为

1. 选区变化仍能更新当前行与状态栏。
2. 滚动仍能正确发布 `visibleLineRange`。
3. marked text / IME 期间的 displayed line 几何仍正确。
4. diagnostics 更新不能重置 cursor 或文本。

### 10.2 新增测试重点

1. gutter 不再依赖 `verticalRulerView`。
2. gutter column 与 scroll view 的垂直滚动保持对齐。
3. 诊断变化只失效受影响行。
4. 当前行切换只失效 old/new 两行。
5. `lineCount` 跨位数阈值时 gutter width 才变化。
6. 大文档滚动不会触发整列全量重绘。

### 10.3 验证方法

建议增加两类测试：

1. 集成测试：验证容器装配、布局同步、snapshot 输入与 hit testing。
2. renderer 测试：验证 diff / invalidate 策略和 width 计算。

## 11. Feature 拆分

下面的拆分故意按“小 Feature、可单独验收、可单独回退”的粒度设计。

### Feature 8：Gutter 宿主替换

目标：把 gutter 从 `NSRulerView` 迁出，建立 editor-owned sibling column。

范围：

1. 新增编辑器容器视图。
2. `CodeEditorTextView` 不再设置 `verticalRulerView`。
3. 保留现有文本区功能不变。

验收标准：

1. 编辑器仍能显示行号。
2. `NSScrollView.hasVerticalRuler == false`。
3. gutter 背景与 separator 完全由自定义视图控制。

### Feature 9：Viewport Line Metrics 批量导出

目标：从单行几何查询升级为批量 viewport metrics 查询。

范围：

1. 在 `CodeEditorPlatformTextView` 上新增批量 API。
2. 把 gutter 的输入从 `visibleLineRange + backgroundRect(forLine:)` 改为 `lineMetrics snapshot`。

验收标准：

1. gutter 不再逐行反查几何。
2. marked text、新增换行、滚动后 metrics 正确。

### Feature 10：Gutter Renderer 与最小失效

目标：引入独立 renderer 和 diff 驱动的 invalidate。

范围：

1. 新增 gutter snapshot 与 renderer。
2. 缓存数字样式与宽度。
3. 只重绘受影响行。

验收标准：

1. current line 切换只重绘两行。
2. diagnostics 更新只重绘变化行。
3. 普通滚动不触发整列无差别重绘。

### Feature 11：Lane 化与扩展协议

目标：把 gutter 从“行号绘制函数”升级为可扩展 lane 容器。

范围：

1. 抽象 number lane / marker lane。
2. 预留 fold / breakpoint lane 接口。

验收标准：

1. 调整 lane 配置不会影响文本区。
2. marker lane 可独立开关。

### Feature 12：交互与辅助功能补强

目标：补最小可交互能力与 accessibility 语义。

范围：

1. gutter 点击命中区。
2. marker hover / click 的协议接缝。
3. 最小 accessibility label。

验收标准：

1. gutter 点击不破坏 text view 的 first responder 逻辑。
2. VoiceOver 至少能读出可见 marker 的核心信息。

### Feature 13：性能护栏与大文件策略

目标：确保新 gutter 在大文件下仍稳定。

范围：

1. 大文件简化模式。
2. redraw telemetry 或调试计数。
3. 回归测试与基准测试。

验收标准：

1. 大文件滚动时无明显整列闪烁。
2. 性能计数能证明 invalidate 范围收敛。

### Feature 14：Diff 视图扩展接缝

目标：让 gutter core model 直接兼容 unified diff 与 side-by-side diff。

范围：

1. 引入 `surface role` 与 diff-aware snapshot 字段。
2. 定义 chunk anchor 与 line change model。
3. 让 lane 配置可以按 `standard / unified / side-by-side` 切换。

验收标准：

1. 普通编辑器 gutter 与 diff gutter 共享同一 renderer 主体。
2. 不需要重写宿主架构就能承载双栏 diff。
3. 现有代码编辑器路径不因为 diff 预留而变复杂失控。

### Feature 15：TextKit 2 兼容接缝

目标：为未来迁移 `NSTextLayoutManager` 预留接口，而不在本期启用。

范围：

1. 把 gutter 依赖限制在 `line metrics provider` 协议上。
2. 让 TextKit 1 与未来 TextKit 2 都能提供同型 snapshot。

验收标准：

1. gutter 不直接依赖 `NSRulerView` 或特定 TextKit 1 细节。
2. 可以单独替换 metrics provider 实现。

## 12. 推荐落地顺序

建议实施顺序：

1. Feature 8
2. Feature 9
3. Feature 10
4. Feature 11
5. Feature 14
6. Feature 13
7. Feature 12
8. Feature 15

原因是：

1. 先完成宿主替换，解决架构根问题。
2. 再把几何与重绘性能做扎实。
3. lane 抽象稳定后，尽早把 diff-ready model 固化，避免后面再返工宿主与 snapshot。
4. 性能护栏仍然要早于复杂交互。
5. TextKit 2 接缝放最后即可。

## 13. 文件级影响预估

大概率会涉及：

1. 新增 `agentGui/Views/CodeEditor/CodeEditorViewportContainerView.swift`
2. 新增 `agentGui/Views/CodeEditor/CodeEditorGutterColumnView.swift`
3. 新增 `agentGui/Views/CodeEditor/CodeEditorGutterRenderer.swift`
4. 新增 `agentGui/Views/CodeEditor/CodeEditorGutterViewportSnapshot.swift`
5. 修改 `agentGui/Views/CodeEditor/CodeEditorTextView.swift`
6. 可能删除或重写 `agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
7. 修改 `agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
8. 修改 `agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
9. 后续 diff editor 落地时，大概率还会影响 `agentGui/Views/GitDiffView.swift` 或其替代者，但这不属于本期实现范围。

## 14. 最终建议

这次 gutter 改造不应该被理解成一次视觉微调，而应被理解成一次 editor surface ownership 修正。

真正值得替换的不是“行号怎么画”，而是“gutter 到底属于谁”。

推荐决策如下：

1. 立即停止继续沿 `NSRulerView` 增量打补丁。
2. 采用 editor-owned sibling gutter column 方案。
3. 保留 `NSTextView + NSLayoutManager` 作为本期文本内核。
4. 把 gutter snapshot 与 lane 模型直接设计成 diff-ready，避免未来再造一套 diff gutter。
5. 按 Feature 8 到 Feature 15 的节奏分批落地。

如果只允许一句话总结这份方案，那就是：

“把 gutter 从 ruler 变成 editor 本身。”