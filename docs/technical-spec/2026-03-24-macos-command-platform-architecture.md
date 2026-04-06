# 2026-03-24 macOS 键盘优先 Commands 平台技术设计

日期：2026-03-24

关联对象：`agentGuiApp`、`SettingsMenuCommands`、`WorkspaceMenuCommands`、`StudioMenuCommands`、`WorkbenchSceneServices`、`WorkspaceState`、`WorkbenchState`、`WorkbenchContextWindowState`、`WorkbenchShellView`、`SessionListView`、`WorkspacePanelView`

## 0. 文档结论

agentGui 当前已经有少量应用级 Commands，但它们仍是“直接在 `Commands` 里写按钮动作”的点状实现。这个模式适合设置、开始使用、打开工作区这类单点入口，不适合继续扩展成一个符合桌面产品预期的键盘优先命令体系。

本次设计的核心结论是：

1. Commands 不应继续以菜单组为中心扩展，而应升级为“命令描述 + 场景上下文 + 执行路由 + 多入口呈现”的平台层。
2. app 级命令注册仍保留在 `agentGuiApp`，但 `agentGuiApp` 只负责组合，不再直接承载业务动作。
3. 所有命令统一抽象成 `AppCommandDescriptor`，由 `CommandRouter` 基于前台窗口上下文决定可用性、标题、执行方式与快捷键。
4. 菜单栏、命令面板、快速打开、最近工作区、最近会话，本质上都应复用同一套命令元数据与路由层，而不是分别手写一套逻辑。
5. 对现有代码，最关键的复用点已经存在：
   1. `WorkspaceState` 负责当前会话、文件、工作目录与 detail selection。
   2. `WorkbenchState` 负责左侧主面板切换。
   3. `WorkbenchContextWindowState` 负责上下文窗口和 tab。
   4. `SessionListView` / `SessionCatalogViewModel` 已经提供了会话查询与筛选基础。
6. 推荐先落一套“可编排命令平台”，再分阶段接入命令面板、快速会话切换、快速打开文件、最近工作区等具体能力。

一句话概括：

> agentGui 需要从“零散菜单项”升级为“面向前台场景的统一命令平台”，让菜单、快捷键、快速切换和命令面板共享同一套命令模型。

## 1. 背景与问题定义

当前应用级 Commands 主要集中在以下几类：

1. 设置与开始使用。
2. 打开/切换工作区。
3. 打开 Agent 工作室。

这些命令已经注册进 app，但范围明显偏窄：

1. 没有针对主工作台的全局会话切换入口。
2. 没有针对左侧主面板的全局切换能力。
3. 没有统一命令面板，用户无法用键盘检索动作。
4. 没有最近工作区、最近会话入口。
5. 没有“打开指定对话/文件”的统一入口。
6. 菜单栏组织仍偏工程实现导向，缺少用户任务导向的结构。

从桌面产品预期看，这会带来三个直接问题：

1. 键盘路径断裂。用户能发送消息，但不能高频切换对象。
2. 发现性差。很多已有能力只存在于局部按钮或上下文菜单里。
3. 后续扩展成本高。每增加一个命令，都要决定它属于哪个 `Commands` 结构、怎么拿状态、如何避免重复逻辑。

## 2. 现状分析

### 2.1 当前命令注册模式的结构问题

当前 `agentGuiApp` 注册的 Commands 是静态组合：

1. `WorkspaceMenuCommands`
2. `SettingsMenuCommands`
3. `StudioMenuCommands`

这个结构本身没有错，但问题在于它们直接把菜单项和动作绑死在一起：

1. 命令没有统一 ID。
2. 命令没有统一可用性判断。
3. 命令无法复用于命令面板或快速打开。
4. 命令的标题、快捷键、启用条件不能被统一检索。

### 2.2 现有状态模型其实已经适合承接命令平台

工作台状态已经被分成三层：

1. `WorkspaceState`：当前会话、当前文件、Git diff、变更提案、工作目录。
2. `WorkbenchState`：左侧当前主面板。
3. `WorkbenchContextWindowState`：上下文窗口 tab 与聚焦状态。

