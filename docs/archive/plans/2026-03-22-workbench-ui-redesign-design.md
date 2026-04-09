# Workbench UI 布局重构设计方案

日期：2026-03-22

## 摘要

本方案用于重构 agentGui 当前工作台的主交互结构，目标是把聊天恢复为主工作面，把文件与变更审查降级为上下文 detail 面板，同时统一输入区上方的辅助面板系统，并让会话始终明确显示其所属工作空间。

本次设计覆盖四项需求：

- ChatView 作为 content，FileEditorView 作为 detail，detail 在无内容时自动收起，并支持用户手动展开与收起。
- 文件变更 proposal 列表迁移到输入区上方，采用“轻量待审查队列 + 独立 detail 审查器”的两级结构。
- 统一 TodoList、Slash、引用面板和 proposal 面板的风格与键盘模型，提取通用组件。
- 会话在列表、聊天头部和窗口层面都具备显著的工作空间标识。

推荐方向不是在现有视图树上继续堆条件分支，而是把工作台拆成三个稳定层级：

1. Sidebar：导航与资源入口。
2. Conversation Content：会话消息流与输入区，是主阅读与主操作面。
3. Contextual Detail：文件、diff、proposal 详情等上下文检查器，在需要时出现。

这样可以让 UI 的职责边界更清晰，也为后续扩展终端、诊断、审查结果等 detail 类型留出空间。

## 背景与问题

当前实现中，WorkbenchShellView 使用三列 NavigationSplitView，结构为 Sidebar | FileEditor | Chat。这个结构在代码上能工作，但交互重心是反的：

- 聊天是用户持续停留时间最长、最频繁输入的面板，却被放在 detail 列。
- 文件编辑器与变更审查承担了中列主面角色，但它们实际上更接近上下文检查器。
- proposal 审查当前通过 badge 从输入区跳转到 FileEditorView 内的 ChangeProposalReviewView，链路偏长，且列表入口不稳定。
- 输入区已经承担 slash、mention、todo 三类辅助面板职责，但没有统一容器、统一键盘模型、统一状态机。
- 工作空间信息虽然存在于窗口标题和部分侧栏状态中，但在会话列表和当前会话主界面上不够显著，跨仓库、多目录场景下容易误判上下文。

这些问题的根因不是单个组件样式不好，而是信息架构没有区分“主任务流”和“上下文检查流”。

## 设计依据与调研结论

本方案参考了当前主流 AI 编程工具的公开资料与交互共性，结论如下：

### 1. 聊天输入区附近适合放轻量上下文面板，不适合承载完整审查流

VS Code Copilot 的公开文档表明，模型选择、权限、上下文引用等控制主要围绕 chat composer 展开，而 AI 变更审查则发生在 editor 或 source control 相关视图中。也就是说，输入区附近适合放“上下文选择”和“待处理事项摘要”，不适合承载完整 diff 审查器。

### 2. 主流 coding agent 普遍把 diff review 作为独立 surface，而不是消息流内嵌内容

Cursor 的公开文档强调 diff 视图实时显示变更，Review 行为也围绕 diff 与独立 review 工具展开。这说明“proposal 列表贴近输入区”是合理的，但“proposal 全量审查嵌在输入区或消息流”不是最佳结构。

### 3. 工作空间身份在 agent 型产品中是一级上下文

Claude Code 的官方文档反复强调 session、工具与运行环境都依附于同一个 project/workspace context。对于 agentGui 这类面向代码工作的产品，会话若不显式标识工作空间，用户容易在多会话、多仓库、多运行目录之间发生误操作。

基于以上结论，本方案采用“两级 proposal 审查模型”：

- 一级：输入区上方的 Proposal Dock，负责提醒、选择、快速处理。
- 二级：detail 列中的 Proposal Review Inspector，负责完整 diff 审查与逐文件操作。

## 设计目标

- 让 ChatView 成为真正的主工作面。
- 让 detail 面板成为“按需出现”的上下文检查器，而不是常驻主列。
- 让 proposal 从零散 badge 升级为输入区附近的稳定待办队列。
- 让输入区辅助面板形成统一的视觉与交互系统。
- 让用户在任意时刻都能明确知道当前会话绑定的工作空间。
- 让状态模型可扩展，后续可以继续承载更多 detail 类型与 composer 面板类型。

