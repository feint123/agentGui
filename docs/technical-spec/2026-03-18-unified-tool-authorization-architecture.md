# 2026-03-18 统一工具授权架构技术方案

日期：2026-03-18

关联对象：`ToolRegistry`、`ToolDefinition`、`ToolsetResolver`、`AppSettings`、`BackgroundAgentTask`、`BackgroundAgentLoopAdapter`、`RemoteExecutionPolicy`、`ChannelAccountBinding`、`ChannelSettingsViewModel`、`SettingsBackgroundTasksView`、`SettingsChannelsView`

## 实施状态

截至 2026-03-18，本方案尚未落地到代码，当前文档用于指导下一阶段实现与迁移。

## 0. 结论摘要

本次设计的结论如下：

1. 当前主会话、后台任务、远程渠道三条链路的工具授权模型不统一，已经出现重复裁剪 `AppSettings`、重复拼装工具列表、重复维护 UI 状态约束的问题。
2. 需要把“工具是否可用”从零散布尔开关和场景专用 policy，收敛为一套统一的授权中心，统一服务于主渠道、后台任务、远程渠道、后续工作流和桌面工具。
3. 新架构不直接废掉现有 `ToolGrant`，而是把它保留为“角色/上下文的静态上限”，再新增“执行主体级运行时授权策略”，两者与 `AppSettings` 全局开关一起参与最终求交。
4. 后台任务现有 `BackgroundTaskToolGrantPolicy` 不再保留；远程渠道现有 `RemoteExecutionPolicy` 中的工具授权字段也不再保留，统一切到共享的 `ToolAuthorizationPolicy`。
5. UI 层需要抽出一个共享的“工具权限设置组件”，第一版样式保持与后台任务当前编辑器中的“工具权限”区域一致，再复用到渠道设置页。
6. 首版以“整体工具权限控制”收口，不引入复杂逐次审批流；但底层模型必须为未来高风险工具、桌面权限、系统 TCC 检查和人工确认预留扩展点。

## 1. 背景与问题

当前代码里至少存在三套与工具授权相关、但彼此割裂的实现：

1. `AppSettings` 提供全局工具总开关，例如文本编辑、Bash、Web Search、Web Fetch、LSP。
2. 后台任务通过 `BackgroundTaskToolGrantPolicy` 单独维护 `trustTier + allowFileWrite + allowBash + allowMemoryMutation + allowNetworkAccess`，并在 `BackgroundAgentLoopAdapter` 中手写工具列表和运行时设置裁剪逻辑。
3. 远程渠道通过 `RemoteExecutionPolicy` 单独维护 `allowFileWrite + allowBash + allowNetworkTools + maxRounds`，并在 `ClaudeRemoteAgentExecutor` 中再次手写运行时设置裁剪逻辑。

这带来以下问题：

1. 同一类授权语义被定义多次，命名和边界不一致。
2. 背景任务和渠道都在重复做“把全局设置裁成当前执行上下文可用设置”的工作，容易出现漂移。
3. 工具是否可用，既依赖 `AppSettings`，又依赖场景专属 policy，还依赖 `ToolContext`，但系统没有统一的决策入口。
4. 渠道设置页还没有“整体工具权限控制”，远程消息进入后只能走默认最小能力，无法像后台任务一样做主体级授权。
5. 后续如果接入桌面操作工具、工作流代理、专用外部 specialist，这种分散方案会继续复制。

问题的根因不是后台任务或渠道各自少了几个字段，而是缺少一个统一的授权架构。

## 2. 目标

本方案目标如下：

1. 为当前渠道增加与后台任务等价的“整体工具权限控制”。
2. 定义一套统一的工具授权架构，覆盖主会话、后台任务、远程渠道、工作流 worker、子代理和未来桌面工具。
3. 收敛授权相关代码，消除后台任务与渠道各自维护工具裁剪逻辑的重复实现。
4. 保留模块化和可扩展性，使未来新增工具类别、桌面权限和审批流时不需要重做模型。
5. 抽出共享的设置 UI 组件，首版视觉和交互保持与后台任务现有“工具权限”区域一致。
6. 在迁移完成后，后台任务旧授权代码直接移除，不保留双轨逻辑。

## 3. 非目标

本次方案暂不覆盖以下内容：

