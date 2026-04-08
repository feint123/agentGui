# Dynamic ACP Provider Design

**Goal:** Remove the hard-coded GitHub Copilot, OpenCode, and Claude Code ACP provider definitions and replace them with a dynamic, modular ACP provider system driven by settings and runtime capability discovery.

**Architecture:** Keep the ACP transport, runtime lifecycle, permission bridge, event normalization, and session projection as shared infrastructure. Replace provider-specific identity, settings storage, availability probing, and registry assembly with a first-class dynamic provider profile model plus a provider catalog service that constructs external ACP providers from persisted profiles at runtime.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, existing ACP runtime stack, existing ConversationExecutionProvider orchestration, existing ACP initialize and session APIs.

---

## 1. 背景与问题定义

当前仓库里的外部 ACP 执行链路已经基本共享：ACP wire model、stdio transport、initialize or session load or session new、permission bridge、session update 归一化、UI 投影、session binding、runtime isolation 都已经位于通用层。真正仍然被写死的是 provider 身份层。

当前硬编码主要体现在以下几个方面：

- 外部 provider ID 被固定在 `ConversationExecutionProviderID` 枚举里。
- `AppSettings` 为三种 ACP CLI 分别保存三段 JSON 配置。
- `SessionExecutionPreferences` 为三种 ACP provider 分别保存一套会话偏好字段。
- `SettingsStore` 和 `SettingsExecutorsView` 维护三套 availability 状态和三组表单。
- `ConversationExecutionProviderRegistry`、`ClaudeService+Messaging` 和新会话菜单直接实例化三种 provider。
- Chat 侧的可发送性检查、选择器、slash commands、配置面板全部依赖固定枚举分支。

这会带来三个直接问题：

- 新增任意一个 ACP provider 都需要跨模型、设置、UI、运行时、测试多处复制修改。
- 现有 `GitHub Copilot / OpenCode / Claude Code` 被系统误建模成三个产品能力分支，但从协议视角它们都只是“可执行的 ACP agent profile”。
- 保存配置时无法做统一的可执行文件校验和 initialize 握手，因此 agentInfo 与 agentCapabilities 只能在运行时零散发现，不能作为设置的一等数据展示和复用。

## 2. 设计目标

### 2.1 必须满足

- 外部 ACP provider 不再需要单独定义为固定业务实体。
- 设置页允许手动新增 provider，至少支持 `displayName`、`executablePath`、`arguments`。
- 保存时先验证 executable 是否可解析且存在；通过后发起一次 ACP `initialize`。
- 将 `agentInfo`、`agentCapabilities`、`authMethods`、握手时间等结果展示并持久化。
- 会话默认执行器、运行时注册、配置面板、可用性状态都基于动态 provider profile 驱动。
- 保留 built-in provider 作为单独类型，不把内置 Anthropic 执行器和外部 ACP profile 混为一谈。
- 重构必须是模块化替换，不接受继续在三套 provider 分支上追加第四套、第五套的补丁式做法。

### 2.2 非目标

- 本次不改 ACP 协议模型本身。
- 本次不改外部 ACP 会话 update 的投影规则。
- 本次不引入 HTTP/OpenAPI provider 路径，仍以 stdio ACP 为唯一外部协议入口。
- 本次不处理 provider marketplace、自动下载或模板市场。

## 3. 关键调研结论

基于当前代码，外部 ACP 已经具备良好的共享底座：

- `ACPClientRuntime` 已完整支持 `initialize`、`session/new`、`session/load`、`session/set_mode`、`session/set_config_option`、`session/prompt`。[agentGui/Services/ACP/ACPClientRuntime.swift](agentGui/Services/ACP/ACPClientRuntime.swift)
- `ACPExternalAgentRuntimeClient` 已把外部 ACP 进程启动、initialize 缓存、session 复用和超时处理做成通用实现。[agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift](agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift)
- `ACPExternalExecutionProviderBase` 已抽出大部分外部 provider 共用流程。[agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift](agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift)

当前耦合点集中在 provider identity 和 persistence：

