# High-Performance Code Editor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 agentGui 中以 FileEditorView 为第一优先级，落地一条高性能原生代码编辑器主路径：使用 Highlightr 提供语法高亮，使用 LSP 提供语义能力与高级操作，并通过增量索引、脏区调度、视口优先渲染和受控降级保证大文件与持续编辑场景下的响应速度。

**Architecture:** 第一阶段不重写整套文本系统，也不把 BlockDocumentEditor 硬扩成通用源码编辑器；而是在现有 macOS AppKit/SwiftUI 架构上新增一条专用 CodeEditorView 路径。文本编辑继续依托原生 NSTextView/TextKit，以获得稳定的输入法、选区、撤销和可访问性；性能优化集中在“文本缓冲的增量索引”“高亮管线的最小失效”“可见区优先更新”“LSP 文档同步去抖”这四个层面。中长期保留 EditorBuffer 抽象，为 piece tree / rope 后端预留替换位，但不在首轮把项目拖进高风险的自研文本内核。

**Tech Stack:** Swift 6、SwiftUI、AppKit、TextKit、Highlightr、JavaScriptCore、现有 LSPClient/LSPServerManager/LSPWorkspaceCoordinator、Foundation、Swift Testing。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. 范围结论

这份文档默认采用“文件编辑器优先”路线。

原因很直接：

- 当前仓库里真正承载源码文件编辑的是 [agentGui/Views/FileEditorView.swift](../agentGui/Views/FileEditorView.swift)，但文本文件仍走 [agentGui/Views/Editor/BlockDocumentEditor.swift](../agentGui/Views/Editor/BlockDocumentEditor.swift) 这一条面向富文本/块结构的路径。
- 现有块编辑器已经有自己的交互复杂度：块级选择、slash menu、table editor、marquee、markdown round-trip，这些都不是高性能源码编辑器的主问题。
- Highlightr 与 LSP 已经接入，但目前 Highlightr 主要用于只读代码块和块级 code/source 样式，LSP 也更多停留在 workspace runtime 与只读语义能力层，还没有形成“专用源码编辑器”的事件管线。

因此，推荐先做一条新的专用代码编辑器主路径，再决定块编辑器是否需要复用其中的部分能力。

## 1. 当前基线

### 1.1 已有能力

- [agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift](../agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift) 已经完成 Highlightr 的项目内封装，具备主题切换、语言归一化和结果缓存。
- [agentGui/Views/FileEditorView.swift](../agentGui/Views/FileEditorView.swift) 已经在文件切换与文本变化时触发 workspace LSP bootstrap 和文档同步。
- [agentGui/Services/LSP/LSPClient.swift](../agentGui/Services/LSP/LSPClient.swift)、[agentGui/Services/LSP/LSPServerManager.swift](../agentGui/Services/LSP/LSPServerManager.swift)、[agentGui/Services/LSP/LSPWorkspaceCoordinator.swift](../agentGui/Services/LSP/LSPWorkspaceCoordinator.swift) 已经提供会话、文档版本、诊断和基础语义查询骨架。
- [agentGui/Views/Editor/BlockTextEditor.swift](../agentGui/Views/Editor/BlockTextEditor.swift) 已经积累了一部分原生 NSTextView 生命周期与高度更新经验，可复用其中的焦点、选区、输入回调模式。

### 1.2 当前缺口

- 没有“专用源码编辑器”视图与状态模型，文本文件仍被映射为 block document。
- Highlightr 当前是整段字符串 -> NSAttributedString 的模式，不适合每个按键都全量重算。
- 编辑器没有独立的行号、gutter、诊断装饰、当前行高亮、可见区缓存等源码编辑体验层。
- LSP 还没有形成 hover / definition / references / diagnostics 与光标、选区、gutter、右键菜单之间的产品闭环。
- 当前文档同步是“文本变化就同步整个文本”的直接路径，缺少去抖、版本闸门、可见区优先和大文件降级。

## 2. 算法调研结论

### 2.1 文本缓冲结构对比

高性能编辑器最常见的文本结构主要有 4 类：

1. Gap Buffer
2. Rope
3. Piece Table / Piece Tree
4. Flat String + 增量索引

调研结论如下：