1. 不在首版引入逐次工具调用审批弹窗。
2. 不在首版实现细粒度到单个文件路径、单个命令 allowlist 的高级沙箱。
3. 不在首版重构 `AppSettings` 的全局工具开关语义，它们仍保留为产品级总开关和环境前提。
4. 不在首版改变后台任务调度策略、渠道路由逻辑或消息投递协议。
5. 不在首版一次性重做所有工作流 / specialist 授权实现，但新模型必须兼容这些场景。

## 4. 设计原则

### 4.1 一套中心，多层求交

最终可用工具集合必须由统一 resolver 决定，而不是每个调用入口自己拼。决策结果来自多层上限求交，而不是单层覆盖。

### 4.2 主体授权与角色授权分离

`ToolGrant` 继续表示角色或上下文的静态能力上限；主体级配置表示某个具体执行主体实际被授予多少权限。两者职责不同，不应混在同一个模型里。

### 4.3 全局开关保留为产品级总闸

`AppSettings` 中的工具开关仍然是全局可用性总闸。主体级策略不能绕过全局关闭状态。

### 4.4 UI 复用优先于场景特化

后台任务和渠道对“整体工具权限控制”的需求高度相似，第一版应抽共享组件，避免再复制一份表单和状态约束代码。

### 4.5 为高风险工具扩展预留结构

未来桌面工具、系统自动化、网络写入、外部 specialist delegation 都属于高风险能力。即使首版只做总开关，也必须在模型层预留风险等级、系统前置条件、审批模式等扩展位。

## 5. 现状拆解

### 5.1 当前全局层

当前 `AppSettings` 已承担产品级开关：

1. `enableTextEditorTool`
2. `enableBashTool`
3. `enableWebSearchTool`
4. `enableWebFetchTool`
5. `enableLSPTools`
6. `memoryEnabled`

这一层定义的是“产品和当前环境是否允许这个能力存在”，不是“某个后台任务 / 某个渠道账号是否被授予该能力”。

### 5.2 当前后台任务层

后台任务当前使用 `BackgroundTaskToolGrantPolicy`：

1. `trustTier`
2. `allowFileWrite`
3. `allowBash`
4. `allowMemoryMutation`
5. `allowNetworkAccess`

并在 `BackgroundTaskManagementViewModel` 和 `SettingsBackgroundTasksView` 里维护一套专用表单状态、等级约束和说明文案。

### 5.3 当前渠道层

渠道当前没有独立的共享授权模型。`RemoteExecutionPolicy` 同时承载：

1. 工具权限：`allowFileWrite`、`allowBash`、`allowNetworkTools`
2. 执行预算：`maxRounds`

这导致权限和预算耦合在一起，也导致渠道设置页目前无法像后台任务一样直接配置整体工具权限。

### 5.4 当前运行时层

当前至少有两处重复的运行时裁剪逻辑：

1. `BackgroundAgentLoopAdapter.resolvedToolIDs(...)` 和 `makeRuntimeSettings(...)`
2. `ClaudeRemoteAgentExecutor.makeRuntimeSettings(...)`

两者本质都在做同一件事：

1. 读取全局设置
2. 读取场景专属授权
3. 决定哪些工具可见
4. 生成本次执行使用的运行时 settings

这正是本次需要收敛的重复点。

## 6. 统一授权架构

### 6.1 总体分层

统一授权采用四层求交模型：

1. **产品级可用性层**：来自 `AppSettings`，决定某能力在当前安装和当前用户设置下是否可存在。
2. **主体级授权层**：来自后台任务、渠道绑定、未来 workflow run、specialist session 的 `ToolAuthorizationPolicy`。
3. **角色 / 上下文上限层**：来自 `ToolGrant` 和 `ToolContext`，决定某角色在该上下文理论上能拿到哪些工具。
4. **运行时前提层**：来自系统权限、平台支持、工作目录、网络条件、审批策略等动态约束。

最终结果是四层求交后的 `EffectiveToolAuthorizationSnapshot`。

### 6.2 核心模块

建议新增以下模块：

1. `ToolAuthorizationPolicy`
2. `ToolAuthorizationResolver`
3. `EffectiveToolAuthorizationSnapshot`
4. `AuthorizedToolsetProjector`
5. `AuthorizedRuntimeSettingsFactory`
6. `ToolPermissionEditorModel`
7. `ToolPermissionSectionView`

职责如下：

