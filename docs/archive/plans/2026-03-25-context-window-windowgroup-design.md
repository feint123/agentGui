# 上下文窗口 WindowGroup 化设计

## 背景

当前上下文窗口使用单例 `Window("上下文", id: WorkbenchContextWindowScene.id)` 承载，窗口内部再通过 `WorkbenchContextWindowState` 和 `WorkbenchContextWindowView` 自绘一套标签条。现状有三个结构性问题：

1. Scene 语义和 Apple 推荐不一致。SwiftUI 的 `Window` 适合“单例补充窗口”，而不是可多开、可聚合的主内容容器。
2. 标签页能力重复造轮子。macOS 已经提供原生窗口 tab bar、Window 菜单和 tab 生命周期管理，但当前实现把这些能力重新放到了应用层状态里。
3. 状态层次混乱。现在的“标签页”既是 UI 表现，又承担内容路由与窗口展示请求，导致窗口体系和内容体系强耦合。

用户目标很明确：上下文窗口应改为 `WindowGroup`，tab 直接使用 macOS 原生 window tab bar，而不是自绘 tab strip。

## Apple 官方文档结论

本设计直接基于以下 Apple 文档结论：

- SwiftUI `WindowGroup`
  - 官方定义是“一组结构相同的窗口”。
  - 在 macOS 上，用户可以同时打开多个窗口，并且“可以把打开的窗口聚合成 tabbed interface”。
  - 使用 data-driven `WindowGroup(for:)` 或 `WindowGroup(id:for:)` 时，`openWindow(value:)` 会把值绑定到对应窗口；如果相同值的窗口已经存在，系统会将该窗口前置，而不是再新开一份。
- SwiftUI `Window`
  - 官方定义是“单个、唯一的窗口”。
  - Apple 明确建议：大多数情况下主场景应优先使用 `WindowGroup`，`Window` 更适合作为补充功能窗口。
- AppKit `NSWindow`
  - `tabbingMode` 可设为 `.automatic`、`.preferred`、`.disallowed`。
  - `tabbingIdentifier` 用于把相关窗口归为同一组；相同 identifier 的窗口更容易被系统合并为 tab。
  - `allowsAutomaticWindowTabbing` 是 app 级总开关。
  - 系统原生提供 `selectNextTab(_:)`、`selectPreviousTab(_:)`、`mergeAllWindows(_:)`、`moveTabToNewWindow(_:)` 等行为。

这组文档共同指向一个结论：如果“上下文”本质上是同构内容实例的集合，且希望复用 macOS 原生 tab bar，那么 scene 层应以 `WindowGroup` 为核心，而不是继续用单例 `Window` 包一个自绘 tab UI。

## 当前实现盘点

当前相关实现主要集中在以下位置：

- `agentGui/agentGuiApp.swift`
  - 主工作台使用 `WindowGroup`
  - 上下文窗口使用单独的 `Window`
- `agentGui/Utilities/WorkbenchContextWindowState.swift`
  - 维护 `tabs`、`selectedTabID`、打开请求 token，以及关闭/切换标签行为
- `agentGui/Views/Workbench/WorkbenchContextWindowView.swift`
  - 自绘 tab strip
  - 根据 `WorkbenchDetailSelection` 渲染文件、Git diff、Change Proposal
  - 依赖 `dismiss()` 在 tab 归零时关闭窗口
- `agentGui/Utilities/WorkspaceState.swift`
  - 打开文件、Diff、提案时统一把 detail selection 推入 `contextWindowState.open(...)`
- `agentGui/AppCommands/Core/AppCommandRouter.swift`
  - “打开上下文窗口 / 上一个标签页 / 下一个标签页”仍然直接操作 `contextWindowState`

这说明当前已经具备“上下文内容选择模型”，但没有真正使用 SwiftUI/macOS 的原生多窗口模型。

## 设计目标

### 目标

1. 把上下文窗口从单例 `Window` 改为 `WindowGroup`。
2. 移除 `WorkbenchContextWindowView` 顶部自绘 tab strip，改用 macOS 原生 window tab bar。
3. 保持“同一个逻辑上下文只打开一个实例；再次打开时聚焦已有实例”的体验。
4. 保留文件、Git diff、Change Proposal 三类上下文承载能力。
5. 保持窗口标题、副标题、represented URL 等现有 macOS 集成体验。
6. 让命令系统尽量复用系统 tab 行为，而不是继续维护应用层 tab 顺序。

### 非目标

1. 本次不改造主工作台 `WindowGroup`。
2. 本次不处理 iPadOS 多窗口适配。
3. 本次不引入新的文档模型或持久化 schema。
4. 本次不顺手重写文件编辑器、Git diff、提案视图内部逻辑。

