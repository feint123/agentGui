日期：2026-03-17

# BlockDocumentEditor Undo/Redo 技术设计

## 1. 背景与问题

当前 `BlockDocumentEditor` 已经具备较完整的块级编辑能力，包括：

- 文本块输入与分块渲染
- 块类型转换
- 分裂 / 合并 / 插入 / 删除块
- 列表缩进调整
- slash 命令与行内格式工具
- markdown 文档与块模型之间的双向同步

但撤销 / 重做能力目前仍处于“不完整且不一致”的状态：

- `BlockTextEditor` 底层 `NSTextView` 开启了 `allowsUndo`，但只覆盖本地文本输入，不覆盖块级结构操作。
- `BlockDocumentEditor` 自身没有统一的历史栈，结构变更、格式变更、slash 命令、资源插入等都直接改写 `document.blocks`。
- 宿主层 `FileEditorSessionController` 只知道 `textContent` 与 `persistedText` 的差异，不知道编辑器内部的事务边界与历史状态。
- 一旦出现外部文件变化、切换文件、重新加载、解析回写，当前没有明确策略决定历史如何保留、失效或重建。

因此现在的编辑体验会出现明显断层：

- 输入文本时可以局部撤销，但执行块级操作后撤销语义断裂。
- 文本编辑与结构编辑可能形成两套并行历史源。
- 焦点、光标、选区、当前块状态在撤销后无法稳定恢复。

本设计目标是为 `BlockDocumentEditor` 定义一套统一、模块化、可扩展的 Undo/Redo 架构，使编辑器把“文本输入”和“块结构编辑”都收敛到同一条事务链路上。

## 2. 目标与非目标

### 2.1 目标

本方案必须满足以下目标：

- 提供统一的编辑器级撤销 / 重做，而不是局部依赖 `NSTextView` 自带 undo。
- 同时覆盖文本输入、块级结构编辑、行内格式、slash 命令、资源插入、表格预设等所有编辑路径。
- 支持合理的事务合并（coalescing），避免用户输入几个字符就生成一长串低质量历史记录。
- 支持恢复编辑上下文，包括当前块、焦点位置、光标 / 选区等关键 UI 状态。
- 与 `FileEditorView` / `FileEditorSessionController` 的保存、脏状态、外部冲突机制兼容。
- 方案应模块化，未来可以扩展到：历史面板、命名快照、协作编辑、持久化编辑历史、跨会话恢复。

### 2.2 非目标

当前阶段明确不做以下内容：

- 不做跨文件全局撤销。
- 不做磁盘级版本历史替代品。
- 不做多人实时协作 OT/CRDT。
- 不做首次实现即 diff-based 的复杂增量存储引擎。
- 不要求把历史持久化到 SwiftData；第一阶段允许历史仅存在编辑会话内存中。

## 3. 现状约束

### 3.1 当前数据流

`BlockDocumentEditor` 当前的核心链路如下：

1. 宿主 `FileEditorView` 以 `Binding<String>` 方式把 `sessionController.document.textContent` 传给 `BlockDocumentEditor`。
2. `BlockDocumentEditor` 在内部维护 `@State private var document = BlockDocument.empty` 作为编辑器真正的结构化工作模型。
3. `BlockTextEditor` / `BlockTableEditor` 等子编辑器对块内容进行修改。
4. `BlockDocumentEditor.syncText(manualCommit:)` 会把 `document` 序列化回 markdown 文本，再写回宿主 binding。
5. 宿主 `FileEditorSessionController` 依据 `textContent != persistedText` 判断是否脏。

这意味着：

- 编辑器内部的“权威工作状态”是 `BlockDocument`，而不是外部 markdown 字符串。
- 撤销 / 重做最自然的实现点应位于 `BlockDocumentEditor` 的结构化状态层，而不是宿主层纯文本层。

### 3.2 当前编辑操作分布

当前主要变更入口集中在 `BlockDocumentEditor`：

- `convertBlock`
- `splitBlock`
- `mergeBlockBackward`
- `insertBlock`
- `deleteBlock`
- `addResources`
- `adjustIndentation`
- `mutateBlock`
- `clearFormatting`
- `createTablePreset`

文本输入则经由 `BlockTextEditor.Coordinator.textDidChange` 直接回写到 `parent.text` 与 `BlockDocumentEditor` 的块绑定。