#### 模块 1：`ToolAuthorizationPolicy`

职责：统一表达“某个执行主体最多能拿到什么工具能力”。

#### 模块 2：`ToolAuthorizationResolver`

职责：接收主体、上下文、角色、全局 settings、工具注册表和动态前提，输出最终授权快照。

#### 模块 3：`EffectiveToolAuthorizationSnapshot`

职责：承载最终允许的工具 ID、能力状态、禁用原因和可展示摘要。

#### 模块 4：`AuthorizedToolsetProjector`

职责：从授权快照投影出本次实际对模型暴露的 `ToolDefinition` 列表，替代后台任务和渠道各自手写拼装逻辑。

#### 模块 5：`AuthorizedRuntimeSettingsFactory`

职责：从基础 `AppSettings` 和授权快照生成本次执行的临时运行时 settings，替代多处重复的 `makeRuntimeSettings(...)`。

#### 模块 6：`ToolPermissionEditorModel`

职责：承载共享 UI 所需的等级说明、能力开关可用性、禁用原因和展示文案。

#### 模块 7：`ToolPermissionSectionView`

职责：提供共享 SwiftUI 设置区域，供后台任务编辑器和渠道设置页复用。

## 7. 统一模型设计

### 7.1 执行主体标识

建议先引入统一的执行主体类型：

```swift
enum ToolAuthorizationSubject: Hashable, Sendable {
    case mainSession(sessionID: String)
    case backgroundTask(taskID: UUID)
    case channelBinding(bindingID: UUID)
    case workflowRun(runID: UUID, roleName: String)
    case delegatedSpecialist(sessionID: UUID)
}
```

说明：

1. 授权配置最终总是归属到一个“执行主体”。
2. 背景任务和渠道都只是不同主体，不应该再各自发明一套授权概念。

### 7.2 能力维度

建议不要继续用一组分散布尔值表达长期模型，而是抽象为能力维度。

```swift
enum ToolCapabilityID: String, Codable, CaseIterable, Sendable {
    case fileSystem
    case shell
    case network
    case memory
    case lsp
    case workflowArtifacts
    case desktopObserve
    case desktopAct
}

enum ToolCapabilityLevel: String, Codable, Sendable {
    case disabled
    case observe
    case execute
    case mutate
}
```

语义约束：

1. `fileSystem.observe` 表示只读；`fileSystem.mutate` 表示允许写入。
2. `shell.execute` 表示允许执行命令。
3. `network.observe` 表示允许读取网络内容；未来若需要联网写入，可再扩展更高等级。
4. `memory.mutate` 表示允许修改 memory。
5. `desktopObserve` 和 `desktopAct` 为后续桌面工具预留。

### 7.3 授权策略对象

建议统一策略模型如下：

```swift
enum ToolAuthorizationPreset: String, Codable, CaseIterable, Sendable {
    case observeOnly
    case maintain
    case actLimited
    case custom
}

struct ToolAuthorizationPolicy: Codable, Equatable, Sendable {
    var preset: ToolAuthorizationPreset
    var capabilityLevels: [ToolCapabilityID: ToolCapabilityLevel]
    var approvalMode: ToolApprovalMode
}

enum ToolApprovalMode: String, Codable, Sendable {
    case none
    case subjectPolicy
    case alwaysRequireHuman
}
```

说明：

1. `preset` 服务于 UI 和默认值，不直接决定最终结果。
2. `capabilityLevels` 是唯一的授权事实来源。
3. `approvalMode` 首版可统一用 `none`，但模型先保留。

### 7.4 与 `ToolDefinition` 的关系

建议扩展 `ToolDefinition`，让工具自身声明需要哪些能力，而不是在 resolver 里写死工具 ID 分支。

```swift
struct ToolCapabilityRequirement: Sendable, Hashable {
    let capabilityID: ToolCapabilityID
    let minimumLevel: ToolCapabilityLevel
}

struct ToolAuthorizationDescriptor: Sendable {
    let requirements: [ToolCapabilityRequirement]
    let riskTier: ToolRiskTier
}

enum ToolRiskTier: String, Codable, Sendable {
    case low
    case medium
    case high
}
```

并在 `ToolDefinition` 上新增：

```swift
let authorization: ToolAuthorizationDescriptor
```

示例映射：