- Gap Buffer 对单光标局部输入性能很好，但对大文件、随机编辑和多视图行列映射不够理想。
- Rope 适合超大文本、并行增量计算和复杂 metrics，但如果当前前端仍深度依赖 NSTextView / NSString 生态，会有较高适配成本。
- Piece Table / Piece Tree 是 VS Code/Monaco 这类大编辑器的实战路线之一。VS Code 的文本缓冲重写说明里明确指出，line array 在超多行文件上会带来高内存和慢打开问题，piece table 通过“原始缓冲 + 追加缓冲 + 树索引”的方式显著降低内存；为了把按 offset / line 的搜索压到对数复杂度，又引入带 subtree metadata 的平衡树，也就是常说的 piece tree。
- 但 piece tree 的收益主要发生在“编辑器自己控制文本存储和行模型”时。对当前项目，如果我们仍然依赖 TextKit 作为输入与布局内核，首轮就把底层改成 piece tree，会同时放大 IME、选区、撤销、富文本属性、LSP 文档镜像等一整串复杂度。

**推荐结论：**

- Feature 1-6 不直接上 piece tree，而是先采用“原生 NSTextStorage/String 作为真实文本缓冲 + 独立增量行索引 + 编辑变更流水线”。
- 同时定义 `EditorBuffer` 抽象，使 piece tree 成为后续可替换后端，而不是现在就侵入全部 UI。
- 当文件规模进入几十 MB、百万行或需要真正的超大文件模式时，再引入 piece tree / rope 后端才值得。

### 2.2 增量语法高亮算法

这部分最关键。

xi-editor 对高亮的分析可以归纳为一个非常实用的模型：

```text
syntax(previous_state, line) -> (next_state, spans)
```

也就是“每一行的高亮结果不仅取决于当前行，还取决于上一行结束时的语法状态”。这意味着：

- 最朴素方案是从头到尾全量跑，复杂度高，交互延迟差。
- 真正高性能的做法不是缓存每一行的 span 本身，而是缓存部分“行起始状态”，编辑后只从最近的有效 cache entry 往后重新传播，直到状态重新收敛。
- xi-editor 进一步提出 frontier 概念，用来追踪“可能失效但尚未重算完成”的状态边界，这样可以把一次编辑的影响控制在最小必要范围，而不是直接把后续全文件都标成脏。

**但当前项目有一个现实约束：Highlightr 并不暴露这种按行状态机接口。**

Highlightr 更像“整段代码输入 -> 一次性返回 attributed string”的黑盒高亮器，因此不能直接实现 tree-sitter / TextMate 那种严格意义上的增量词法状态传播。结论是：

- 不要尝试在首轮把 Highlightr 伪装成逐行增量解析器。
- 应把增量优化放在调度层，而不是解析器内部。
- 具体做法是：维护脏区、版本号、可见区优先队列和后台高亮任务；输入时先保持纯文本编辑响应，随后对可见区或有限窗口异步重算高亮，再安全回写属性。

这不是理论最优，但在 Highlightr 约束下是最务实路线。

### 2.3 最小失效与视口优先

xi-editor 在 minimal invalidation 里强调了两点：

- 编辑器不应该把“整个文档的渲染结果”当作一个整体重算对象。
- 真正需要保证始终正确的是 viewport 内的内容；viewport 外的结果只要可按需补算即可。

这对当前项目的启发非常直接：

- 编辑器 UI 应显式建模 viewport 与 visible line range。
- 高亮、诊断装饰、当前行背景、查找结果等图层都要按“可见区优先，近场缓存，远场丢弃”的策略组织。
- 对可见区外的更新，允许延迟、丢弃或合并，而不是每次都做同步全量刷新。

### 2.4 LSP 同步策略

高性能代码编辑器和 LSP 的关系，核心不是“会不会发 didChange”，而是“何时发、发多少、如何不拖慢输入”。

当前项目已有版本化文档同步能力，但还缺少一层更贴近编辑器的同步调度。推荐算法与策略：

- 所有编辑先落本地 buffer，不等待 LSP。
- 使用短窗口去抖把连续输入合并成一次 `didChange` 批次。
- 以文档版本为闸门，只接受最新版本对应的异步结果，过期 hover / diagnostics / references 全部丢弃。
- 光标驱动类请求如 hover 应有更严格的去抖与取消策略，避免鼠标移动时堆积请求。
- 诊断刷新与文本同步解耦；先保障文本版本一致，再异步更新诊断层。