这说明命令执行时需要的绝大多数状态，并不在某个局部 View 内，而是已经具备“前台场景上下文”的雏形。

### 2.3 已有数据基础可支持最近项与快速打开

1. `Session` 已有 `updatedAt`，天然适合最近会话排序。
2. `SessionCatalogViewModel` 已经具备搜索过滤基础。
3. `WorkspaceState` 已有当前工作目录与当前打开文件。
4. `WorkspacePanelView` / `WorkspaceTreeViewModel` 已有工作区文件树与搜索行为。

也就是说，问题不是“没有数据”，而是“没有一层把这些数据组织成全局命令体验的中台”。

## 3. 设计目标

本次设计目标如下：

1. 建立统一的命令模型，使菜单、快捷键、命令面板、快速切换入口复用同一套描述。
2. 所有命令都能基于前台 scene 上下文做启用/禁用和执行路由。
3. 支持首批高频入口：
   1. 快速切换会话。
   2. 快速切换左侧面板。
   3. 全局命令面板。
   4. 最近工作区。
   5. 最近会话。
   6. 打开指定对话/文件。
   7. 常用操作菜单栏入口。
4. 让 `agentGuiApp` 中的 Commands 组合保持简洁，避免持续膨胀。
5. 新命令可以按功能域追加，而不是继续向单个文件堆积。
6. 保持方案对 SwiftUI App 生命周期友好，不引入过重的 AppKit 菜单黑科技。

## 4. 非目标

本次设计不把以下内容作为第一阶段目标：

1. 不追求做成完整 IDE 级快捷键系统。
2. 不在第一阶段引入用户可自定义快捷键。
3. 不要求所有局部操作都立即升级为全局命令。
4. 不要求一次性把所有视图的按钮动作都迁入平台层。
5. 不要求支持跨 app 的系统级全局热键。

这里的目标是“app 内统一 Commands 平台”，不是“系统级热键守护进程”。

## 5. 方案比选

### 5.1 方案 A：继续沿用按菜单组零散扩展

做法：继续新增 `SessionMenuCommands`、`WindowMenuCommands`、`NavigationMenuCommands` 等结构，并在各自内部直接调用状态或服务。

优点：

1. 改动小。
2. 学习成本低。

缺点：

1. 命令逻辑会分散到多个 `Commands` 文件。
2. 命令面板无法直接复用。
3. 最近项、快速打开这类“不是纯菜单项”的能力仍要另起一套系统。
4. 可用性判断与命令检索无法统一。

结论：不采纳。

### 5.2 方案 B：做一个巨型 `CommandCenter`

做法：所有命令、菜单、最近项、命令面板、执行逻辑都塞进单个中心对象。

优点：

1. 所有逻辑集中。
2. 初期实现速度快。

缺点：

1. 很快会变成新的 God Object。
2. 前台窗口上下文与持久化、菜单、视图弹窗会耦合在一起。
3. 单元测试会越来越重。

结论：不采纳。

### 5.3 方案 C：分层命令平台

做法：将命令体系拆成描述层、上下文层、路由层、呈现层、索引层，并按功能域拆分模块。

优点：

1. 可扩展。
2. 菜单与命令面板共享命令元数据。
3. 前台上下文与执行器可独立测试。
4. 能自然承接最近项与快速打开。

缺点：

1. 设计成本高于继续堆菜单。
2. 需要先建立平台骨架，再逐步迁移命令。

结论：推荐采用。

## 6. 推荐架构

## 6.1 分层概览

推荐将命令体系拆成五层：

1. 命令描述层：定义命令是什么。
2. 上下文层：定义当前前台窗口能做什么。
3. 路由执行层：决定命令由谁执行。
4. 呈现层：菜单栏、命令面板、快速打开等 UI 入口。
5. 索引层：最近工作区、最近会话、文件检索、命令搜索。

目标结构示意：