1. `str_replace_based_edit_tool` 需要 `fileSystem.mutate`
2. `bash` 需要 `shell.execute`
3. `web_search` / `web_fetch` 需要 `network.observe`
4. LSP 工具需要 `lsp.observe`
5. 未来桌面截图需要 `desktopObserve.observe`
6. 未来桌面点击 / 输入需要 `desktopAct.execute`

### 7.5 与 `ToolGrant` 的关系

`ToolGrant` 不删除，但职责收窄为“角色静态上限”。

最终决策关系如下：

1. `ToolGrant` 决定该角色 / 上下文理论上有哪些工具组。
2. `ToolAuthorizationPolicy` 决定当前主体是否真的被授予这些能力。
3. `AppSettings` 决定全局是否启用。
4. `ToolDefinition.authorization` 决定单个工具需要的最低能力。

换句话说：

`ToolGrant` 解决“这类 agent 能不能碰这个工具”，`ToolAuthorizationPolicy` 解决“这次执行给不给它碰”。

## 8. 统一决策流程

建议把授权决策流程统一为：

1. 根据执行入口拿到 `ToolAuthorizationSubject`。
2. 读取该主体的 `ToolAuthorizationPolicy`。
3. 读取 `AppSettings` 全局工具总开关。
4. 读取上下文和角色约束，例如 `ToolContext.backgroundTask`、`ToolContext.mainAgent`、`WorkflowRoleDefinition.toolGrants`。
5. 遍历 `ToolRegistry` 中所有候选工具。
6. 按 `ToolDefinition.authorization` 校验能力是否满足。
7. 叠加运行时前提，例如系统权限、是否允许网络、工作目录是否存在。
8. 产出 `EffectiveToolAuthorizationSnapshot`。
9. 由 `AuthorizedToolsetProjector` 输出工具列表。
10. 由 `AuthorizedRuntimeSettingsFactory` 输出执行时 settings 投影。

建议快照结构如下：

```swift
struct EffectiveToolAuthorizationSnapshot: Sendable {
    let subject: ToolAuthorizationSubject
    let context: ToolContext
    let allowedToolIDs: Set<String>
    let deniedToolReasons: [String: ToolAuthorizationDenialReason]
    let capabilityLevels: [ToolCapabilityID: ToolCapabilityLevel]
}

enum ToolAuthorizationDenialReason: Sendable, Equatable {
    case globallyDisabled
    case subjectPolicyDenied
    case contextUnsupported
    case roleGrantMissing
    case runtimePrerequisiteMissing
}
```

这样：

1. UI 可以展示为什么某能力不可用。
2. 时间线和日志可以记录更清晰的失败原因。
3. 后续加桌面权限、审批要求时可以沿用同一机制。

## 9. 预设策略设计

### 9.1 首版共享预设

后台任务和渠道第一版共享同一套预设：

1. `Observe Only`
2. `Maintain`
3. `Act Limited`

默认能力矩阵建议如下：

1. `Observe Only`
   - `fileSystem = .disabled`
   - `shell = .disabled`
   - `network = .observe`
   - `memory = .disabled`
   - `lsp = .disabled`
2. `Maintain`
   - `fileSystem = .disabled`
   - `shell = .disabled`
   - `network = .observe`
   - `memory = .mutate`
   - `lsp = .disabled`
3. `Act Limited`
   - `fileSystem = .mutate`
   - `shell = .execute`
   - `network = .observe`
   - `memory = .mutate`
   - `lsp = .disabled`

说明：

1. 第一版保留与后台任务现有语义一致的三档结构，降低迁移成本。
2. 渠道默认建议落在 `Observe Only`。
3. `custom` 仅在用户手动改动预设矩阵时出现。

### 9.2 共享 UI 中的开关映射

第一版共享组件保留当前后台任务表单的认知方式：

1. 信任等级 Picker
2. `允许文件写入`
3. `允许 Bash`
4. `允许修改记忆`
5. `允许联网工具`

但这些开关不再直接绑定 `BackgroundTaskToolGrantPolicy`，而是绑定 `ToolPermissionEditorModel` 对 `ToolAuthorizationPolicy.capabilityLevels` 的映射。

这样可以兼顾：

1. 首版 UI 不打断现有使用习惯。
2. 底层模型从布尔字段升级为统一能力矩阵。

## 10. UI 与交互设计

### 10.1 共享组件