这说明系统已经有一个较清晰的“结构变更中枢”，但缺少一个统一的事务包装层。

### 3.3 当前最关键的问题

当前最需要避免的是“双重历史源”：

- 一条来自 `NSTextView` 自带 undo manager
- 一条来自未来的块级撤销栈

如果这两者同时存在，最终一定会导致：

- 撤销顺序错乱
- 文本状态与块结构状态不一致
- 宿主 `textContent` 与编辑器 `document` 被不同来源回滚

因此本设计明确要求：**撤销 / 重做必须只有一个权威来源。**

## 4. 设计原则

### 4.1 单一历史源

编辑器历史只能由 `BlockDocumentEditor` 自己控制。`NSTextView` 不再持有独立的最终 undo 真相。

### 4.2 事务优先，而不是 API 拼凑

所有编辑操作都必须先归一为“编辑事务”，再进入历史栈，而不是由每个按钮或快捷键各自决定是否可撤销。

### 4.3 结构状态与界面状态一起回滚

纯文档内容回滚是不够的。一次可用的撤销还必须尽量恢复：

- 当前活动块
- 焦点位置
- 光标 / 选区
- 相关临时 UI 状态的关闭策略

### 4.4 先用快照方案保证一致性，再为未来 diff 化预留接口

第一阶段不追求最小内存占用，而追求正确性、可调试性和实现速度。推荐使用快照式历史条目，但在协议层保留后续替换为 diff/delta 存储的空间。

### 4.5 文本输入要做合并，结构操作默认原子化

- 连续输入字符、连续删除、连续同块编辑应自动合并。
- 结构操作（转换块、删除块、插入资源、表格预设）应默认作为单个原子事务入栈。

## 5. 推荐总体方案

### 5.1 总体结论

推荐采用：**编辑器内聚的事务型历史引擎 + 快照式历史条目 + 输入合并策略 + 可选的 UndoManager 桥接层**。

总体结构如下：

```text
BlockDocumentEditor
    │
    ├── BlockEditorMutationDriver
    │       └── 所有编辑入口统一走 applyMutation / applyTextEdit
    │
    ├── BlockEditorHistoryController
    │       ├── past stack
    │       ├── future stack
    │       ├── coalescing state
    │       └── clean revision anchor
    │
    ├── BlockEditorUndoSnapshot
    │       ├── BlockDocument
    │       ├── presentation state
    │       └── metadata
    │
    └── BlockEditorUndoBridge
            └── 与 SwiftUI / AppKit UndoManager、菜单快捷键对接（可选层）
```

### 5.2 为什么推荐快照式而不是命令反演式

本项目当前编辑能力已经比较丰富，而且部分操作的逆操作并不天然简单，例如：

- 多块插入资源
- 表格预设替换当前块
- slash 命令触发的多字段元数据变化
- 后续可能出现的折叠块内容、嵌套块、表格复杂编辑

若采用命令反演式（每个操作都手写 inverse command），会显著增加：

- 实现复杂度
- 漏覆盖风险
- 维护成本

而 `BlockDocument` 与若干 UI 恢复状态本身已经是值语义结构，适合做快照。第一阶段推荐直接存储前后状态快照，以保证语义绝对一致。

## 6. 核心模块设计

### 6.1 `BlockEditorUndoSnapshot`

表示一次可恢复的编辑器状态。

建议结构：

```swift
struct BlockEditorUndoSnapshot: Equatable, Sendable {
    var document: BlockDocument
    var presentation: BlockEditorPresentationSnapshot
    var serializedText: String?
}

struct BlockEditorPresentationSnapshot: Equatable, Sendable {
    var activeBlockID: UUID?
    var focus: BlockEditorFocusSnapshot?
    var selection: BlockEditorSelectionSnapshot?
}

struct BlockEditorFocusSnapshot: Equatable, Sendable {
    var blockID: UUID
    var caretUTF16Offset: Int
}

struct BlockEditorSelectionSnapshot: Equatable, Sendable {
    var blockID: UUID
    var range: NSRange
}
```

说明：

- `document` 是撤销的核心。
- `presentation` 用于恢复“撤销后用户站在哪儿继续编辑”。
- `serializedText` 可选缓存，用于减少重复序列化；第一阶段可以先不启用。