- provider 身份被 `ConversationExecutionProviderID` 枚举锁死。[agentGui/Models/ConversationExecutionProviderID.swift](agentGui/Models/ConversationExecutionProviderID.swift)
- 全局配置通过三段 JSON 存在 `AppSettings` 中。[agentGui/Models/AppSettings.swift](agentGui/Models/AppSettings.swift)
- 会话偏好通过三套结构体字段持久化。[agentGui/Models/SessionExecutionPreferences.swift](agentGui/Models/SessionExecutionPreferences.swift)
- provider registry 在 composition root 直接 new 三个 provider 实例。[agentGui/Services/ClaudeService/ClaudeService+Messaging.swift](agentGui/Services/ClaudeService/ClaudeService+Messaging.swift#L384)
- 设置页是三组并排静态表单。[agentGui/Views/Settings/SettingsExecutorsView.swift](agentGui/Views/Settings/SettingsExecutorsView.swift)

结论是：本次重构应该保留 ACP runtime shared core，不再扩展 provider-specific class tree，而是把“外部 provider 的差异”收敛为 profile data 和极少数 launch policy。

## 4. 方案比较

### 方案 A：保留现有枚举，新增一个 `custom` case

优点：改动表面看起来较小。

缺点：

- 仍然保留 `githubCopilotCLI`、`openCodeCLI`、`claudeAdapterCLI` 三个特殊分支。
- UI、偏好、持久化、registry 仍要同时处理“内置 3 个固定项 + n 个动态项”。
- 本质是继续补丁，不符合这次目标。

不推荐。

### 方案 B：把所有执行器都抽象成统一的 `ExecutionProviderReference`

核心思路：把“内置执行器”和“外部 ACP profile”统一建模成可序列化引用，业务层只依赖引用，不再依赖固定枚举。

优点：

- 可以彻底消除对三种 ACP provider 的硬编码。
- 可以把默认 provider、会话 provider、执行作业 provider、session binding provider 统一成同一身份模型。
- 外部 ACP provider 可以无限扩展，不再要求增加 enum case。

缺点：

- 需要一次性迁移多个持久化字段和 UI 选择器。
- 需要重新组织会话偏好存储结构。

推荐采用。

### 方案 C：完全插件化 manifest 系统

优点：理论上最灵活。

缺点：

- 会引入 manifest schema、模板安装、兼容层等大量额外复杂度。
- 当前需求只要求“手动新增 ACP provider 并自动 initialize 探测”，不需要插件系统。

当前阶段过度设计，不推荐。

## 5. 推荐架构

推荐方案是“内置执行器保持固定，外部 ACP provider 全部改成动态 profile”。

### 5.1 新的身份模型

新增统一引用类型：

```swift
enum ExecutionProviderReference: Codable, Hashable, Sendable {
    case builtIn
    case externalACP(profileID: UUID)
}
```

设计要点：

- `builtIn` 继续代表当前 Anthropic 内置执行器。
- 任意外部 ACP provider 都只通过 `profileID` 引用，不再拥有单独枚举值。
- 所有原来保存 `ConversationExecutionProviderID.rawValue` 的地方，统一迁移成 `ExecutionProviderReference` 的编码字符串或 JSON。

这一步是整个重构的根。只要 provider 身份仍然由 enum 控制，动态 provider 就一定会在上层重新长回硬编码分支。

### 5.2 新的动态 provider profile 模型

新增 SwiftData 模型 `ACPProviderProfile`：

```swift
@Model
final class ACPProviderProfile {
    var id: UUID
    var displayName: String
    var executablePath: String
    var argumentsJSON: String
    var isEnabled: Bool
    var sortOrder: Int
    var sourceKindRaw: String
    var discoveredAgentInfoJSON: String
    var discoveredCapabilitiesJSON: String
    var discoveredAuthMethodsJSON: String
    var lastValidationStatusRaw: String
    var lastValidationMessage: String
    var lastResolvedExecutablePath: String
    var lastVerifiedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}
```

其中：

- `displayName` 是用户在 UI 里看到的 provider 名称。
- `executablePath` 保存用户输入，可是相对命令名，也可以是绝对路径。
- `argumentsJSON` 保存参数数组，第一版不强加 environment 字段，但模型保留未来扩展空间。
- `sourceKindRaw` 用于区分 `preset` 与 `manual`，方便后续提供“从 GitHub Copilot 预设创建”但不再形成特殊 provider 类型。
- `discoveredAgentInfoJSON`、`discoveredCapabilitiesJSON`、`discoveredAuthMethodsJSON` 保存 initialize 返回值，作为设置页和运行时的真实能力缓存。
- `lastValidationStatusRaw` 和 `lastValidationMessage` 用于展示“未检测 / executable 不存在 / initialize 失败 / 已就绪”。

### 5.3 Provider Catalog 与 Registry Builder

新增三个模块：

- `ACPProviderProfileRepository`
- `ACPProviderValidationService`
- `DynamicACPProviderRegistryBuilder`

职责如下：

`ACPProviderProfileRepository`

- 读写 `ACPProviderProfile`
- 提供已启用 profile 列表
- 提供默认排序和去重规则

`ACPProviderValidationService`

- 负责解析 executable
- 启动一次轻量 ACP runtime
- 发起 `initialize`
- 生成 `ACPProviderValidationResult`
- 不负责保存 UI 草稿，不直接碰设置页面状态

`DynamicACPProviderRegistryBuilder`

- 把 `ACPProviderProfile` 列表转换成 `[ExecutionProviderReference: any ConversationExecutionProvider]`
- 为每个 profile 生成同一个 `DynamicACPExternalExecutionProvider` 实例
- 把 provider runtime、terminal runtime、permission center 注入共享基类

这样 composition root 不再显式写 `GitHubCopilotCLIExecutionProvider(...)`、`OpenCodeCLIExecutionProvider(...)`、`ClaudeAdapterCLIExecutionProvider(...)`，而是：

```swift
let registry = DynamicACPProviderRegistryBuilder(...).build(
    builtInProvider: BuiltInConversationExecutionProvider(...),
    profiles: profileRepository.enabledProfiles()
)
```

## 6. 运行时 Provider 设计

### 6.1 动态外部 Provider 类型

新增统一类型 `DynamicACPExternalExecutionProvider`，替代现有三个具体类。

建议结构：

```swift
@MainActor
final class DynamicACPExternalExecutionProvider: ACPExternalExecutionProviderBase<ACPProviderLaunchConfiguration> {
    let profileID: UUID
    let profileDisplayName: String
}
```

这里不再有 “Copilot provider / OpenCode provider / Claude provider” 的 class 层级差异。差异只来自 profile 数据和 initialize 返回的能力。

### 6.2 Launch Configuration

新增统一配置结构：

```swift
struct ACPProviderLaunchConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var arguments: [String]
    var defaultApprovalMode: String
}
```

说明：

- 现有 `ACPCLIConfiguration.defaultModel` 不应继续作为全局外部 provider 的核心字段。
- 模型和审批选项应以 remote ACP session config 为准，属于运行时 capability，不应强绑在 provider 产品定义上。
- 第一版只保留 `defaultApprovalMode` 作为本地授权策略的外部 provider 默认值；未来如果外部 provider 需要额外静态选项，可以通过 profile-level metadata 扩展，而不是重新长出多个配置类型。

### 6.3 Capability 使用原则

对于动态 provider，所有会话内控制都遵循 initialize/newSession 或 loadSession 返回的能力快照：

- 是否支持 `loadSession` 只看 initialize 返回。
- 是否展示 mode picker 只看 `modes`。
- 是否展示模型切换与审批项，只看 `configOptions` 中远端广告出的 option。
- 是否支持 auth，不做产品名假设，只看 `authMethods`。

这意味着 `GitHubCopilotCLIApprovalModeOption` 这样的命名需要下沉成“外部 provider 的本地审批策略”而不是 GitHub Copilot 专属概念。

## 7. 设置页设计

### 7.1 新的设置结构

“执行器”页拆成三块：

1. 内置执行器设置
2. 外部 ACP Provider 列表
3. Provider 编辑面板

外部 ACP provider 列表行为：

- 展示所有已保存 profile
- 每一行显示 `displayName`、解析状态、最后一次握手 agent 名称与版本
- 支持新增、编辑、删除、排序、启停

编辑面板字段：

- 名称
- executablePath
- arguments
- 保存按钮
- 重新验证按钮
- 最近一次握手结果

### 7.2 保存流程

保存采用“先验证，后持久化 profile 变更”的原子流程：

1. 用户编辑草稿。
2. 点击保存。
3. `ACPProviderValidationService` 解析 executable。
4. 若 executable 不存在，保存失败，保留草稿并显示错误。
5. 若存在，则启动临时 ACP runtime 并发送 `initialize`。
6. 若 `initialize` 成功，展示 `agentInfo`、`agentCapabilities`、`authMethods` 摘要。
7. 将 profile 和发现结果一次性持久化。
8. 通知 `DynamicACPProviderRegistryBuilder` 刷新 registry。

第一版建议采用严格策略：

- executable 无法解析时，不允许保存。
- initialize 失败时，也不允许保存为启用状态。

是否允许“保存为禁用草稿”可以作为后续增强，不放进第一版主流程，否则设置语义会变复杂。

### 7.3 Initialize 结果展示

设置页展示信息建议包括：

- Agent 名称
- Agent 标题
- Agent 版本
- `loadSession`
- prompt capabilities：audio/image/embeddedContext
- session capabilities
- mcp capabilities
- auth methods 数量与名称
- 最近验证时间

这里展示的是“最近一次成功握手缓存”，不是实时连接状态。实时可用性仍可以保留“重新验证”动作，但不再为每个已知产品维护单独状态字段。

## 8. 会话与默认执行器设计

### 8.1 全局默认执行器

`AppSettings.defaultExecutionProviderID` 迁移为统一引用字段，例如：

```swift
var defaultExecutionProviderReferenceJSON: String
```

并提供计算属性：

```swift
var defaultExecutionProviderReference: ExecutionProviderReference
```

### 8.2 会话默认执行器

`Session.defaultExecutionProviderID` 同样迁移为 `ExecutionProviderReference` 的序列化字段。

### 8.3 会话级偏好

`SessionExecutionPreferences` 不再按 provider 产品分字段，改为按 profileID 建索引：

```swift
struct SessionExecutionPreferences: Codable, Equatable, Sendable {
    var builtIn: BuiltInSessionExecutionPreferences
    var externalACP: [UUID: ACPRemoteSessionPreferenceSnapshot]
}

struct ACPRemoteSessionPreferenceSnapshot: Codable, Equatable, Sendable {
    var selectedModeID: String?
    var selectedValuesByConfigID: [String: String]
}
```

这样任意外部 provider 的模式和 config 选择都能按 profileID 保存，不再需要 `gitHubCopilotCLI`、`openCodeCLI`、`claudeAdapterCLI` 三套结构。

## 9. Registry 与调用方改造

### 9.1 Registry 形态

`ConversationExecutionProviderRegistry` 应从固定属性：

```swift
let builtIn
let copilot
let openCode
let claudeAdapter
```

改成：

```swift
struct ConversationExecutionProviderRegistry {
    let builtIn: any ConversationExecutionProvider
    let externalProviders: [UUID: any ConversationExecutionProvider]
}
```

同时提供：

- `provider(for reference: ExecutionProviderReference)`
- `allProviders()`
- `externalProvider(profileID: UUID)`

### 9.2 上层调用方约束

所有依赖 provider 分支的代码都要改成“引用驱动”而非 “switch provider enum”：

- 设置页默认 provider picker
- 新会话菜单
- chat composer 可发送性检查
- ACP session config 面板
- slash command provider 获取
- execution job 持久化
- ACP external session binding

如果某处只是为了展示名字，就从 profile snapshot 获取 displayName；不要再反向推断产品名。

## 10. 数据迁移策略

本次必须包含一次性迁移，不建议长期双写。

### 10.1 迁移输入

旧数据来源：

- `AppSettings.githubCopilotCLIConfigurationJSON`
- `AppSettings.openCodeCLIConfigurationJSON`
- `AppSettings.claudeAdapterCLIConfigurationJSON`
- `AppSettings.defaultExecutionProviderID`
- `Session.defaultExecutionProviderID`
- `Session.executionPreferencesJSON`

### 10.2 迁移输出

- 创建最多三个 `ACPProviderProfile`，其来源为现有三段配置。
- 用 profile 的 `sourceKindRaw = preset` 标记这些历史导入记录。
- 把全局和会话默认执行器映射到新的 `ExecutionProviderReference`。
- 把旧的会话偏好迁移到 `externalACP[profileID]`。

### 10.3 迁移原则

- 迁移应幂等。
- 如果旧配置为空或明显未安装，可仍创建 profile，但默认置为 disabled，并标记未验证。
- profile ID 必须稳定写回，避免迁移后 session 指针丢失。

为保证稳定性，建议通过固定的 preset migration key 建立映射，例如：

- `legacy.github_copilot_cli`
- `legacy.opencode_cli`
- `legacy.claude_adapter_cli`

这样首次迁移生成的 profile 可以被后续升级稳定识别，而不是每次启动都创建新记录。

## 11. 验证与测试设计

### 11.1 单元测试

- `ACPProviderValidationServiceTests`
  - executable 缺失时失败
  - initialize 成功时持久化返回 agentInfo 与 capabilities
  - initialize 超时或协议错误时失败
- `ExecutionProviderReferenceMigrationTests`
  - 旧默认 provider 能正确迁移到 profile 引用
- `SessionExecutionPreferencesMigrationTests`
  - 旧三套偏好能迁移为 profile 索引结构
- `DynamicACPProviderRegistryBuilderTests`
  - 启用中的 profile 会生成 provider
  - 禁用 profile 不生成 provider
  - 删除 profile 后 registry 不返回陈旧 provider

### 11.2 集成测试

- 设置页新增 provider，保存后完成 initialize，摘要信息正确展示。
- 以新 provider 创建会话，默认执行器引用正确落盘。
- 同一动态 provider 的 session config UI 能根据 remote capabilities 正常展示。
- 旧仓库升级后，历史 Copilot/OpenCode/Claude 配置被正确迁移为三个动态 profile。

### 11.3 回归重点

- 外部 runtime 仍必须按 provider 作用域隔离，不能因 profile 动态化而丢失隔离键。
- `session/load` 仍必须以 initialize 的 `loadSession` 能力为准。
- provider 删除后，引用到该 provider 的旧 session 应优雅降级到 built-in 或显示“provider 已丢失”。

## 12. 模块拆分建议

建议按以下目录分层，而不是继续把新逻辑塞进现有 Copilot/OpenCode/Claude 目录：

- `agentGui/Models/ExecutionProviderReference.swift`
- `agentGui/Models/ACPProviderProfile.swift`
- `agentGui/Repositories/ACPProviderProfileRepository.swift`
- `agentGui/Services/ACP/ACPProviderValidationService.swift`
- `agentGui/Services/ACP/DynamicACPExternalExecutionProvider.swift`
- `agentGui/Services/ACP/DynamicACPProviderRegistryBuilder.swift`
- `agentGui/ViewModels/ACPProviderSettingsEditorViewModel.swift`
- `agentGui/Views/Settings/ACPProviderListSection.swift`
- `agentGui/Views/Settings/ACPProviderEditorView.swift`

对应地，现有以下内容应逐步退役：

- `GitHubCopilotCLIExecutionProvider`
- `OpenCodeCLIExecutionProvider`
- `ClaudeAdapterCLIExecutionProvider`
- `ACPExternalAgentDescriptor`
- `AppSettings` 中三段 provider JSON
- `SessionExecutionPreferences` 中三套 provider 字段

## 13. 风险与权衡

### 风险 1：迁移面广

原因：provider ID 目前散落在 Session、ExecutionJob、ChangeProposal、ACP binding、RemoteConversationBinding 等多个模型里。

控制策略：先统一引入 `ExecutionProviderReference`，再分层替换读取入口，最后做持久化迁移与 UI 收尾。

### 风险 2：设置保存时拉起真实进程

原因：`initialize` 需要真的启动 CLI，可能受 PATH、权限、登录状态影响。

控制策略：将验证服务设计成独立 service，支持超时、结构化错误和测试替身，不把进程控制逻辑写进 SwiftUI view。

### 风险 3：把 provider 产品差异完全抹平后，丢失少量历史兼容逻辑

原因：例如某些 provider 的默认参数和本地审批策略原先由独立类提供。

控制策略：保留“预设模板”概念，但模板只参与新建 profile 的初始值填充，不再成为运行时 provider 类型。

## 14. 建议的实施顺序

1. 引入 `ExecutionProviderReference`，替换 provider 身份模型。
2. 新增 `ACPProviderProfile` 与 repository。
3. 做历史配置迁移，把三套旧配置导入为动态 profile。
4. 引入 `ACPProviderValidationService`，打通“保存前 initialize”。
5. 引入 `DynamicACPExternalExecutionProvider` 与 registry builder。
6. 替换设置页、默认 provider 选择器与新会话入口。
7. 替换 chat composer 和 session config UI 的 provider 解析。
8. 删除历史固定 provider 类型和冗余配置结构。

## 15. 最终结论

这次需求本质上不是“再接一个 ACP provider”，而是把外部 ACP provider 从产品枚举重构为运行时 profile。当前仓库已经具备足够成熟的 ACP 通用底座，因此最合理的做法不是继续给 `ConversationExecutionProviderID` 加 case，也不是再复制一套设置和 provider 类，而是：

- 用 `ExecutionProviderReference` 统一身份模型。
- 用 `ACPProviderProfile` 统一外部 provider 持久化。
- 用 `ACPProviderValidationService` 统一保存前校验和 initialize 探测。
- 用 `DynamicACPExternalExecutionProvider` 统一外部 ACP 执行实现。

这样才能满足“模块化、可扩展、禁止补丁式修改”的要求，并为未来新增任意 ACP agent 保持稳定的系统边界。