## 3. 设计原则

### 3.1 明确不做的事

- 第一阶段不把 BlockDocumentEditor 替换为源码编辑器。
- 第一阶段不引入自研 piece tree 文本内核。
- 第一阶段不追求多光标、代码补全、inline diff、folding、minimap 一次到位。
- 第一阶段不开放 rename / code action 这类会回写文件的 LSP 写操作。

### 3.2 必须做到的事

- 代码输入的主线程延迟优先，语法高亮与 LSP 必须服从输入体验。
- 任何异步计算都必须版本化、可取消、可丢弃。
- 可见区优先于全量正确性；全量正确性通过后台收敛获得，而不是阻塞输入。
- 大文件必须有明确降级路径，而不是继续启全部高级能力硬扛。
- 所有第三方能力都要隔离在项目自己的抽象层后面，尤其是 Highlightr。

## 4. 目标架构

### 4.1 分层

推荐新增以下分层：

1. `CodeEditorDocument`
2. `CodeEditorBuffer`
3. `CodeEditorLineIndex`
4. `CodeEditorHighlightPipeline`
5. `CodeEditorLSPCoordinator`
6. `CodeEditorViewModel`
7. `CodeEditorView`

职责如下：

#### `CodeEditorDocument`

- 保存文件 URL、语言、文本版本、保存状态、只读状态、文件大小分级。
- 提供编辑变更事件 `EditorChangeSet`。
- 对上游暴露 offset/line/column 转换接口，但不自己做 UI。

#### `CodeEditorBuffer`

- 首轮实现用 `String` / `NSTextStorage` 即可。
- 对外暴露统一协议：全文读取、范围替换、行读取、offset <-> line 映射请求。
- 后续可新增 piece tree 实现，而不动上层。

#### `CodeEditorLineIndex`

- 维护换行位置索引和行数统计。
- 接收 edit delta 后，仅重扫受影响片段并修正后续偏移。
- 为 gutter、诊断、LSP 位置映射和 visible range 计算提供服务。

#### `CodeEditorHighlightPipeline`

- 输入：文本版本、语言、可见行范围、脏区。
- 输出：可回写到 NSTextStorage 的 token attributes 或 attributed fragments。
- 使用 Highlightr，但调度策略由项目自己控制。
- 按可见区优先，支持取消旧任务、跳过过期结果。

#### `CodeEditorLSPCoordinator`

- 管理 didOpen / didChange / didClose。
- 为 hover / definition / references / diagnostics 建立光标与版本绑定。
- 暴露“当前光标符号语义状态”给 UI，如 hover popover、跳转菜单、gutter diagnostics。

#### `CodeEditorViewModel`

- 统一编辑状态、搜索状态、当前行、选区、visible range、诊断摘要。
- 组织 UI 级别去抖与任务取消，但不直接操作底层高亮库。

#### `CodeEditorView`

- SwiftUI 包装原生 AppKit 视图。
- 提供 gutter、scroll 同步、hover hit-testing、当前行高亮、状态栏。

### 4.2 建议新增文件

### New files

- `agentGui/Views/CodeEditor/CodeEditorView.swift`
- `agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- `agentGui/Views/CodeEditor/CodeEditorGutterView.swift`
- `agentGui/ViewModels/CodeEditorViewModel.swift`
- `agentGui/Models/CodeEditorDocument.swift`
- `agentGui/Models/EditorChangeSet.swift`
- `agentGui/Services/Editor/CodeEditorLineIndex.swift`
- `agentGui/Services/Editor/CodeEditorHighlightPipeline.swift`
- `agentGui/Services/Editor/CodeEditorHighlightScheduler.swift`
- `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
- `agentGuiTests/CodeEditorLineIndexTests.swift`
- `agentGuiTests/CodeEditorHighlightPipelineTests.swift`
- `agentGuiTests/CodeEditorLSPCoordinatorTests.swift`
- `agentGuiTests/CodeEditorViewModelTests.swift`

### Modified files