### 6.2 `BlockEditorHistoryEntry`

表示一条历史记录。

```swift
struct BlockEditorHistoryEntry: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case textInput(blockID: UUID)
        case blockStructure
        case inlineFormat(blockID: UUID)
        case slashCommand(blockID: UUID)
        case resourceInsert
        case externalReload
    }

    enum MergePolicy: Equatable, Sendable {
        case never
        case bySession(key: String, timeout: TimeInterval)
    }

    var id: UUID
    var kind: Kind
    var title: String
    var before: BlockEditorUndoSnapshot
    var after: BlockEditorUndoSnapshot
    var mergePolicy: MergePolicy
    var timestamp: Date
}
```

这里 `title` 不是为了第一阶段 UI，而是为了未来历史面板、调试日志与埋点可读性。

### 6.3 `BlockEditorHistoryController`

这是纯状态机，不直接依赖 SwiftUI。

职责：

- 管理 `past` / `future` 两个栈
- 管理当前合并会话
- 记录 clean revision anchor
- 对外提供 `record`, `undo`, `redo`, `reset`, `markClean` 等接口

建议接口：

```swift
struct BlockEditorHistoryController: Sendable {
    private(set) var past: [BlockEditorHistoryEntry] = []
    private(set) var future: [BlockEditorHistoryEntry] = []
    private(set) var cleanEntryID: UUID?

    mutating func record(_ entry: BlockEditorHistoryEntry)
    mutating func undo(current: BlockEditorUndoSnapshot) -> BlockEditorUndoSnapshot?
    mutating func redo(current: BlockEditorUndoSnapshot) -> BlockEditorUndoSnapshot?
    mutating func reset(with snapshot: BlockEditorUndoSnapshot)
    mutating func markClean(at snapshot: BlockEditorUndoSnapshot)
}
```

### 6.4 `BlockEditorMutationDriver`

这是编辑器层最关键的新模块。它负责把“变更行为”统一包装成事务。

建议职责：

- 在 mutation 前抓取 `before snapshot`
- 执行真实变更闭包
- 在 mutation 后抓取 `after snapshot`
- 按 `Kind + MergePolicy` 生成历史记录
- 推送给 `BlockEditorHistoryController`
- 统一清空 `future stack`

建议 API：

```swift
struct BlockEditorMutationDriver {
    mutating func applyMutation(
        kind: BlockEditorHistoryEntry.Kind,
        title: String,
        mergePolicy: BlockEditorHistoryEntry.MergePolicy = .never,
        editor: inout BlockEditorRuntimeState,
        mutation: () -> Void
    )
}
```

注意：这里的 `BlockEditorRuntimeState` 不是要求把 `BlockDocumentEditor` 变成单个巨型 model，而是建议后续把 `document`, `activeBlockID`, `focusRequest`, `selectionState`, `slashState` 中与恢复相关的部分抽成可快照状态。

### 6.5 `BlockEditorUndoBridge`

这是适配层，不应该污染历史核心。

职责：

- 将 `undo` / `redo` 行为暴露给 SwiftUI 或 AppKit 菜单系统
- 可选接入环境 `UndoManager`
- 协调快捷键、菜单标题、可用态

第一阶段即使暂时不做完整菜单桥接，也应保留该层接口，避免以后把平台耦合塞回历史控制器里。

## 7. 事务建模与合并策略

### 7.1 结构操作

以下操作默认一条事务一条历史：

- 块类型转换
- 分块 / 合并块
- 插入块 / 删除块
- 插入资源
- 清除格式
- 表格预设创建
- 缩进 / 反缩进
- slash 命令触发的块级变更

这些操作全部应通过统一入口，例如：

- `applyStructuralMutation(...)`
- `applySlashMutation(...)`
- `applyInlineFormatMutation(...)`

不允许直接在任意方法中写 `document.blocks[index] = ...` 后就结束。

### 7.2 文本输入

文本输入必须做 coalescing。推荐策略：

- 合并条件：
  - 同一个 `blockID`
  - 同一编辑模式（插入 / 删除）
  - 与上次输入间隔不超过 `0.8s ~ 1.5s`
  - 中间没有结构变更、焦点跳转到其他块、显式命令提交