## 方案对比

### 方案 A：保留现有 `Window`，只把 tab strip 换成更接近系统样式

优点：改动最小。

缺点：根问题没有解决。Scene 仍然是单例补充窗口，tab 仍然是应用自管，Window 菜单、系统 tab 命令、窗口恢复语义都无法自然接入。

结论：不推荐。

### 方案 B：改为 `WindowGroup`，每个上下文实例对应一个原生窗口，tab 交给 macOS 原生窗口体系

优点：和 Apple 场景模型一致；天然支持 Window 菜单、Merge All Windows、Move Tab to New Window、系统级前后切换；应用层状态明显简化。

缺点：需要重做上下文窗口的 scene value 和状态路由；原有 tab 级命令需要迁移。

结论：推荐。这是本设计采用的方案。

### 方案 C：保留单窗口，但把内容切换改成 `TabView`

优点：SwiftUI 代码更少。

缺点：这仍然不是 macOS 原生 window tab bar，只是另一种自绘标签实现，而且会继续把窗口职责和内容职责混在一起。

结论：不推荐。

## 推荐方案

### 核心思路

把“上下文标签”重新定义为“上下文窗口实例”。每一个文件、Diff、Change Proposal 都对应一个 `WindowGroup` 中的场景值。系统负责决定这些窗口是分离显示，还是由用户合并成原生 tab 组。应用只负责：

1. 生成稳定、轻量、可序列化的 scene value。
2. 使用 `openWindow(value:)` 或 `openWindow(id:value:)` 打开对应实例。
3. 在窗口内容内部根据 scene value 解析并展示内容。
4. 对窗口做统一的 tabbing 配置，使其优先参与同组 tabbing。

应用不再维护“当前有哪些 tab、tab 顺序如何、右侧有哪些 tab”这类系统已经能处理的 UI 状态。

### Scene 模型

新增一个轻量值类型，例如 `WorkbenchContextSceneValue`：

- `file(path: String)`
- `gitDiff(title: String, diffCacheKey: String)`
- `changeProposal(proposalID: UUID, filePath: String?)`

该类型必须满足：

- `Hashable`
- `Codable`
- 能稳定表达“同一逻辑上下文”

这样做有两个直接收益：

1. 符合 Apple 对 data-driven `WindowGroup` 的要求。
2. 再次打开相同 value 时，系统可以直接前置现有窗口，而不是重复创建。

注意点：

- `file` 不能直接持有 `URL` 的复杂派生状态，建议保存 standardized path 字符串，再在视图层恢复为 `URL`。
- `gitDiff` 的 value 不应直接把整段 diff 文本塞进 scene value。应以可重建的 key 或快照标识承载，否则会让值过重、恢复不可控。
- `changeProposal` 应以 `proposalID` 为主键，`filePath` 作为可选补充路由信息。

### Scene 声明

把当前：

- `Window("上下文", id: WorkbenchContextWindowScene.id)`

改为类似：

- `WindowGroup("上下文", id: WorkbenchContextWindowScene.id, for: WorkbenchContextSceneValue.self) { $selection in ... }`

这样“上下文窗口”从单例变成同构多实例组，和 Apple 官方推荐的主内容窗口模型一致。

内容闭包接收到 `Binding<WorkbenchContextSceneValue?>` 或默认值版本后，应立即把它转成实际可渲染的 detail selection，并在缺值时渲染空态或做兜底。

### 窗口内容结构

`WorkbenchContextWindowView` 需要从“tab 容器 + 内容渲染器”改成“单个上下文实例渲染器”。也就是：

1. 删除顶部 `tabStrip`
2. 删除基于 `contextWindowState.tabs` 的切换逻辑
3. 保留 `content(for:)` 这层分发，但它的输入改为当前 scene value 对应的单个 selection
4. `dismiss()` 只用于关闭当前窗口实例，不再由“全部 tab 关闭”驱动

视图职责收敛后，`WorkbenchContextWindowView` 会更接近标准 SwiftUI window content，而不是一个小型窗口管理器。

### AppKit 配置

为了让这些窗口尽可能稳定地参与同一组原生 tab，需要在现有 `NSViewRepresentable` 配置点上补两类设置：

1. app 级设置
   - 在 app 启动早期设置 `NSWindow.allowsAutomaticWindowTabbing = true`
2. window 级设置
   - 给上下文窗口设置固定的 `tabbingIdentifier`，例如 `workbench-context`
   - 给上下文窗口设置 `tabbingMode = .preferred`

其中 `WorkbenchWindowConfigurator` 已经是现成的切入点，当前只设置 title、subtitle、representedURL。建议为上下文窗口单独扩展一个 configurator，或者给现有 configurator 增加可选 tabbing 配置参数，避免把所有窗口都强行归入同一 tab 组。

