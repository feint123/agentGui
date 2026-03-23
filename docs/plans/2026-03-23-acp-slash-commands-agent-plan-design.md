# ACP Slash Commands 与 Agent Plan 设计方案

日期：2026-03-23

## 目标

为当前 external ACP 执行框架补齐以下两项协议能力，并确保设计具备良好的模块边界、provider 差异隔离能力与后续扩展空间：

1. slash-commands
2. agent-plan

本方案覆盖：

- ACP 协议层建模
- GitHub Copilot CLI 与 OpenCode 的差异化接入策略
- UI 投影与会话状态持久化
- 恢复、回放、兼容与测试策略

本方案不直接给出实现代码，而是作为后续 implementation plan 的基础设计文档。

## 调研结论

### 1. ACP 协议结论

#### Slash Commands

ACP 协议将 slash commands 定义为两部分：

- Agent 通过 `session/update` 下发 `available_commands_update`，向 Client 广播当前会话可用命令列表。
- Client 在发起 `session/prompt` 时，仍然以普通用户消息文本的形式发送，例如 `/plan xxx`、`/review xxx`。

协议关键点：

- `available_commands_update` 是动态的，Agent 可以在会话中多次替换整个命令列表。
- 命令执行本身不是单独 RPC，而是普通 prompt 文本。
- 每个命令可以包含可选的输入 hint，用于指导 UI 提示与补全。

这意味着对 Client 来说，slash command 支持不是“本地执行命令”，而是：

- 识别并缓存 Agent 广播的命令目录。
- 在输入区提供发现、补全与插入。
- 最终仍把 `/command args` 原样交给 Agent。

#### Agent Plan

ACP 通过 `session/update` 的 `plan` 更新将执行计划暴露给 Client。

协议关键点：

- `plan` 更新携带的是完整列表，而不是增量 patch。
- 每条 entry 至少包含 `content`、`priority`、`status`。
- `status` 取值为 `pending`、`in_progress`、`completed`。
- Client 必须把每次更新视为“替换当前计划”，而不是合并局部变更。

这意味着我们需要一个“原始 ACP plan 快照 + 内部 UI 投影”的双层模型，而不是直接把若干事件临时拼成 todo。

### 2. GitHub Copilot CLI 调研结论

GitHub Copilot 官方文档确认：

- Copilot CLI 可通过 `copilot --acp --stdio` 作为 ACP server 运行，且该能力仍处于 public preview。
- CLI 自身拥有明确的 interactive slash command 目录，包括 `/plan`、`/review`、`/agent`、`/mcp`、`/model`、`/resume`、`/share`、`/usage` 等。
- Copilot CLI 具备 plan mode；`/plan` 是正式的交互命令。

但是，Copilot 的 ACP 参考页只明确展示了普通 `agent_message_chunk` 的 ACP 集成示例，并未在官方 ACP 参考页中显式承诺：

- 一定会通过 ACP 广播 `available_commands_update`
- 一定会通过 ACP 下发 `plan`

因此，Copilot 的设计结论是：

- slash command 文本调用本身可以立即支持，因为协议本来就是普通 prompt 文本。
- “远端命令目录广播”和“协议原生 plan 更新”必须按 runtime 观测能力处理，不能在 client 里强假设。
- 若要提升发现性，可以引入一层 provider 文档种子命令，但必须与远端广告列表分层，不能把静态文档列表伪装成协议事实。

### 3. OpenCode 调研结论

OpenCode 官方文档明确说明：

- ACP 启动命令为 `opencode acp`。
- OpenCode 通过 ACP 运行时，几乎与终端内行为一致。
- 支持内置工具、自定义工具、自定义 slash commands、MCP、AGENTS.md 规则、代理与权限系统。
- 已知例外是部分内置命令如 `/undo`、`/redo` 当前暂不支持。

进一步从其实现和文档仓库可确认：

- OpenCode 在 load session 阶段会主动发送 `available_commands_update`。
- OpenCode 会把内部 todo 列表投影为 ACP `plan` 更新。

因此，OpenCode 是协议原生支持最完整的 provider，我们应把它作为 `available_commands_update` 与 `plan` 的主验证对象。

## 当前仓库现状