建议新增共享组件：

1. `ToolPermissionSectionView`
2. `ToolPermissionEditorModel`

组件职责：

1. 显示预设 Picker
2. 显示文案说明
3. 显示能力开关
4. 自动处理不同预设下的禁用规则
5. 输出最终 `ToolAuthorizationPolicy`

### 10.2 后台任务页面迁移

`SettingsBackgroundTasksView` 中现有 `toolsSection` 不再直绑 `draftToolGrantPolicy`，改为使用共享组件。

迁移后页面效果要求：

1. 标题仍为“工具权限”
2. 预设和开关排布保持与当前后台任务样式一致
3. 原有说明文案可直接迁入共享 `ToolPermissionEditorModel`

### 10.3 渠道页面新增

`SettingsChannelsView` 在飞书配置区域新增一段“工具权限”设置，样式与后台任务一致。

第一版建议放在渠道基本信息之后、保存按钮之前，内容包括：

1. 信任等级 Picker
2. 文件写入开关
3. Bash 开关
4. 记忆写入开关
5. 联网工具开关

说明：

1. 渠道页需要的是“总的工具权限控制”，不是逐条消息审批。
2. 首版先只控制整条远程渠道的执行上限，不细分到联系人级别。

## 11. 持久化设计

### 11.1 后台任务

`BackgroundAgentTask` 中：

1. 删除 `toolGrantPolicyJSON`
2. 新增 `authorizationPolicyJSON`
3. 对外暴露 `authorizationPolicy: ToolAuthorizationPolicy`

理由：

1. 背景任务旧模型不再保留。
2. 新字段语义更准确，也便于未来扩展桌面能力和审批模式。

### 11.2 渠道绑定

`ChannelAccountBinding` 中：

1. 新增 `authorizationPolicyJSON`
2. 保持 `settingsJSON` 继续承载渠道适配器私有配置

理由：

1. 工具授权属于跨渠道共性能力，不应塞进 adapter 私有 `settingsJSON`。
2. 单独字段更利于共享 ViewModel、迁移和查询。

### 11.3 执行预算解耦

`RemoteExecutionPolicy` 不再承载工具授权字段，建议拆成：

1. `RemoteExecutionBudget`：例如 `maxRounds`
2. `ToolAuthorizationPolicy`：统一工具授权

这样渠道层的“预算”和“授权”会回归两个独立概念。

## 12. 运行时落地方案

### 12.1 替换后台任务的工具解析

`BackgroundAgentLoopAdapter` 不再直接读取 `BackgroundTaskToolGrantPolicy`，改为：

1. 根据 `task.authorizationPolicy`
2. 调用 `ToolAuthorizationResolver`
3. 通过 `AuthorizedToolsetProjector` 构建工具列表
4. 通过 `AuthorizedRuntimeSettingsFactory` 构建运行时 settings

原有：

1. `resolvedToolIDs(task:settings:)`
2. `makeRuntimeSettings(task:settings:)` 中的专属工具裁剪逻辑

都应被替换为共享实现。

### 12.2 替换渠道的工具解析

`ClaudeRemoteAgentExecutor` 不再根据 `RemoteExecutionPolicy.allowFileWrite / allowBash / allowNetworkTools` 手工裁剪 settings，而是：

1. 从 `ChannelAccountBinding.authorizationPolicy` 读取授权配置
2. 结合 `RemoteExecutionBudget` 和全局 settings
3. 调用同一套 resolver / projector / factory

### 12.3 主会话与未来工作流接入

首版可以先不全面改造主会话，但新架构必须允许后续逐步接入：

1. 主会话可拥有默认主体授权
2. 工作流 worker 可在 `ToolGrant` 之外叠加主体授权
3. specialist delegation 可复用相同的快照产物

## 13. 兼容桌面工具的扩展设计

虽然本次实现目标是“渠道整体工具权限 + 背景任务统一迁移”，但模型必须直接兼容桌面工具接入。

因此建议在能力矩阵中预留：

1. `desktopObserve`
2. `desktopAct`

后续桌面工具可直接接入统一架构：

1. `desktopObserve` 对应截图、枚举窗口、读取前台状态
2. `desktopAct` 对应点击、输入、滚动、窗口激活
3. 运行时前提层再叠加 macOS 屏幕录制、辅助功能、自动化权限检查