- [agentGui/Views/FileEditorView.swift](../agentGui/Views/FileEditorView.swift)
- [agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift](../agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift)
- [agentGui/Services/LSP/LSPClient.swift](../agentGui/Services/LSP/LSPClient.swift)
- [agentGui/Services/LSP/LSPServerManager.swift](../agentGui/Services/LSP/LSPServerManager.swift)
- [agentGui/Services/LSP/LSPWorkspaceCoordinator.swift](../agentGui/Services/LSP/LSPWorkspaceCoordinator.swift)
- [agentGui/Models/AppSettings.swift](../agentGui/Models/AppSettings.swift)

## 5. 核心算法与数据流

### 5.1 文本变更流水线

推荐管线：

```text
用户输入
-> NSTextView/TextStorage 本地更新
-> 生成 EditorChangeSet(version, replacedRange, insertedText)
-> 增量更新 CodeEditorLineIndex
-> 标记 HighlightDirtyRegion
-> 本地 UI 立即显示纯文本结果
-> HighlightScheduler 后台处理可见区高亮
-> LSPCoordinator 去抖同步 didChange
-> diagnostics / hover / symbol 信息异步回流
```

关键点：

- 输入路径永远不等待 Highlightr 或 LSP。
- UI 的第一正确性来源是纯文本本身，不是着色结果。
- 高亮和 LSP 都只能“追赶版本”，不能阻塞版本前进。

### 5.2 行索引算法

首轮建议实现一个 chunk-aware line index，而不是简单全量 `split`。

推荐结构：

- `textLength`
- `lineCount`
- `lineStartOffsets: [Int]` 作为基线实现
- 后续若发现大文件更新代价偏高，再升级为 chunk/block 形式

更新逻辑：

1. 根据 `replacedRange` 找到受影响的起止行。
2. 只对“编辑前后交集窗口”重新扫描换行。
3. 计算新增/减少的换行数量。
4. 批量平移后续 offset。

这个实现不是 piece tree 级别的极限性能，但已经足够把“每次都全量 split 全文”这个低效路径淘汰掉。

### 5.3 Highlightr 调度算法

Highlightr 在此处不作为“每键同步词法器”，而是作为“异步批处理高亮引擎”。

推荐策略：

- 维护 `dirtyVersionRange` 和 `visibleLineRange`。
- 每次编辑后立即取消上一个未完成高亮任务。
- 若用户持续输入，只在短暂停顿后发起高亮。
- 优先计算当前 viewport 的整屏或扩展窗口，例如可见区上下各 100-300 行。
- 对超大文件设置阈值：超过阈值后关闭实时全量高亮，只保留当前窗口高亮或完全退回纯文本模式。

可把高亮任务分成 3 个优先级：

1. `viewportImmediate`
2. `nearbyPrefetch`
3. `backgroundCatchUp`

### 5.4 视口与最小重绘

推荐维护 `visibleLineRange` 与 `retainedLineWindow`：

- `visibleLineRange`：当前屏幕内的行。
- `retainedLineWindow`：在 visible range 前后各保留一小段缓存，降低小幅滚动时的抖动。

装饰层更新规则：

- gutter 只画 retained window。
- 当前行高亮只更新 old/new current line。
- diagnostics underline 只在受影响行或可见区行重建。
- 高亮结果只回写变化过的行范围，而不是整份 NSTextStorage。

### 5.5 LSP 事件模型

读操作优先级建议：

1. diagnostics
2. hover
3. definition
4. references
5. document symbols

调度原则：

- `didOpen`：文件进入编辑器且有可用语言服务器时触发一次。
- `didChange`：本地编辑后经去抖批量触发。
- `didClose`：关闭文件或切换到非文本查看器时触发。
- `hover`：停顿触发，可取消。
- `definition/references`：手势或快捷键触发，不做自动轮询。
- `diagnostics`：以服务端通知为主，UI 只订阅投影结果。

## 6. 降级与性能保护

必须从设计一开始就定义大文件与低性能模式。

### 6.1 文件分级

建议至少分 3 档：

- `interactiveRich`: 小中型文件，启用实时高亮、gutter、diagnostics、hover。
- `interactiveLimited`: 中大型文件，启用行号和基础编辑，Highlightr 改为 viewport-only，hover 去抖更长。
- `plainLargeFile`: 超大文件，只保留纯文本编辑、查找、基础保存，关闭 Highlightr 与大部分 LSP 实时能力。