当前仓库已经具备实现这两个能力的若干重要基础，但链路尚未打通。

### 已有基础

1. ACP session/update 已有统一解码入口

`agentGui/Services/ACP/ACPModels.swift`

当前 `ACPSessionUpdate` 已能区分：

- `agent_message_chunk`
- `agent_thought_chunk`
- `tool_call`
- `tool_call_update`
- 其他未知类型会落入 `.other`

这说明协议入口已经存在，但 `available_commands_update` 与 `plan` 目前仍被吞入 `.other`。

2. 外部 ACP provider 共享基类已经存在

`agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`

当前 GitHub Copilot CLI 与 OpenCode CLI 已经复用同一套：

- runtime 启动
- session new/load
- set model
- prompt
- permission resolution
- event consumption

这为“统一协议能力，provider 只做差异化适配”提供了很好基础。

3. 当前 normalizer 只处理文本、思考、工具、权限

`agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`

这里没有命令目录与计划的概念，说明新能力不应再硬塞进当前 tool/text normalizer，而应该拆出独立 feature 通道。

4. 当前 UI 已有两条可复用能力

- slash 命令补全：`agentGui/Services/SlashCommandRegistry.swift`
- todo 卡片显示：`agentGui/ViewModels/ChatComposerTodoCardPresentation.swift`

此外，现有会话状态已经支持：

- `Session.planJson`
- `SessionTaskStateStore.savePlan`
- `SessionTaskStateStore.saveTodoItems`

这意味着 agent-plan 不需要重新发明持久化和展示层，只需要一个可靠的投影器。

### 当前缺口

当前缺口主要有四类：

1. ACP 模型层缺口

- 缺少 `available_commands_update` 的 typed model
- 缺少 `plan` 的 typed model

2. feature 路由缺口

- 当前 ACP update 只进文本/工具 projector
- 命令目录与计划没有独立消费链路

3. provider 差异隔离缺口

- OpenCode 与 Copilot 对协议扩展的支持度不同
- 当前 runtime capability snapshot 只记录 `loadSession` 与 `supportsSessionModelOverride`

4. UI/状态桥接缺口

- slash menu 只知道本地 skill/provider，不知道远端 ACP commands
- todo 卡片虽存在，但没有接入外部 ACP `plan`

## 设计目标

1. 协议扩展必须以 typed model 接入，禁止把 `plan`/`available_commands_update` 当作匿名 JSON 在各层临时解析。
2. feature 更新必须与文本/工具流解耦，避免 normalizer 膨胀成万能转发器。
3. provider 差异必须收敛到单独适配层，不能把 Copilot/OpenCode 细节散落在 UI 与存储层。
4. 计划状态必须既能投影为现有 `ExecutionPlan`/`TodoItem`，又能保留原始 ACP 语义，避免信息丢失。
5. slash command 必须支持“远端广告优先、静态种子兜底、手动输入永远可用”的三层策略。
6. 方案必须能继续扩展 future ACP session/update 类型，例如 modes、checkpoints、structured outputs。

## 非目标

1. 不在本次设计中解析 Agent 输出的 Markdown 来伪造 `plan`。
2. 不在本次设计中本地执行 slash command。
3. 不在本次设计中重做整个输入区架构。
4. 不把 provider 文档中列出的命令强行写成协议事实。

## 方案比较

### 方案 A：最小改动，直接在现有 normalizer 中追加两种 event

做法：

- 为 `ACPSessionUpdate` 增加两个 case
- 在 `ACPExternalAgentEventNormalizer` 中继续返回更多 event
- 在 `ACPExternalExecutionProviderBase` 中继续统一 apply

优点：

- 改动最少
- 短期可用

缺点：

- 文本/工具/feature 三类语义混在一个 normalizer 中
- slash commands 与 plan 并不是“消息流增量事件”，强行混入会让模型污染严重
- 后续再接 modes、resume metadata、session capabilities 时会继续失控

结论：不推荐。

### 方案 B：新增 ACP Feature Layer，文本工具链与 feature 链解耦

做法：

- 协议模型层新增 typed update
- 新增 `ACPExternalSessionFeatureExtractor`
- 新增 `ACPExternalSessionFeatureStore`
- 由基类同时驱动两条链路：
  - 文本/工具投影链
  - feature 状态投影链