## 非目标

- 不重写消息列表与消息卡片体系。
- 不在本次设计中重做左侧所有导航面板。
- 不追求把所有浮层都抽象成一个过度通用、难以维护的超级协议。
- 不复制某一款竞品的具体视觉，而是吸收其稳定的信息架构模式。

## 总体信息架构

### 新的工作台结构

新的三列结构调整为：

- Sidebar：WorkbenchSidebarView，不变。
- Content：ChatView，为主会话区。
- Detail：WorkbenchDetailHost，承载 FileEditor、GitDiff、ChangeProposalReview 等上下文视图。

工作原则如下：

- 用户没有打开任何文件、diff 或 proposal 时，detail 自动收起。
- 用户选择文件、打开 diff、或进入 proposal 详情时，detail 自动展开。
- 用户可以手动收起 detail。手动收起后，系统仍保留当前 detail selection，但不强制显示，直到用户重新展开或新的高优先级上下文显式请求展示。
- Chat 内容区不因 detail 收起而失去可用性，始终保持为主操作面。

### proposal 的新位置

proposal 不再只通过输入区顶部的一枚 badge 暴露，而是在 input area 上方形成一个稳定的 Proposal Dock。它属于聊天区的一部分，但在语义上是“当前会话待处理更改”的局部队列，而不是某条消息的子内容。

Proposal Dock 负责：

- 展示当前会话待审查 proposal 数量与状态。
- 展示 proposal 项摘要，例如标题、文件数、剩余待处理数、最新更新时间。
- 提供快速动作，例如打开审查、应用全部、丢弃提案。
- 通过键盘方向键与回车完成选择和打开。

完整 diff 审查仍在 detail 列完成。

## 状态架构

### 1. 用统一的 detail selection 替代分散状态

当前 WorkspaceState 同时维护 selectedFile、selectedGitDiffPath、selectedGitDiffText、selectedChangeProposalID 等状态，并通过 didSet 互相清空。这个方案能运行，但扩展性差，而且不利于 detail 自动收起与恢复。

建议引入统一 detail 选择模型：

```swift
enum WorkbenchDetailSelection: Equatable {
    case none
    case file(URL)
    case gitDiff(title: String, diffText: String)
    case changeProposal(proposalID: UUID, filePath: String?)
}
```

WorkspaceState 只暴露一个主状态：

```swift
var detailSelection: WorkbenchDetailSelection
```

现有的 selectedFile、selectedChangeProposalID 等字段在迁移期可以保留为兼容层，但最终应收敛到 detailSelection，避免多源状态互相覆盖。

### 2. 引入 detail 展示策略状态

除了“选中了什么”，还要单独建模“是否展示 detail”：

```swift
enum WorkbenchDetailVisibilityMode: Equatable {
    case automatic
    case userCollapsed
    case userExpanded
}
```

最终是否显示 detail，由以下规则计算：

- `userCollapsed`：隐藏。
- `automatic`：仅当 `detailSelection != .none` 时显示。
- `userExpanded`：显示；若 `detailSelection == .none`，则展示空 detail 占位态或最近一次可恢复内容。

推荐默认策略：

- 初始为 `automatic`。
- 用户点击收起按钮后进入 `userCollapsed`。
- 用户点击展开按钮后进入 `automatic`，而不是永久锁定展开。

这样交互更符合“上下文检查器按需出现”的语义。

### 3. 引入统一的 composer assist 状态

当前 ChatView 通过 `ChatComposerAssistSurface` 在 slash、mention、todo 三者之间切换，但 proposal 不在同一套系统里。

建议扩展为：

```swift
enum ComposerAssistPanelKind: Equatable {
    case slash
    case mention
    case todo
    case proposal
}
```

同时拆出统一状态容器：

```swift
struct ComposerAssistPanelState {
    var activeKind: ComposerAssistPanelKind?
    var keyboardSelection: Int?
    var isPersistent: Bool
}
```

其中：

- slash、mention 属于瞬时面板。
- todo、proposal 属于可持续可见面板。
- 是否显示 proposal，不由输入文本决定，而由 session 的 change review projection 决定。

## 组件拆分方案

### 一、工作台层