### 打开逻辑

`WorkspaceState` 不再调用 `contextWindowState.open(...)` 去追加应用内 tab，而是改为生成 `WorkbenchContextSceneValue` 并触发 `openWindow`。

推荐把这层能力封装成独立路由器，例如：

- `WorkbenchContextWindowRouter`

职责：

1. `selection -> scene value` 的转换
2. 调用 `openWindow(id:value:)`
3. 对 diff / proposal 这类需要预热缓存的场景做必要的准备

这样 `WorkspaceState` 仍然只表达“我要展示哪个 detail”，但不再直接持有 tab 容器语义。

### 命令系统改造

当前命令系统有三类和上下文 tab 强绑定的命令：

1. 打开上下文窗口
2. 下一个上下文标签页
3. 上一个上下文标签页

改造后建议分两层：

1. “打开当前上下文”继续保留，但实现改为 `openWindow(id:value:)`
2. “下一个/上一个上下文标签页”不再操作 `WorkbenchContextWindowState`，而是转向系统窗口 tab 行为

实现上有两个可选路径：

- 路径 1：直接移除自定义“上下文标签页切换”命令，依赖 macOS 自带 Window 菜单
- 路径 2：保留菜单项，但命令执行时把焦点窗口的 `NSWindow` 作为 target，调用 `selectNextTab(nil)` / `selectPreviousTab(nil)`

推荐先采用路径 1。理由是最符合系统模型，也能减少跨 SwiftUI/AppKit 桥接复杂度。如果产品层面坚持保留自定义命令，再补路径 2 即可。

### 状态模型调整

`WorkbenchContextWindowState` 当前主要承担三个职责：

1. 保存标签集合
2. 保存选中标签
3. 驱动“展示窗口”请求

在新架构里，前两项不再需要由应用维护，第三项也应转移到 window router。因此它不应继续作为中心状态对象存在。

推荐拆分为：

- 删除：`tabs`、`selectedTabID`、`closeTabsToRight`、`selectNextTab`、`selectPreviousTab` 等 tab 管理 API
- 保留或重命名：如果仍需要统一的上下文展示入口，则以 router/service 形式存在，而不是 observable tab store

这一步是本次改造最关键的“减法”。如果 `WorkbenchContextWindowState` 只是换个名字继续维护 tab 数组，说明架构并没有真正切换到系统窗口模型。

## 具体改造落点

### 需要修改的现有文件

- `agentGui/agentGuiApp.swift`
  - 把上下文 scene 从 `Window` 改成 data-driven `WindowGroup`
  - 注入新的上下文窗口路由能力
- `agentGui/Views/Workbench/WorkbenchContextWindowView.swift`
  - 删除自绘 tab strip
  - 改成单实例内容视图
- `agentGui/Utilities/WorkspaceState.swift`
  - 从“向 tab store 开页”改为“请求打开指定 context window value”
- `agentGui/AppCommands/Core/AppCommandRouter.swift`
  - 删掉对 `contextWindowState.selectNextTab()` / `selectPreviousTab()` 的直接依赖
- `agentGui/AppCommands/Core/AppCommandRegistry.swift`
  - 调整上下文标签页相关命令文案与可用性判定
- `agentGui/Views/Workbench/WorkbenchTitlePresentation.swift`
  - 复用或扩展 window configurator，使上下文窗口支持 tabbing 配置
- `agentGui/Utilities/WorkbenchSceneServices.swift`
  - 移除旧的 context tab store 注入，替换为 router 或 presentation service

### 建议新增的文件

- `agentGui/Utilities/WorkbenchContextSceneValue.swift`
  - 定义 data-driven window value
- `agentGui/Utilities/WorkbenchContextWindowRouter.swift`
  - 封装 `selection -> openWindow(value:)` 路由
- `agentGui/Views/Workbench/WorkbenchContextWindowConfigurator.swift`
  - 专门负责上下文窗口 `tabbingIdentifier` / `tabbingMode` 设置

## 迁移步骤

### 第 1 阶段：建立新 scene value 和 window group

先引入 `WorkbenchContextSceneValue` 与新的 `WindowGroup` 声明，但暂时允许旧 `WorkbenchContextWindowState` 共存，便于小步迁移。

### 第 2 阶段：把打开逻辑切到 `openWindow(id:value:)`

把文件、Diff、提案入口逐步改成生成 scene value 并打开上下文实例。此时相同 value 应满足“已打开则前置”的行为。

### 第 3 阶段：移除自绘 tab strip

确认多实例窗口能正确打开后，再删除 `WorkbenchContextWindowView` 中的 tab UI 和 tab 操作菜单，避免迁移过程中失去内容访问能力。