优点：

- 模块边界清晰
- provider 差异可集中处理
- slash commands 与 plan 可以直接映射到会话状态与 UI
- 后续可持续扩展更多 ACP session features

缺点：

- 比最小改动多一个 feature store 和 adapter 层

结论：推荐。

### 方案 C：做通用 ACP session/update registry，所有 update 动态插件化

优点：

- 理论上最通用

缺点：

- 对当前仓库明显过度设计
- 会引入不必要的抽象层和测试复杂度

结论：当前阶段不值得。

## 推荐方案

采用方案 B：在现有 external ACP 执行框架上新增一层 ACP Feature Layer。

核心思路是把 ACP update 分成两条正交链路：

1. 执行流

- assistant text
- thinking
- tool calls
- permission prompts

2. feature 流

- available commands
- plan snapshot
- 后续可扩展的会话级 feature

执行流继续服务当前消息流 UI。

feature 流负责维护：

- 远端 slash command 目录
- 外部 agent plan 快照
- 这些状态到本地 UI 模型的投影

## 模块设计

### 1. 协议模型层

建议在 `agentGui/Services/ACP/ACPModels.swift` 新增以下模型：

```swift
struct ACPAvailableCommand: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let input: ACPAvailableCommandInput?
}

struct ACPAvailableCommandInput: Codable, Equatable, Sendable {
    let hint: String
}

struct ACPAvailableCommandsUpdatePayload: Codable, Equatable, Sendable {
    let availableCommands: [ACPAvailableCommand]
}

enum ACPPlanEntryPriority: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

enum ACPPlanEntryStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

struct ACPPlanEntry: Codable, Equatable, Sendable {
    let content: String
    let priority: ACPPlanEntryPriority
    let status: ACPPlanEntryStatus
}

struct ACPPlanUpdatePayload: Codable, Equatable, Sendable {
    let entries: [ACPPlanEntry]
}
```

然后扩展 `ACPSessionUpdate`：

```swift
case availableCommandsUpdate(ACPAvailableCommandsUpdatePayload)
case plan(ACPPlanUpdatePayload)
```

这是整个方案的基础。如果这里仍保留 `.other` 再下游临时解析，后续所有模块都会不稳定。

### 2. Feature 领域模型

建议新增一组“会话级 ACP feature 状态”模型，而不是直接把协议模型塞进 UI：

```swift
enum ACPCommandSource: String, Codable, Sendable {
    case remoteAdvertised
    case documentationSeed
}

struct ACPCommandDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let inputHint: String?
    let source: ACPCommandSource
}

struct ACPPlanSnapshot: Codable, Equatable, Sendable {
    let entries: [ACPPlanEntry]
    let providerID: ConversationExecutionProviderID
    let remoteSessionID: String
    let updatedAt: Date
}

struct ACPExternalSessionFeatureState: Codable, Equatable, Sendable {
    var commands: [ACPCommandDescriptor]
    var plan: ACPPlanSnapshot?
    var lastUpdatedAt: Date
}
```

这里的关键是保留两个层次：

- 协议原始语义
- 本地展示语义

这样后续如果 UI 想显示“该命令来自远端广告还是 provider 文档种子”，不需要重新拆模型。

### 3. Feature 提取器

建议新增 `ACPExternalSessionFeatureExtractor`，职责只有一个：

- 从 `ACPExternalAgentUpdate` 中提取命令目录与计划快照

接口可以类似：

```swift
enum ACPExternalSessionFeatureEvent: Equatable, Sendable {
    case replaceCommands([ACPCommandDescriptor])
    case replacePlan(ACPPlanSnapshotDraft)
}

struct ACPPlanSnapshotDraft: Equatable, Sendable {
    let entries: [ACPPlanEntry]
}
```

为什么不继续用现有 normalizer：

- normalizer 当前的语义是“把流式 update 变成 message/tool event”
- commands/plan 是状态替换，不是流式 delta
- 两者强行复用只会增加耦合

### 4. Feature Store

建议新增 `ACPExternalSessionFeatureStore`，作用是以 `localSessionID + providerID` 为键维护 feature 快照。

建议职责：