这样桌面工具不会再成为第四套独立授权体系。

## 14. 迁移计划

建议按以下步骤迁移：

### 阶段 1：引入统一模型与共享 UI

1. 新增 `ToolAuthorizationPolicy`、`ToolAuthorizationResolver`、`AuthorizedRuntimeSettingsFactory`
2. 新增共享 `ToolPermissionSectionView`
3. 先让后台任务 UI 改用共享组件，但内部仍可双读旧字段做过渡

### 阶段 2：后台任务切换到统一策略

1. `BackgroundAgentTask` 改持久化 `authorizationPolicy`
2. `BackgroundTaskManagementViewModel` 改用共享编辑模型
3. `BackgroundAgentLoopAdapter` 切到统一 resolver
4. 删除 `BackgroundTaskToolGrantPolicy.swift`

### 阶段 3：渠道接入统一策略

1. `ChannelAccountBinding` 新增 `authorizationPolicy`
2. `SettingsChannelsView` 接入共享权限组件
3. `RemoteExecutionPolicy` 拆出预算字段
4. `ClaudeRemoteAgentExecutor` 切到统一 resolver

### 阶段 4：清理冗余与补齐测试

1. 删除后台任务旧信任等级归一化逻辑
2. 删除渠道旧布尔字段裁剪逻辑
3. 为 resolver、factory、UI 组件补齐单元测试和集成测试

## 15. 测试要求

至少补齐以下测试：

1. `ToolAuthorizationResolverTests`
   - 全局关闭时工具不可用
   - 主体策略拒绝时工具不可用
   - `ToolGrant` 缺失时工具不可用
   - 动态前提缺失时返回正确拒绝原因
2. `AuthorizedRuntimeSettingsFactoryTests`
   - 后台任务与渠道共用同一投影逻辑
   - 文件写入、Bash、网络、记忆开关投影正确
3. `BackgroundTaskManagementViewModelTests`
   - 迁移后仍保留原有预设约束与说明文案行为
4. `ChannelSettingsViewModelTests`
   - 渠道授权策略能正确加载、保存和回填
5. UI / 快照测试
   - 后台任务与渠道页面中的共享权限组件渲染一致

## 16. 风险与注意事项

### 16.1 不要让共享模型重新退化成场景特化

如果共享模型底层仍然只是“后台任务字段名换个壳”，后续接桌面工具或 specialist 时仍会再次分叉。因此底层必须以“能力矩阵”建模，而不是仅复制布尔字段。

### 16.2 不要把预算和授权混在一起

`maxRounds`、调度周期、QoS 之类属于预算或执行策略，不属于工具授权。模型边界必须在这次切清楚。

### 16.3 不要让渠道绕过全局总闸

即使渠道主体授权允许文件写入，只要全局 `AppSettings.enableTextEditorTool` 关闭，最终结果也必须拒绝。

### 16.4 不要保留后台任务双轨逻辑太久

既然目标是收敛冗余代码，后台任务旧授权代码不应长期保留兼容层。完成数据迁移和测试后应直接删除旧实现。

## 17. 建议的落地命名

为了减少后续重命名成本，建议直接采用以下命名：

1. `ToolAuthorizationPolicy`
2. `ToolAuthorizationPreset`
3. `ToolAuthorizationResolver`
4. `EffectiveToolAuthorizationSnapshot`
5. `AuthorizedToolsetProjector`
6. `AuthorizedRuntimeSettingsFactory`
7. `ToolPermissionEditorModel`
8. `ToolPermissionSectionView`

## 18. 最终方案总结

最终建议如下：

1. 以 `ToolAuthorizationPolicy` 作为唯一主体级授权模型，替代后台任务和渠道各自维护的专用工具授权字段。
2. 以 `ToolAuthorizationResolver + AuthorizedToolsetProjector + AuthorizedRuntimeSettingsFactory` 收敛运行时裁剪逻辑，消除重复实现。
3. `ToolGrant` 保留为角色静态上限，和主体授权、全局设置、运行时前提共同参与求交。
4. 抽共享 `ToolPermissionSectionView`，首版样式保持与当前后台任务的工具权限区域一致，并复用到渠道设置页。
5. 后台任务旧授权代码在迁移完成后直接删除，不保留旧方案。
6. 新架构从第一天就兼容未来桌面工具、specialist delegation 和更细粒度审批需求。