触发条件可先用简单阈值：文件大小、行数、首次高亮耗时、最近 20 次编辑平均耗时。

### 6.2 性能预算

建议把以下指标做成可测试或可日志采样：

- 单次本地输入主线程处理目标 < 8ms
- 视口高亮回填目标 < 50ms
- 连续输入期间不允许累计未取消的高亮任务
- LSP 文档同步队列只保留最新版本待发送任务

## 7. Feature 拆分

以下 Feature 都是可以逐步交付的小 Feature，而不是一次性大爆炸。

### Feature 1: 建立专用 CodeEditorView 外壳

**目标：** 把文本文件从 BlockDocumentEditor 路径中分离出来，形成独立代码编辑主路径。

**范围：**

- 新增 `CodeEditorView` 与 `CodeEditorTextView`
- `FileEditorView` 对文本文件切到新路径
- 先只保证纯文本编辑、保存、焦点、选区、撤销、外部刷新

**关键算法：** 暂无复杂算法，先建立统一编辑事件模型 `EditorChangeSet`

**验收：** 文本文件能稳定编辑和保存，功能不退化

### Feature 2: 增量行索引与位置映射

**目标：** 淘汰每次全量分割全文的低效路径，为 gutter、diagnostics、visible range 和 LSP 坐标转换打基础。

**范围：**

- 新增 `CodeEditorLineIndex`
- 接入 offset <-> line/column 映射
- 把当前编辑器中的行列换算统一走索引服务

**关键算法：** 局部重扫 + 后续 offset 平移

**验收：** 普通编辑只重算受影响行，映射结果稳定

### Feature 3: Highlightr 异步高亮管线

**目标：** 在不阻塞输入的前提下接入实时代码高亮。

**范围：**

- 新增 `CodeEditorHighlightPipeline` 和 `CodeEditorHighlightScheduler`
- 建立脏区、版本和取消机制
- 只对 viewport + 缓冲窗口高亮

**关键算法：** dirty region 调度、版本闸门、可见区优先

**验收：** 连续输入时不卡顿，停顿后可见区正确着色

### Feature 4: 行号、当前行和 diagnostics gutter

**目标：** 提供源码编辑器基础观感与可读性层。

**范围：**

- 行号 gutter
- 当前行高亮
- diagnostics 图标与行级着色
- 基础状态栏：行列、语言、缩进、LSP 状态

**关键算法：** visible range 驱动的轻量绘制与局部失效

**验收：** 滚动和编辑时 gutter 不出现整视图重绘抖动

### Feature 5: LSP 文档同步协调器

**目标：** 让编辑器和 LSP 形成受控同步，不再直接在文本绑定里裸发同步。

**范围：**

- 新增 `CodeEditorLSPCoordinator`
- 把 didOpen/didChange/didClose 从 FileEditorView 抽出来
- 增加去抖、版本过滤和过期结果丢弃

**关键算法：** debounce + latest-version-wins

**验收：** 持续输入时 LSP 不拖慢本地编辑，诊断可持续回流

### Feature 6: Hover / Definition / References 只读语义能力

**目标：** 把 LSP 的只读语义操作直接挂到代码编辑器交互里。

**范围：**

- Option-click 或菜单触发 definition
- 右键或快捷键触发 references
- 光标停顿触发 hover
- document symbols 接到文件内导航

**关键算法：** 光标位置版本绑定、请求取消、异步结果去抖

**验收：** 语义能力可用且不会引入明显输入卡顿

### Feature 7: 查找、选区装饰与最小失效渲染

**目标：** 补齐编辑器的常用局部装饰能力，并验证 minimal invalidation 管线是否成立。

**范围：**

- 当前文档查找高亮
- 当前选区匹配高亮
- diagnostics underline 局部更新
- 局部属性回写，不再整份 attributed string 覆盖

**关键算法：** line-scoped invalidation、局部属性合并

**验收：** 选中词与查找结果更新只影响局部范围

### Feature 8: 大文件模式与性能采样

**目标：** 让编辑器在大文件场景下有明确的保护策略。