- 保存最后一次可用 commands 列表
- 保存最后一次 plan 快照
- 提供会话恢复时的缓存读取
- 负责把原始 ACP plan 投影到现有 `SessionTaskStateStore`

不要把它直接并入 `SessionTaskStateStore`，原因如下：

- `SessionTaskStateStore` 当前是会话任务状态存储，已经承载 `ExecutionPlan`、`TodoItem`、verification、RMS
- ACP feature 还包含 commands，这不是 task state 的一部分
- 单独 store 更便于未来扩展更多 ACP session features

### 5. Provider Feature Adapter

建议为 external ACP provider 引入一个单独的 feature adapter 协议：

```swift
protocol ACPExternalProviderFeatureAdapter {
    var providerID: ConversationExecutionProviderID { get }

    func documentedSlashCommands() -> [ACPCommandDescriptor]
    func mergeCommands(
        cached: [ACPCommandDescriptor],
        remote: [ACPCommandDescriptor]?
    ) -> [ACPCommandDescriptor]
}
```

设计意图：

- Copilot 与 OpenCode 在协议支持成熟度上不同
- 但差异应该被限制在 adapter，而不是散落到 UI 和 ACP store

#### OpenCode adapter

- 默认不需要文档种子命令
- 以远端 `available_commands_update` 为真源
- 若远端暂时未返回，可读取缓存

#### GitHub Copilot adapter

- 提供一个保守的文档种子命令集，用于提升 UX discoverability
- 所有种子命令标记为 `source = .documentationSeed`
- 一旦 ACP 远端真的发来 `available_commands_update`，远端结果覆盖种子列表

注意：

- 不能把 Copilot 所有交互命令都无脑写死
- 只应纳入官方文档明确稳定、且适合作为 ACP 前端暴露的命令
- 推荐首批仅纳入：`/plan`、`/review`、`/agent`、`/model`、`/mcp`、`/share`、`/usage`、`/resume`、`/cwd`

这能在协议理想化与 UX 实用性之间取得平衡。

## Slash Commands 设计

### 用户体验目标

1. 当当前执行 provider 是 external ACP provider 时，输入 `/` 可以看到该 provider 当前会话可用命令。
2. 远端已广告的命令优先显示。
3. 对于 Copilot，可在远端无广告时显示文档种子命令，并明确其不是 runtime 保证。
4. 选择命令后，本地只负责插入文本，不负责执行。

### 输入区桥接策略

当前 `ChatSlashCommandRegistry` 主要服务本地 skill 命令。推荐新增并行 provider：

- `ACPChatSlashCommandProvider`

由它把 `ACPCommandDescriptor` 投影为 `ChatSlashCommandItem`。

但是当前 `ChatSlashCommandPayload` 只支持 `.skill(directoryName:)`，因此需要扩展：

```swift
case acpCommand(name: String, argumentHint: String?, source: ACPCommandSource)
```

然后在 `ChatInputCommandParser` 中新增一条替换逻辑：

- 选择 ACP command 后，插入 `/command `
- 若存在 hint，则在 UI 层显示 hint，不把 hint 内容写进 prompt

这里不建议把 ACP command 做成 `ChatInputDirective`，因为它不是本地语义，也不需要写入审计尾注；它只是普通用户输入的补全来源。

### 命令选择与发送语义

发送时不需要任何特殊分支：

- 文本仍然是普通用户输入
- external ACP provider 仍然使用现有 `prompt(text:sessionID:)`

这与协议完全一致，也避免本地逻辑和远端 agent 行为发生偏离。

## Agent Plan 设计

### 语义要求

1. 每次 `plan` 更新必须视为完整替换。
2. 必须保留原始 ACP plan 快照，以备恢复、调试与 provider 差异分析。
3. 必须投影到当前已有 UI 能力：
   - `Session.planJson`
   - `SessionTaskStateStore.saveTodoItems`

### 内部投影策略

建议新增 `ACPPlanProjector`，职责：

- `ACPPlanSnapshot` -> `ExecutionPlan`
- `ACPPlanSnapshot` -> `[TodoItem]`

推荐映射规则：

#### 投影到 `TodoItem`

- `content` -> `title`
- `status.pending` -> `.pending`
- `status.in_progress` -> `.inProgress`
- `status.completed` -> `.done`
- `priority` -> 追加到 `notes` 或保留在 raw snapshot