```text
AppCommands/
  Core/
    AppCommandID.swift
    AppCommandDescriptor.swift
    AppCommandAvailability.swift
    AppCommandContext.swift
    AppCommandRouter.swift
    AppCommandRegistry.swift
  Modules/
    AppMenuCommands.swift
    WorkspaceCommands.swift
    SessionCommands.swift
    NavigationCommands.swift
    WindowCommands.swift
    RecentCommands.swift
  Palette/
    CommandPaletteWindowScene.swift
    CommandPaletteView.swift
    CommandPaletteViewModel.swift
    QuickOpenProvider.swift
  Indexes/
    RecentWorkspaceStore.swift
    RecentSessionProvider.swift
    WorkspaceFileSearchIndex.swift
```

### 6.2 命令描述层

所有命令都抽象成统一描述对象：

```swift
struct AppCommandDescriptor: Identifiable, Sendable {
    let id: AppCommandID
    let title: String
    let category: AppCommandCategory
    let menuPlacement: AppCommandMenuPlacement?
    let shortcut: AppCommandShortcut?
    let keywords: [String]
    let requirement: AppCommandRequirement
    let performer: AppCommandPerformer
}
```

关键点：

1. `id` 稳定，不依赖菜单文字。
2. `category` 用于命令面板分组与排序。
3. `menuPlacement` 决定是否出现在菜单栏及其位置。
4. `requirement` 用于判断是否需要前台 workbench、是否要求存在选中会话、是否要求存在工作目录等。
5. `performer` 不直接持有 View，而是路由到上下文执行器。

### 6.3 前台命令上下文层

命令不能直接抓全局单例，它必须感知“当前聚焦的是哪个 scene”。推荐新增：

```swift
@MainActor
struct AppCommandContext {
    let workspaceState: WorkspaceState?
    let workbenchState: WorkbenchState?
    let contextWindowState: WorkbenchContextWindowState?
    let modelContext: ModelContext?
    let openWindow: OpenWindowAction?
    let focusedScene: AppFocusedSceneKind
}
```

并通过 `FocusedValue` 或 `FocusedSceneValue` 从 `WorkbenchShellView` 暴露给命令系统。

这样做的原因：

1. 菜单项需要基于前台窗口启用/禁用。
2. 命令面板也需要知道执行目标是前台工作台，还是设置窗口，还是工作室窗口。
3. 多窗口下必须避免“用户在 A 窗口按快捷键，却修改了 B 窗口状态”。

### 6.4 路由执行层

推荐引入 `AppCommandRouter`：

1. 接收 `AppCommandID` 与可选 payload。
2. 从当前 `AppCommandContext` 解析执行器。
3. 做统一的可用性判断与失败兜底。

例如：

1. `switchToSessionsPanel` 只需要 `WorkbenchState`。
2. `openRecentWorkspace` 需要 `WorkspaceState`、`ModelContext` 和 `PersistenceCoordinator`。
3. `openCommandPalette` 只需要 `openWindow`。
4. `openFileQuickOpen` 需要工作目录可用，且需要文件索引服务。

执行结果建议统一返回：

```swift
enum AppCommandResult {
    case performed
    case disabled(reason: String)
    case failed(message: String)
}
```

这让菜单验证、命令面板反馈、测试断言都能共享一套结果模型。

### 6.5 呈现层

呈现层不再拥有业务动作，只负责把 descriptor 绑定成 UI。

建议拆成三类入口：

1. 菜单栏 Commands。
2. 命令面板。
3. 快速打开 / 快速切换浮层。

其中：

1. 菜单栏适合高频、稳定、可发现的动作。
2. 命令面板适合检索全部动作。
3. 快速打开适合对象导航，例如会话、文件、最近工作区。

### 6.6 索引层

快速打开和最近项不是菜单问题，而是索引问题。推荐单独做三类 provider：

1. `RecentWorkspaceStore`
2. `RecentSessionProvider`
3. `WorkspaceFileSearchIndex`

其中：

1. 最近工作区需要持久化，并优先存安全书签或标准化路径。
2. 最近会话可直接从 `Session.updatedAt` 生成，不需要第一阶段新增持久化表。
3. 文件快速打开使用当前工作目录构建轻量索引，必要时增量刷新。

## 7. 首期命令域设计