**范围：**

- 文件分级策略
- Highlightr / LSP 动态降级
- 采样日志与性能基线测试

**关键算法：** 自适应能力开关，而不是硬编码“一直全开”

**验收：** 大文件不会因高亮或 LSP 导致不可交互

### Feature 9: Buffer 抽象与 piece tree 预研接口

**目标：** 为未来超大文件模式和真正的文本内核升级预留边界。

**范围：**

- 提炼 `EditorBuffer` 协议
- 让 line index / LSP / visible range 依赖 buffer 抽象而不是具体 String
- 先做基于 String 的默认实现

**关键算法：** 无新增用户可见能力，目标是隔离后端

**验收：** 上层不直接依赖具体文本存储实现

## 8. 每个 Feature 的测试门禁

### Feature 1

- `CodeEditorViewModelTests`
- `FileEditorView` focused tests
- 手工验证：输入法、撤销、保存、外部文件冲突

### Feature 2

- `CodeEditorLineIndexTests`
- 大量随机替换与 line/column 映射回归测试

### Feature 3

- `CodeEditorHighlightPipelineTests`
- 验证旧任务取消、过期版本不回写、viewport 优先策略

### Feature 4

- gutter 可见区渲染测试
- diagnostics 显示与当前行联动测试

### Feature 5-6

- `CodeEditorLSPCoordinatorTests`
- 复用现有 LSP focused tests，新增编辑器集成测试

### Feature 7-8

- 选区/查找/诊断装饰的局部失效测试
- 性能采样测试与大文件降级测试

## 9. 推荐迭代顺序

建议严格按以下顺序推进：

1. Feature 1
2. Feature 2
3. Feature 3
4. Feature 5
5. Feature 4
6. Feature 6
7. Feature 7
8. Feature 8
9. Feature 9

原因：

- 没有独立编辑器外壳之前，后续任何优化都没有稳定落点。
- 没有行索引，就无法把高亮、gutter、diagnostics 和 LSP 坐标统一起来。
- Highlightr 的性能问题必须先通过调度层化解，再谈 UI 装饰与高级语义操作。
- LSP 同步协调器应早于 hover/definition 等 UI 功能，否则上层会继续直接耦合到底层 manager。

## 10. 风险与决策点

### 风险 1: Highlightr 不是增量高亮器

这是最大现实约束。

**应对：**

- 第一阶段只做异步 viewport-only 高亮
- 建立可插拔高亮协议
- 若性能仍不达标，后续增补 tree-sitter 或 TextMate 状态缓存型高亮器

### 风险 2: TextKit 与局部属性回写可能互相干扰

**应对：**

- 严格区分文本内容和展示属性
- 任何属性回写都不允许破坏 `typingAttributes`、选区和 first responder

### 风险 3: LSP 回流结果与本地版本错位

**应对：**

- 所有异步结果都带本地版本戳
- 过期结果直接丢弃，不做“尽量合并”

### 风险 4: 大文件场景下功能过多

**应对：**

- 文件分级和动态降级必须是架构的一部分，而不是最后补丁

## 11. 完成定义

达到以下条件时，可以认为这条高性能代码编辑器主路径初步成立：

- 文本文件不再依赖 BlockDocumentEditor 承载源码编辑。
- 编辑输入主路径不等待 Highlightr 或 LSP。
- Highlightr 在可见区内可用，并具备版本化取消与后台追赶机制。
- LSP 的 didOpen/didChange/didClose、diagnostics、hover、definition、references 能与代码编辑器形成闭环。
- gutter、当前行、诊断装饰、查找装饰都按局部失效更新。
- 对大文件存在明确降级模式，编辑器依然可交互。

## 12. 最终建议

如果只给一个最务实的落地建议，那就是：

**不要先重写文本内核，先把“专用代码编辑器壳 + 增量行索引 + Highlightr 异步可见区高亮 + LSP 去抖同步协调器”做出来。**

这是当前仓库在风险、收益和实现复杂度之间最平衡的路线。

Plan complete and saved to `docs/plans/2026-03-29-high-performance-code-editor-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按 Feature 顺序逐个实现、逐个验证

**2. Parallel Session (separate)** - 新开会话按 executing-plans skill 并行执行

**Which approach?**