#### 投影到 `ExecutionPlan`

当前 `ExecutionPlan.PlanStepStatus` 不支持 `in_progress`，因此推荐扩展内部模型：

```swift
case inProgress = "in_progress"
```

同时为 `PlanStep` 增加可选 `priority` 字段：

```swift
var priority: ACPPlanEntryPriority?
```

这样内部 plan 模型就不会在投影时丢语义。

### 为什么不能只存 todo

如果只存 todo：

- 无法保留 ACP 原生 priority
- 无法表达完整 plan 替换的来源时间与 provider 语义
- 无法区分“原生 agent plan”与“本地工具生成的 execution plan”

因此建议：

- 原始 ACP plan 快照存到 feature store
- 投影结果写入现有 `SessionTaskStateStore`

这是“协议层真实状态”和“UI 层兼容状态”的合理拆分。

## ACPExternalExecutionProviderBase 接入方式

当前 `ACPExternalExecutionProviderBase.consume(update:)` 只会把 update 送入：

- normalizer
- update projector
- `apply(event:to:in:)`

推荐改造为：

1. 先让 feature extractor 提取 feature 事件
2. 再让现有 normalizer 处理执行流事件
3. 两条链路互不依赖

伪代码如下：

```swift
private func consume(update: CopilotACPUpdate, localSessionID: String) {
    guard turnRouter.shouldProjectIncomingUpdate(for: localSessionID) else { return }
    guard let activeTurn = activeTurns[localSessionID] else { return }

    let featureEvents = featureExtractor.extract(
        update: update,
        providerID: id,
        remoteSessionID: ...
    )
    featureStore.apply(featureEvents, localSessionID: localSessionID, modelContext: activeTurn.modelContext)

    let projectedEvents = updateProjector.project(
        events: normalizer.normalize(update: update),
        sessionID: localSessionID
    )
    ...
}
```

这里的关键收益是：

- `plan` 更新不需要等 turn 结束 flush
- `available_commands_update` 可以即时影响输入区补全
- 不会污染现有工具流处理逻辑

## 持久化与恢复策略

### Commands

commands 是会话级、provider 级、远端 session 级状态。建议缓存最近一次结果，以支持：

- app 重启后会话恢复
- `session/load` 到远端后，UI 在下一次广告到达前仍可展示上次已知命令

commands 不应写到 `Session.planJson` 或 `SessionTaskState`，应保存在独立 feature store 中。

### Plan

plan 需要两层持久化：

1. 原始快照
   - 由 `ACPExternalSessionFeatureStore` 保存

2. UI 兼容投影
   - `ExecutionPlan` 写入 `Session.planJson`
   - `TodoItem[]` 写入 `SessionTaskStateStore`

### 恢复时机

在 `ensureSession` 完成后：

- 如果远端 provider 重新广播 feature，则用远端覆盖缓存
- 若没有广播，则保留缓存状态，不阻塞发送与 UI

这对 Copilot 尤其重要，因为其 ACP preview 行为未完全稳定。

## 错误处理与边界条件

### 1. 远端未广告 commands

处理方式：

- OpenCode：显示缓存或空列表
- Copilot：显示文档种子列表或缓存
- 用户始终可手动输入 `/command`

### 2. 远端计划为空列表

应当视为合法的“清空计划”，而不是忽略。

因为协议语义是完整替换。

### 3. 远端返回未知 plan status 或 priority

处理方式：

- raw snapshot 保留原始 JSON
- typed decode 可以在必要时引入 `.unknown(String)`，或在 phase 1 直接回退为 `.other` payload 并记录日志

推荐优先采用宽容解码方案，避免 preview provider 因新增字段导致整个功能失效。

### 4. slash command 与本地 skill 命令重名

必须区分命令来源：

- 本地 skill 命令
- provider ACP 命令

推荐 UI 上用 badge 显示来源，例如：

- `Skill`
- `Copilot`
- `OpenCode`

排序策略：

- 当前 provider 的 ACP command 优先
- 其次本地 skill

### 5. 计划与内建 plan 工具冲突