- 合并边界：
  - 按 Enter 分块
  - 按 Tab 缩进
  - 执行 slash 命令
  - 点击其他块
  - 失去焦点
  - 保存 / 重新加载 / 外部冲突

推荐把文本输入建模成“编辑 session”而不是每次 `textDidChange` 立刻入栈：

```swift
struct BlockEditorTextEditSession {
    var blockID: UUID
    var baseline: BlockEditorUndoSnapshot
    var latest: BlockEditorUndoSnapshot
    var startedAt: Date
    var lastEditedAt: Date
}
```

当 session 结束时再真正生成 `HistoryEntry`，这样历史粒度会更符合真实编辑体验。

### 7.3 行内格式

行内格式操作本质上是文本包裹（例如 `**text**`），但用户感知上属于命令操作而不是自然输入。因此建议：

- 默认不与普通 typing session 合并
- 独立记录为一条 `inlineFormat` 事务

## 8. 焦点、光标与选区恢复策略

Undo/Redo 好不好用，很大程度取决于回滚后用户是否能继续自然编辑。

推荐恢复策略：

- 如果撤销前后目标块仍存在，优先恢复到原 blockID
- 如果原 block 被删除，回退到最邻近块
- 如果有有效选区，恢复选区
- 如果只有光标位置，恢复 caret offset
- 如果 offset 超界，裁剪到文本末尾
- slash 菜单、行内浮窗等瞬态 UI 一律不纳入历史恢复；撤销后统一关闭

原因：

- 用户关心的是编辑位置，不关心临时浮层也被“撤销回来”。
- 将浮层状态纳入历史会显著增加复杂度且收益有限。

## 9. 与宿主 FileEditor 的集成设计

### 9.1 与 `FileEditorSessionController` 的关系

`FileEditorSessionController` 仍然负责：

- 文件加载
- 文件保存
- 外部变更冲突
- 脏状态判断

Undo/Redo 不应上移到 `FileEditorSessionController`，原因是它当前只知道纯文本，不知道块级 UI 状态。

因此推荐边界为：

- `BlockDocumentEditor` 负责会话级编辑历史
- `FileEditorSessionController` 只感知 undo/redo 后写回的 `textContent`

### 9.2 保存时的处理

保存成功后不应清空撤销栈，而应：

- 将当前历史位置标记为 `clean revision`
- 允许用户保存后继续撤销到未保存状态，脏标记再次变为 true

这符合主流桌面编辑器行为。

### 9.3 文件切换与外部重载

以下场景必须 `reset history`：

- 打开另一个文件
- 用户选择“重新加载磁盘版本”
- 文本来自外部强制替换，且不是编辑器内部写回

理由：

- 历史记录天然绑定某个编辑会话和某个基线文档。
- 外部重载后若继续沿用旧历史，撤销结果很可能把文档拉回失效基线。

## 10. 平台快捷键与系统 UndoManager 策略

### 10.1 推荐策略

推荐采用：**自定义历史为真相，系统 `UndoManager` 为桥接层，而不是反过来。**

具体含义：

- `NSTextView.allowsUndo` 在 Block 编辑上下文中应关闭，避免本地私有历史。
- `Command+Z` / `Shift+Command+Z` 应路由到编辑器自己的 `undo()` / `redo()`。
- 如果需要菜单栏“撤销输入”“重做删除块”等标题更新，可额外实现 `UndoManager` 适配层。

### 10.2 为什么不直接依赖 AppKit 原生 UndoManager

原生 `UndoManager` 更适合：

- 单 view 文本输入
- 明确的 target/action 反演

但当前编辑器需要：

- 文档模型回滚
- 多块结构变更
- UI 状态恢复
- 宿主保存锚点
- 可测试的纯状态机

这些都更适合先自建历史控制器，再决定是否桥接给平台菜单系统。

## 11. 建议的实施入口重构

为降低未来实现风险，建议后续实现时把 `BlockDocumentEditor` 的直接 mutation 收敛为三类入口：

### 11.1 结构变更入口

```swift
private func applyStructuralEdit(
    title: String,
    kind: BlockEditorHistoryEntry.Kind,
    mutation: () -> Void
)
```

适用于：

- `convertBlock`
- `splitBlock`
- `mergeBlockBackward`
- `insertBlock`
- `deleteBlock`
- `addResources`
- `adjustIndentation`