推荐将命令按功能域组织，而不是按菜单位置组织。

### 7.1 App 域

包含：

1. 打开设置。
2. 打开开始使用。
3. 显示 Agent 工作室。
4. 打开命令面板。

### 7.2 Workspace 域

包含：

1. 打开/切换工作区。
2. 打开最近工作区。
3. 重新载入当前工作区文件索引。
4. 快速打开文件。

### 7.3 Session 域

包含：

1. 新建对话。
2. 快速切换会话。
3. 打开最近会话。
4. 复制当前会话为本地会话。
5. 删除当前会话。

### 7.4 Navigation 域

包含：

1. 切换到会话面板。
2. 切换到工作区面板。
3. 切换到 Git 面板。
4. 切换到 LSP 面板。
5. 切换到 Skills 面板。
6. 切换到 Diagnostics 面板。
7. 下一个面板。
8. 上一个面板。

### 7.5 Window / Context 域

包含：

1. 打开当前上下文窗口。
2. 选择下一个上下文 tab。
3. 选择上一个上下文 tab。
4. 关闭当前上下文 tab。

## 8. 菜单栏信息架构

当前菜单栏偏“已有按钮往菜单搬”，推荐改成用户任务导向结构。

### 8.1 File

建议包含：

1. 打开/切换工作区。
2. 打开最近工作区。
3. 快速打开文件。
4. 新建对话。

### 8.2 Go

建议新增 `Go` 菜单，承接高频导航：

1. 命令面板。
2. 快速切换会话。
3. 最近会话。
4. 会话面板 / 工作区面板 / Git / LSP / Skills / Diagnostics。
5. 下一个面板 / 上一个面板。
6. 打开当前上下文窗口。

### 8.3 Window

建议保留并补充：

1. 显示 Agent 工作室。
2. 设置。
3. 开始使用。
4. 命令面板窗口。

## 9. 首期快捷键建议

快捷键需要兼顾 macOS 习惯、冲突风险和学习成本。建议首期如下：

1. `Command + ,`：设置。
2. `Command + O`：打开/切换工作区。
3. `Command + Shift + P`：命令面板。
4. `Command + P`：快速打开文件。
5. `Command + J`：快速切换会话。
6. `Command + 1 ... 6`：切换左侧主面板。
7. `Control + Tab`：下一个左侧主面板。
8. `Control + Shift + Tab`：上一个左侧主面板。
9. `Command + Shift + O`：最近会话。
10. `Command + Option + O`：最近工作区。

说明：

1. `Command + Shift + P` 与 `Command + P` 的组合对键盘用户认知负担最低。
2. `Command + 1...6` 能让左侧面板切换具备稳定肌肉记忆。
3. 最近工作区和最近会话也可以没有独立快捷键，只作为命令面板与菜单二级入口，避免首期快捷键过载。

## 10. 命令面板设计

### 10.1 定位

命令面板是“动作检索器”，不是“对象打开器”的简单复制。它应优先列出命令，而不是文件。

建议采用独立窗口 scene 或 utility panel，而不是深度绑定到单一 View overlay。原因是：

1. 真正的 app 级入口应在前台任意窗口都可用。
2. 独立 scene 更容易处理焦点与 Escape 关闭。
3. 后续可以扩展为多 provider 搜索，而不用重构为跨窗口浮层。

### 10.2 数据源

命令面板首期只检索两类结果：

1. `Commands`
2. `Navigation targets`

第二阶段再扩展：

1. 最近工作区。
2. 最近会话。
3. 文件。

为了避免“一个入口塞所有东西导致排序失真”，建议 provider 采用分组展示，而不是把所有候选混成一个列表。

### 10.3 结果模型

建议统一为：

```swift
struct QuickActionItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let group: QuickActionGroup
    let keywords: [String]
    let action: () -> AppCommandResult
}
```

这样命令面板和快速打开可以共用一套列表渲染骨架，但 provider 不同。

## 11. 最近项与快速打开设计

### 11.1 最近工作区

推荐新增 `RecentWorkspaceStore`，职责如下：