当前 app 已存在内部 `ExecutionPlan` 与 todo 系统。外部 ACP plan 不应覆盖内部工具语义，而应定义明确来源：

- `source = builtIn`
- `source = externalACP(providerID)`

phase 1 可以只在 raw snapshot 中保留来源，在 UI 上复用同一显示组件。

## 推荐落地文件

建议首批变更聚焦以下文件：

### 协议与 runtime

- `agentGui/Services/ACP/ACPModels.swift`
- `agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- 新增 `agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift`
- 新增 `agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
- 新增 `agentGui/Services/ACP/ACPPlanProjector.swift`

### provider 差异层

- 新增 `agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- `agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`

### UI 与输入区

- `agentGui/Services/SlashCommandRegistry.swift`
- `agentGui/Services/ChatInputCommandParser.swift`
- `agentGui/Models/SlashCommandModels.swift`
- `agentGui/Models/ChatComposerSlashState.swift`
- `agentGui/Views/ChatView+InputArea.swift`

### 计划状态投影

- `agentGui/Models/ExecutionPlan.swift`
- `agentGui/Models/TodoItem.swift`
- `agentGui/Services/SessionTaskStateStore.swift`

## 测试策略

### 1. 协议模型测试

新增单元测试验证：

- `available_commands_update` 正确 decode/encode
- `plan` 正确 decode/encode
- 未知 session update 仍能回退到 `.other`

### 2. Feature extractor 测试

验证：

- 输入 `ACPSessionUpdate.availableCommandsUpdate` 时输出 `replaceCommands`
- 输入 `ACPSessionUpdate.plan` 时输出 `replacePlan`
- 输入 message/tool update 时不产生 feature event

### 3. Plan projector 测试

验证：

- ACP `pending/in_progress/completed` 正确映射到 `TodoStatus`
- priority 正确保留
- 空 plan 能清空本地计划

### 4. Provider adapter 测试

Copilot：

- 无远端广告时返回文档种子命令
- 有远端广告时远端覆盖种子

OpenCode：

- 仅使用远端广告结果
- 空广告时使用缓存或空列表

### 5. Execution provider 集成测试

扩展现有 ACP provider 测试夹具，验证：

- OpenCode 风格的 `available_commands_update` 能出现在输入补全中
- OpenCode 风格的 `plan` 更新能驱动 `SessionTaskStateStore`
- Copilot provider 不会因缺少远端 `plan`/commands 广播而报错

### 6. UI 测试

验证：

- 输入 `/` 时展示 ACP commands
- 选择命令后只插入文本，不触发本地动作
- todo 卡片会随 ACP plan 更新刷新

## 分阶段实施建议

### Phase 1：协议建模与 feature store

- 扩展 `ACPModels`
- 新增 extractor/store/projector
- 打通 OpenCode `available_commands_update` 与 `plan`

这是最有确定性的阶段，因为 OpenCode 已经明确支持。

### Phase 2：输入区集成与 plan UI 投影

- 把 commands 接到输入补全
- 把 plan 接到 `SessionTaskStateStore` 与 todo card
- 扩展 `ExecutionPlan` 以保留 `in_progress`

### Phase 3：Copilot provider adapter

- 加入保守的 Copilot 文档种子命令
- 保持远端广告优先
- 不对 Copilot 缺失的原生 `plan` 做脆弱的文本解析

### Phase 4：恢复、缓存与 observability

- 持久化 commands cache
- 记录 feature source、更新时间与 provider 行为差异
- 为未来 ACP 新 feature 保留扩展点

## 最终建议

最合适的落地方式不是“在现有 normalizer 里加两个 if”，而是把 external ACP 从“只会处理文本与工具流”升级为“同时承载执行流与会话 feature 流”的双通道架构。

推荐最终原则如下：

1. 协议原语 typed 化。
2. 文本/工具流与 feature 流解耦。
3. provider 差异通过 adapter 收口。
4. `plan` 采用“raw snapshot + internal projection”双层存储。
5. `slash commands` 采用“远端广告优先，文档种子兜底，手动输入永远可用”的策略。

按这个方向实现，可以在不破坏现有 external ACP 架构的前提下，把 OpenCode 的协议能力完整接进来，同时为 GitHub Copilot 的 preview 行为保留足够弹性。