### 11.2 文本变更入口

```swift
private func registerTextEdit(
    blockID: UUID,
    source: BlockEditorTextEditSource,
    snapshotProducer: () -> BlockEditorUndoSnapshot
)
```

适用于：

- 普通字符输入
- 删除
- 粘贴
- IME 完成后文本落地

### 11.3 历史应用入口

```swift
private func applyHistorySnapshot(_ snapshot: BlockEditorUndoSnapshot)
```

该方法负责：

- 替换 `document`
- 恢复活动块 / 焦点 / 选区
- 清理 slash / inline toolbar 等瞬态 UI
- 调用 `syncText(manualCommit: true)` 写回宿主

## 12. 测试设计

本方案必须以测试驱动方式落地。建议新增以下测试层次。

### 12.1 历史状态机测试

新增独立纯单元测试，覆盖：

- record 后 `past/future` 状态
- undo/redo 基本栈行为
- 新编辑后清空 `future`
- clean revision 标记
- coalescing 合并 / 不合并边界

### 12.2 编辑器事务测试

新增 `BlockDocumentEditor` 级测试，覆盖：

- 文本输入形成单条历史记录
- 分块 / 合并 / 删除 / 转换块可以 undo/redo
- 表格预设与资源插入可 undo/redo
- undo 后焦点恢复到合理位置

### 12.3 宿主集成测试

覆盖：

- 保存后 clean anchor 更新
- 撤销到保存前状态时 dirty 标志变化正确
- 外部 reload 后历史被重置

### 12.4 UI / 交互测试

重点覆盖：

- `Command+Z` / `Shift+Command+Z`
- 连续输入字符合并为一个撤销步
- 撤销删除块后焦点正确回到恢复的块

## 13. 风险与对策

### 13.1 风险：快照占用内存增长

对策：

- 第一阶段设置 history 容量上限，例如 100 条
- 支持按估算字节数裁剪旧记录
- 保留 `HistoryStorage` 抽象，未来替换为 delta 存储

### 13.2 风险：文本输入频繁入栈导致性能抖动

对策：

- 采用编辑 session 合并
- 历史快照只在 session 结束时提交
- 需要时可给 `serializedText` 做惰性缓存

### 13.3 风险：撤销后选区恢复不稳定

对策：

- 先保证 blockID + caret offset 恢复
- 选区恢复作为增强项逐步加入
- 对失效块和越界 offset 使用保守裁剪

### 13.4 风险：与平台原生 UndoManager 冲突

对策：

- 明确关闭 `NSTextView` 的本地 undo 作为真相来源
- 所有撤销快捷键统一路由到编辑器历史控制器

## 14. 推荐落地顺序

建议后续实现分四阶段推进：

### 阶段 1：纯历史状态机

- 实现 `UndoSnapshot / HistoryEntry / HistoryController`
- 写纯单元测试

### 阶段 2：结构操作接入

- 把 `convertBlock / splitBlock / mergeBlockBackward / insertBlock / deleteBlock` 接到统一 mutation driver
- 接入 undo/redo 快捷键

### 阶段 3：文本输入接入

- 去除 `NSTextView` 作为独立历史源
- 引入 text edit session 与合并策略
- 恢复 caret / 焦点

### 阶段 4：宿主与平台桥接

- clean revision
- 保存 / 外部 reload 边界
- 可选 UndoManager 菜单桥接

## 15. 最终建议

本项目的 `BlockDocumentEditor` 不适合继续沿用“结构编辑靠手工 mutation，文本编辑靠 `NSTextView` 自己 undo”的混合方案。推荐尽快收敛为：

- `BlockDocument` 作为唯一文档真相
- `BlockEditorHistoryController` 作为唯一撤销真相
- `BlockEditorMutationDriver` 作为所有可编辑行为的统一事务入口
- `BlockEditorUndoBridge` 作为平台交互适配层

这一方案的优势是：

- 一致性强
- 易测
- 模块化清晰
- 与现有 `FileEditorSessionController` 边界清楚
- 后续可自然扩展到历史浏览、命名检查点、持久化历史、协作编辑

如果后续进入实现阶段，第一件事不应该是“直接往当前方法里塞 undo 逻辑”，而应该先抽出统一的 mutation + snapshot + history 状态机，再把现有编辑路径逐步迁移进去。