1. 在工作区切换成功后记录路径。
2. 去重并按最近访问时间排序。
3. 保留固定上限，例如 20 条。
4. 记录可展示名称、标准化路径、最近访问时间。

持久化建议：

1. 第一阶段可存入 `AppSettings` 的 JSON 字段。
2. 若后续需要 pin、标签、书签恢复，再升级成独立 SwiftData 模型。

### 11.2 最近会话

最近会话不需要新增模型。直接基于：

1. `Session.updatedAt` 倒序。
2. 过滤不可见或已删除对象。
3. 取前 N 条用于菜单和命令面板。

### 11.3 打开指定文件

快速打开文件不应直接复用 `WorkspacePanelView` 的树视图状态，而应有独立 provider：

1. 根据当前有效工作目录扫描相对路径。
2. 建立轻量文件索引。
3. 提供模糊匹配。
4. 结果执行时调用 `workspaceState.showFileDetail(...)`。

这么做的好处是：

1. 不依赖左侧工作区面板当前是否可见。
2. 不依赖树视图当前搜索状态。
3. 可以天然接入 `Command + P`。

## 12. 与现有代码的映射关系

### 12.1 `agentGuiApp` 只保留组合职责

改造后 `agentGuiApp` 应类似：

```swift
.commands {
    AppCommandsRoot()
}
```

`AppCommandsRoot` 内部再组合：

1. `AppCoreCommands`
2. `WorkspaceCommands`
3. `SessionCommands`
4. `NavigationCommands`
5. `WindowCommands`
6. `RecentCommands`
7. `StudioMenuCommands`

### 12.2 `WorkbenchShellView` 负责发布前台上下文

`WorkbenchShellView` 作为主工作台容器，是最适合发布 focused command context 的位置。它已经持有：

1. `WorkspaceState`
2. `WorkbenchState`
3. `WorkbenchContextWindowState`
4. `ModelContext`

这意味着它天然就是命令平台的“前台场景桥接点”。

### 12.3 `WorkspaceState` / `WorkbenchState` 是命令执行的主目标

推荐保持现有状态边界：

1. 面板切换只修改 `WorkbenchState.selectedItem`。
2. 会话切换、文件打开、工作区切换只修改 `WorkspaceState` 或持久化设置。
3. 上下文窗口 tab 切换只走 `WorkbenchContextWindowState`。

这样平台层不会把业务状态重新封装一遍，避免重复中间状态。

## 13. 推荐落地阶段

### 13.1 Phase 1：平台骨架

交付内容：

1. `AppCommandDescriptor` / `AppCommandID` / `AppCommandRouter`
2. `AppCommandContext`
3. `AppCommandsRoot`
4. 现有设置、开始使用、工作区、工作室命令迁入新平台

目标：先把命令注册方式统一。

### 13.2 Phase 2：导航与高频快捷键

交付内容：

1. 左侧面板切换命令。
2. 新建/删除/复制会话命令。
3. 上下文窗口命令。
4. `Go` 菜单。

目标：先解决最明显的键盘断层。

### 13.3 Phase 3：命令面板与快速打开

交付内容：

1. 命令面板窗口 scene。
2. 会话快速切换 provider。
3. 文件快速打开 provider。
4. 最近工作区 / 最近会话 provider。

目标：形成统一检索入口。

### 13.4 Phase 4：排序与个性化

交付内容：

1. 最近使用频率排序。
2. 搜索打分优化。
3. 可能的用户自定义快捷键预留。

目标：从“可用”升级到“顺手”。

## 14. 测试策略

### 14.1 单元测试

重点覆盖：

1. 命令 descriptor 注册完整性。
2. `AppCommandRouter` 的 requirement 判断。
3. `RecentWorkspaceStore` 的去重、排序、上限裁剪。
4. 最近会话 provider 的排序和过滤。
5. 面板切换命令对 `WorkbenchState` 的正确修改。

### 14.2 集成测试

重点覆盖：

1. 前台 workbench scene 下执行命令是否命中正确上下文。
2. 设置窗口或工作室窗口为前台时，工作台专属命令是否被禁用。
3. 工作区切换后最近工作区是否更新。
4. 快速打开文件是否正确打开 editor detail。