### 第 4 阶段：清理应用层 tab 状态与命令

最终删除 `WorkbenchContextWindowState` 中所有 tab 相关逻辑，收敛命令系统到原生窗口命令模型。

## 风险与缓解

### 风险 1：Git diff 内容缺少稳定标识

如果 diff 只以原始文本存在于内存里，那么 scene value 很难保持轻量且可恢复。

缓解：为 diff 增加快照缓存键或临时存储仓库，把 scene value 限定为 key，而不是全文。

### 风险 2：`openWindow(value:)` 的调用位置在纯状态对象中不可用

`openWindow` 是环境值，不适合直接深入 `WorkspaceState` 这类非 View 类型。

缓解：显式引入 router/service，由 scene 或 view 层注入 `OpenWindowAction`，状态对象只发出意图，不直接持有环境能力。

### 风险 3：窗口标题和 represented URL 可能因 scene value 化而退化

如果只做 scene value 路由、不补 window configurator，原有 Finder 代理图标、标题、副标题体验可能丢失。

缓解：保留当前 `WorkbenchTitlePresentation` 路线，并让单实例 context view 继续根据实际内容动态配置窗口元信息。

### 风险 4：自定义“上一个/下一个标签页”命令行为变化

从应用自管 tab 切到系统 tab 后，可用性判断和行为来源都会变化。

缓解：第一阶段先依赖系统 Window 菜单；如果用户仍需要自定义命令，再做基于焦点 `NSWindow` 的桥接实现。

## 验收标准

完成改造后，应满足以下结果：

1. 上下文 scene 使用 `WindowGroup` 而非单例 `Window`。
2. `WorkbenchContextWindowView` 不再包含自绘 tab strip。
3. 打开多个上下文实例时，用户可使用 macOS 原生 window tab bar 聚合与切换。
4. 再次打开相同上下文时，系统前置已有窗口实例，而不是重复创建。
5. 上下文窗口仍然保留正确的标题、副标题、represented URL。
6. 代码中不再存在以 `tabs` 数组维护上下文窗口 UI 的核心路径。

## 建议的后续实现顺序

1. 先做 scene value 与 `WindowGroup` 声明改造。
2. 再抽出 `WorkbenchContextWindowRouter`，迁移 `WorkspaceState` 的打开路径。
3. 然后删掉自绘 tab UI。
4. 最后收口命令系统和旧状态对象。

这个顺序能保证每一步都可运行、可验证，也便于在中途观察 macOS 原生 tabbing 是否符合预期。

## 参考文档

- Apple Developer: SwiftUI `WindowGroup`
  - https://developer.apple.com/documentation/swiftui/windowgroup
- Apple Developer: SwiftUI `Window`
  - https://developer.apple.com/documentation/swiftui/window
- Apple Developer: `NSWindow.TabbingMode`
  - https://developer.apple.com/documentation/appkit/nswindow/tabbingmode
- Apple Developer: `NSWindow.allowsAutomaticWindowTabbing`
  - https://developer.apple.com/documentation/appkit/nswindow/allowsautomaticwindowtabbing
- Apple Developer: `NSWindow.tabbingIdentifier`
  - https://developer.apple.com/documentation/appkit/nswindow/tabbingidentifier
- Apple Developer: `NSWindow.selectPreviousTab(_:)`
  - https://developer.apple.com/documentation/appkit/nswindow/selectprevioustab(_:)

## Implementation Status

截至 2026-03-25，本设计已经按推荐方案落地，具体包括：

1. 上下文 scene 已从单例 `Window` 迁移到 data-driven `WindowGroup`。
2. `WorkbenchContextSceneValue`、`WorkbenchDiffSnapshotStore` 与 `WorkbenchContextWindowRouter` 已替代旧的应用层 tab store 路径。
3. `WorkbenchContextWindowView` 已收缩为单实例上下文渲染器，自绘 tab strip 已删除。
4. 上下文窗口已接入 `NSWindow.allowsAutomaticWindowTabbing`、固定 `tabbingIdentifier` 和 `.preferred` tabbing mode。
5. 命令系统中的自定义上下文 tab 切换命令与 `WorkbenchContextWindowState` 已移除，只保留“打开当前上下文窗口”。

## Manual QA

建议按以下脚本做手工验收：

1. 从工作区打开一个文件，确认打开一个上下文窗口实例。
2. 再打开第二个文件，确认出现第二个上下文窗口实例。
3. 使用 Window > Merge All Windows，确认系统原生 window tab bar 接管，而不是应用自绘标签条。
4. 再次打开第一个文件，确认系统前置已有窗口或标签，而不是创建重复实例。
5. 打开 Git diff 和 change proposal，确认标题、副标题、represented URL 与内容路由仍正确。