#### WorkbenchShellView

职责缩减为：

- 组装 NavigationSplitView。
- 绑定 Sidebar / Content / Detail 三列。
- 处理 column visibility 与 layout state。
- 注入全局 environment。

不再直接知道“文件编辑器还是聊天谁在 content/detail”，而是通过明确的子视图承接。

#### WorkbenchConversationPane

新组件，负责承载：

- ChatView
- 会话级标题副标题
- 工作空间标识
- detail toggle toolbar action

它的目标是让“聊天作为主工作面”的布局更清晰，不让 WorkbenchShellView 持续膨胀。

#### WorkbenchDetailHost

新组件，负责根据 `WorkbenchDetailSelection` 渲染：

- FileEditorView
- GitDiffView
- ChangeProposalReviewView
- 空态

该组件不负责改变 selection，只负责解释 selection 并渲染相应的 detail 内容。

### 二、proposal 审查层

#### ProposalDockView

新组件，位于 input area 上方。职责：

- 读取会话级 `SessionChangeReviewProjection`。
- 生成摘要列表。
- 显示 pending proposal 列表。
- 处理快速动作与键盘导航。
- 打开 detail 审查器。

#### ProposalDockItemView

列表项组件，建议展示：

- 提案标题或主文件名。
- 待审查文件数 / 总文件数。
- 状态标记，例如“待处理”“部分已处理”。
- 次要信息，如更新时间。
- 快捷动作入口。

#### ProposalReviewInspectorBridge

不是独立 UI 组件，而是一个职责层：负责把 Proposal Dock 的打开动作转换为 `WorkbenchDetailSelection.changeProposal(...)`，避免 Dock 直接操作多个 WorkspaceState 字段。

### 三、统一辅助面板层

#### ComposerAssistPanelContainer

通用容器组件，负责统一以下视觉行为：

- 面板圆角、材质、边框、间距。
- 标题区、内容区、页脚区。
- hover、focus、active row 的样式。
- 出入场动画。

它只负责壳，不负责业务数据。

#### ComposerSelectableList

通用可选列表组件，负责：

- 高亮项索引。
- 键盘上移、下移。
- 回车确认。
- 空态呈现。

Slash、Mention、Proposal 都可以复用这层；Todo 可复用壳与 row 样式，但不必强行复用同一个交互协议。

#### ComposerPanelHeaderStyle / ComposerPanelRowStyle

建议提取样式层，而不是一味提取 ViewModel 协议。原因是四类面板的数据形态不同，但视觉层高度一致。应该优先统一容器与 row 样式，再在交互层复用选择模型。

### 四、工作空间身份层

#### SessionWorkspaceBadgeView

新组件，用于在会话列表中显示工作空间标识。建议信息结构：

- 主 badge：工作空间短名，例如 `agentGui`。
- 次 badge：来源类型，例如“会话级”“全局”。
- 悬浮时显示完整路径。

#### WorkspaceIdentityHeaderView

新组件，用于在聊天内容区头部或工具栏位置显示当前会话的工作空间。建议呈现为更显眼的 chip，而不是仅依赖 navigation subtitle。

## 交互设计

### 1. Detail 面板交互

#### 自动行为

- 用户在工作区树中打开文件：detail 自动展开并显示文件。
- 用户从消息或 proposal dock 打开变更审查：detail 自动展开并进入审查器。
- 当前 detail 内容被关闭且无其他 detail 内容可展示：detail 自动收起。

#### 手动行为

- 工具栏提供“显示/隐藏 detail”按钮。
- 当 detail 已打开时，按钮表现为收起。
- 当 detail 被隐藏且存在可恢复 selection 时，按钮表现为展开最近上下文。

#### 建议快捷键