### 14.3 UI 测试

重点覆盖：

1. 菜单项是否出现于预期菜单组。
2. 快捷键能否触发对应动作。
3. 命令面板打开、检索、回车执行、Escape 关闭。
4. 会话快速切换是否更新主聊天面板。

## 15. 风险与对策

### 15.1 快捷键冲突

风险：新快捷键可能与现有局部快捷键、系统默认行为或文本输入习惯冲突。

对策：

1. 首期只给高频稳定动作分配快捷键。
2. 其余动作优先走命令面板与菜单。
3. 将快捷键定义集中管理，避免散落在视图内部。

### 15.2 多窗口上下文错路由

风险：命令可能误操作非前台工作台状态。

对策：

1. 必须使用 focused scene context。
2. 对需要 workbench context 的命令做显式 requirement 校验。

### 15.3 快速打开性能问题

风险：工作区大时，文件扫描和模糊匹配可能拖慢体验。

对策：

1. 首期使用异步索引与增量缓存。
2. 限制一次展示的候选结果数量。
3. 扫描逻辑与 UI 输入解耦。

## 16. 最终建议

推荐采用“分层命令平台”方案，并按以下顺序推进：

1. 先收敛命令模型和前台上下文模型。
2. 再把 `agentGuiApp` 的 Commands 改成平台式组合。
3. 然后补齐左侧面板切换、会话切换和上下文窗口命令。
4. 最后接入命令面板、最近项和快速打开。

这个顺序的价值在于：

1. 能先解决结构性扩展问题，而不是继续堆菜单项。
2. 后续任何新命令都能自然进入菜单栏、快捷键和命令面板。
3. 方案与现有 `WorkspaceState` / `WorkbenchState` / `WorkbenchContextWindowState` 高度兼容，不需要推翻当前工作台结构。

结论上，agentGui 下一步不应该只是“再加几组 Commands”，而应该正式引入一个面向 macOS 键盘优先工作流的命令平台。

## 17. 当前实现状态

截至 2026-03-24，本设计的一阶段到三阶段主体已经落地，范围如下：

1. 已完成命令平台核心骨架：
  1. `AppCommandID`
  2. `AppCommandDescriptor`
  3. `AppCommandAvailability`
  4. `AppCommandContext`
  5. `AppCommandRequirement`
  6. `AppCommandRegistry`
  7. `AppCommandRouter`
2. 已完成前台 scene 上下文桥接：
  1. `WorkbenchShellView` 发布 focused command context。
  2. `WorkbenchContextWindowView` 发布 focused command context。
  3. `WorkbenchSceneServices` 负责构建命令执行上下文。
3. 已完成菜单模块化迁移：
  1. `AppMenuCommands`
  2. `WorkspaceCommands`
  3. `NavigationCommands`
  4. `WindowCommands`
  5. `RecentCommands`
4. 已完成命令面板与快速打开首版：
  1. 独立命令面板 window scene。
  2. 命令检索。
  3. 最近工作区。
  4. 最近会话。
  5. 当前工作区文件快速打开。
5. 已完成的高频命令能力包括：
  1. 设置、开始使用、Agent 工作室。
  2. 打开或切换工作区。
  3. 命令面板打开。
  4. 左侧主面板切换。
  5. 上下文窗口与上下文 tab 导航。
  6. 相邻会话切换。

当前尚未覆盖的内容如下：

1. 用户自定义快捷键。
2. 最近使用频率排序与更复杂的搜索打分。
3. 更完整的 Session 域命令迁移，例如新建、删除、复制等全部统一收敛进平台。

当前验证状态如下：

1. 命令核心、上下文桥接、菜单迁移相关单元测试已通过。
2. 新增命令平台代码已完成编译级修正，并通过聚焦测试持续收敛问题。
3. UI 测试按实现约束未执行。

这意味着本文档中的推荐架构已经不再只是设计提案，而是已成为当前 macOS 命令系统的实际落地方向；后续工作应继续围绕命令域补齐、排序优化和可定制性增强推进，而不是回退到零散菜单项实现。