- `Cmd+\`：切换 detail 显示状态。
- `Esc`：若 assist panel 打开则先关闭 assist panel；若 assist panel 已关闭且 detail 为当前焦点，可收起 detail。

### 2. Proposal Dock 交互

Proposal Dock 位于 input area 上方，行为应当稳定，不随输入文本闪烁。建议规则：

- 只要当前会话存在 pending proposal，dock 就显示。
- proposal 数量为 1 时，展示单卡摘要。
- proposal 数量大于 1 时，展示列表，可滚动但高度受控。
- 点击条目主体：在 detail 打开 proposal review。
- 点击快捷动作：直接 apply/discard，对高风险动作需二次确认。

### 3. 统一辅助面板交互

四类面板统一遵循以下键盘模型：

- 上下方向键：切换高亮项。
- 回车：确认当前项。
- `Esc`：关闭当前面板。
- 鼠标 hover 与键盘高亮使用同一种 active 样式，避免双重视觉语义。

具体差异：

- Slash：瞬时面板，输入变更后实时过滤。
- Mention：瞬时面板，输入变更后实时过滤。
- Todo：可持续面板，默认只读，可扩展为点击跳转任务上下文。
- Proposal：可持续面板，支持打开 detail 与快捷审查动作。

### 4. 工作空间标识交互

#### 会话列表

每个 SessionRow 增加工作空间 badge，并遵循以下优先级：

- 有会话级 working directory：显示会话级目录短名。
- 无会话级目录但有全局工作目录：显示全局目录短名，并标记“全局”。
- 两者都无：显示“未设置工作区”。

#### 当前会话头部

在 Chat 主界面头部放置当前工作空间 chip，显示短名，辅助文本展示来源类型；完整路径通过 tooltip 或展开态显示。

#### 窗口标题

继续保留窗口标题与 representedURL，但不再把它作为唯一的工作空间身份出口。

## 视觉设计原则

- Content 与 Detail 必须有明确主次关系。Content 更宽、更稳定，Detail 更轻、更像 inspector。
- 输入区上方的辅助面板应形成同一家族样式，避免 slash、mention、todo、proposal 像四套系统。
- proposal dock 的视觉权重要高于 badge、低于消息正文，避免喧宾夺主。
- 工作空间 badge 应该“显著但不吵闹”，建议采用一致的 chip 语言，而不是增加大量彩色标签。
- 不依赖 hover 才暴露关键状态，尤其是 proposal 待处理与当前工作空间。

## 数据流设计

### proposal 流

1. `ChangeReviewProjectionStore` 为当前 session 产出 `SessionChangeReviewProjection`。
2. `ProposalDockPresenter` 将 projection 转换为 `ProposalDockPresentation`。
3. `ProposalDockView` 渲染 dock 列表。
4. 用户选择某一项时，事件统一转换为 `WorkbenchDetailSelection.changeProposal(...)`。
5. `WorkbenchDetailHost` 接管并展示 `ChangeProposalReviewView`。
6. 审查动作完成后，projection 更新；Dock 与 Detail 同步刷新。

### detail 流

1. 任何打开文件、diff、proposal 的动作都转换为统一 `detailSelection`。
2. `WorkbenchLayoutController` 根据 `detailSelection + visibilityMode` 计算是否显示 detail。
3. `WorkbenchDetailHost` 根据 selection 决定实际内容。

### 工作空间流

1. `WorkspaceState` 基于 selectedSession 与全局设置计算 effective working directory。
2. `SessionWorkspacePresentationFactory` 生成列表 badge 和头部 chip 的展示模型。
3. SessionListView 与 Chat 头部都消费同一份 presentation，避免多处自行拼装字符串。

## 模块建议

建议新增或重组的模块如下：

- `Views/Workbench/WorkbenchConversationPane.swift`
- `Views/Workbench/WorkbenchDetailHost.swift`
- `Views/ChatComposer/ProposalDockView.swift`
- `Views/ChatComposer/ProposalDockItemView.swift`
- `Views/ChatComposer/ComposerAssistPanelContainer.swift`
- `Views/ChatComposer/ComposerSelectableList.swift`
- `Views/Session/SessionWorkspaceBadgeView.swift`
- `ViewModels/ProposalDockPresenter.swift`
- `ViewModels/SessionWorkspacePresentationFactory.swift`
- `Utilities/WorkbenchDetailSelection.swift`
- `Utilities/WorkbenchDetailVisibilityMode.swift`

命名不是强制要求，但模块边界应保持稳定：

- 展示模型与状态机放在 ViewModels / Utilities。
- 通用壳层组件放在独立目录，避免继续膨胀到 ChatView+InputArea.swift。
- ChatView 只保留对这些组件的组合关系，不再承载全部细节实现。

## 分阶段落地计划

### Phase 1：工作台布局反转

- 调整 WorkbenchShellView，让 ChatView 进入 content，FileEditor 进入 detail。
- 引入统一 detail selection 与 detail visibility mode。
- 接通 detail 自动展开与自动收起逻辑。

### Phase 2：Proposal Dock 上移

- 把 proposal 入口从单一 badge 升级为 dock。
- 保留 detail 内的 ChangeProposalReviewView 作为完整审查器。
- 完成 proposal 选择、快速动作与 detail 打开链路。

### Phase 3：统一辅助面板系统

- 抽出 ComposerAssistPanelContainer 与 ComposerSelectableList。
- 把 slash、mention、todo 迁移到统一壳层。
- 再把 proposal dock 接入统一样式与键盘模型。

### Phase 4：工作空间身份增强

- 在 SessionRow 中加入 workspace badge。
- 在 Chat 头部加入 workspace chip。
- 统一 presentation factory，清理重复字符串拼装。

### Phase 5：清理与文档

- 清理 WorkspaceState 中已废弃的分散 detail 字段。
- 收敛 InputArea 中遗留的局部样式实现。
- 补充 UI 测试与设计文档。

## 风险与应对

### 风险 1：状态迁移期间，旧字段与新 detailSelection 双写导致状态错乱

应对：

- 先建立适配层，明确单向同步规则。
- 在迁移完成前禁止新代码继续直接写入旧字段。

### 风险 2：proposal dock 与 slash/mention 面板竞争垂直空间

应对：

- proposal dock 视为 persistent section，slash/mention 视为 transient section。
- 容器按“persistent 在上，transient 在下”分层，避免互相覆盖。

### 风险 3：detail 自动收起让用户误以为内容丢失

应对：

- 收起前保留可恢复 selection。
- 工具栏按钮和空态明确提示“展开最近上下文”。

### 风险 4：统一面板抽象过度，导致 proposal/todo 的特例反而更复杂

应对：

- 统一视觉壳与选择模型，不强行统一全部业务协议。
- 面板内容依然允许使用各自 presenter。

## 测试策略

### 单元测试

- `WorkbenchDetailLayoutResolverTests`
  - 验证 `detailSelection` 与 `visibilityMode` 如何解析为实际列显示状态。
- `ProposalDockPresenterTests`
  - 验证 proposal 列表摘要、排序、状态文本。
- `SessionWorkspacePresentationFactoryTests`
  - 验证会话级目录、全局目录、未设置三种展示结果。
- `ComposerAssistSelectionControllerTests`
  - 验证上下移动、确认、取消的统一键盘行为。

### UI 测试

- 选择文件时 detail 自动展开。
- 清空 detail selection 时 detail 自动收起。
- proposal dock 在存在 pending proposal 时出现，并可打开 detail 审查器。
- slash、mention、proposal 面板支持上下键与回车。
- SessionList 中能稳定显示工作空间 badge。

### 手工验证

- 多会话切换时，workspace badge 是否与会话真实目录一致。
- proposal 被 apply/discard 后，dock 与 detail 是否同步更新。
- 用户手动收起 detail 后，聊天区是否维持稳定宽度与输入体验。

## 推荐实施顺序

若只从交付价值出发，建议按以下顺序实施：

1. 先做工作台布局反转与 detail 状态统一。
2. 再做 proposal dock 上移。
3. 然后统一辅助面板体系。
4. 最后补齐会话工作空间标识与收尾清理。

原因是第一步会决定后面三项需求的宿主结构；如果不先把聊天扶正为主 content，proposal dock 和统一面板系统都会继续依附在一个错误的布局重心上。

## 最终建议

最终建议采用“Chat-first workbench + contextual detail inspector + unified composer assist surfaces”的方案。

这个方案的优点是：

- 交互重心正确，聊天成为真正主面。
- proposal 审查路径更短，但仍保留专业的独立 diff 审查器。
- 输入区上方的所有辅助面板有一致的视觉与键盘体验。
- 工作空间身份在会话层变得可见，降低误操作风险。
- 状态模型可扩展，后续继续加入 terminal preview、diagnostics detail、search result detail 都不会破坏架构。

这套设计不会只解决当前四个点，而是把工作台的基础信息架构重新摆正。