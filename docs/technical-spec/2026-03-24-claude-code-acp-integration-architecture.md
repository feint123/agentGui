# agentGui Claude Code ACP 接入技术方案

日期：2026-03-24

## 1. 文档目标

本文档回答的问题是：在 agentGui 已经完成通用 external ACP provider 基础抽象，并已支持 GitHub Copilot CLI 与 OpenCode 的前提下，如何为 Claude Code 增加 ACP 接入支持。

本文档覆盖：

1. ACP 官方文档与 Claude 官方文档的关键约束。
2. 为什么 Claude Code 不能像 OpenCode 一样被当作原生 ACP agent 直接拉起，而必须通过 adapter CLI。
3. Claude Code adapter CLI 接入 agentGui 的推荐架构、配置模型、会话流、认证流和 UI 变更。
4. 与现有 ACP 基础设施的复用边界，尤其是权限桥、事件投影、会话恢复和可用性探测。
5. 风险、兼容性、测试策略与分阶段落地顺序。

非目标：

1. 本文档不直接提交代码实现。
2. 本文档不讨论把 Claude Agent SDK 直接内嵌到 agentGui 进程内的方案。
3. 本文档不覆盖 Anthropic API 直连模式下的 built-in agent 优化。
4. 本文档不假设 Claude Code 官方已经原生提供 ACP server；设计以 adapter CLI 为前提。

## 2. 结论先行

推荐结论如下：

1. Claude Code 接入应走 “Claude Code CLI/Agent SDK + ACP adapter CLI” 的双层架构，而不是把 `claude` CLI 直接当成 ACP agent。
2. adapter CLI 是前置依赖，不是可选增强。agentGui 侧应把它视为一个独立 external ACP provider，而不是复用 OpenCode 的启动模型。
3. 当前仓库已经具备大部分可复用的会话执行平面，包括 external ACP provider 抽象、配置存储、provider registry、capability-aware session negotiation、权限中心和 update projector；Claude Code 接入应在此之上扩展，而不是新建一套 runtime。
4. Claude Code adapter 的主复用点是 initialize、authenticate、session/new、session/load、session/prompt、session/cancel、session/update 与 permission request；本地 fs/terminal bridge 不应被假定为主链。
5. V1 应先支持本地 stdio adapter CLI 接入、会话创建/恢复、权限请求、流式消息、工具调用投影与基础认证；MCP 深度透传、gateway auth、list/fork/resume/close 等增强能力放到后续阶段。
6. 从产品与分发角度，用户可理解为“接入 Claude Code 能力”，但技术实现上真实接入对象是 ACP adapter。代码与设置命名需要把这层关系表达清楚，避免后续排障时把问题错误归因到 `claude` CLI 本体。

一句话概括：

> 这不是“再接一个 CLI”，而是“把 Claude Agent SDK 暴露出来的 ACP adapter 当成第三个 external ACP provider 接入 agentGui，并针对它的认证、能力广告和工具投影差异做专门适配”。

## 3. 外部资料调研摘要

### 3.1 ACP 官方协议结论

根据 ACP 官方站与官方仓库文档，可以确认以下事实：

1. ACP 基于 JSON-RPC 2.0，并以 stdio 作为本地 agent 的典型传输方式。
2. 标准生命周期是 `initialize -> authenticate（可选） -> session/new 或 session/load -> session/prompt -> session/update -> session/cancel`。
3. Agent 基线能力包括 `session/new`、`session/prompt`、`session/cancel` 与 `session/update`。
4. `session/load` 不是基线能力，而是只有在 initialize 响应广告了 `loadSession` 后才能调用。
5. `session/set_model` 目前仍属于不稳定能力，不能被客户端当成所有 agent 的默认前提。
6. Slash commands 是通过 `available_commands_update` 广告、再以普通 prompt 文本发送的会话级能力，而不是一组固定 API。
7. `session/load` 的语义不是简单恢复句柄，而是必须重放历史消息，客户端要能消费 replay 期间的 `session/update`。
8. Client 侧文件、终端、权限能力也是 capability-gated 的；agent 是否调用这些 client methods，取决于 agent 自身实现。

这些结论意味着：agentGui 当前已经做对了一半，尤其是在 capability-aware session negotiation 与 update projection 上，但仍不能把任何 provider-specific 能力提升成协议默认值。

### 3.2 ACP 官方 Agents 页对 Claude 的结论

ACP 官网的 Agents 页面没有把 Claude Code 列为“原生 ACP agent”，而是列为：

1. `Claude Agent`。
2. 接入方式是 `via Zed’s SDK adapter`。

这条信息非常关键，因为它直接说明：

1. Claude 这条链路在 ACP 生态中的标准接入物不是 `claude` CLI 本身。
2. 真实的 ACP 对接点是一个单独的 adapter 实现。
3. 因此 agentGui 若要支持 Claude Code 的 ACP 集成，前提不是“用户装了 claude 就够了”，而是“用户还装了可运行的 ACP adapter CLI”。

### 3.3 Claude Code / Agent SDK 官方文档结论

根据 Claude Code 官方文档与 Agent SDK 官方文档，可以确认以下事实：

1. Claude Code 官方公开的一等接口是 `claude` CLI 与 Claude Agent SDK，而不是 ACP server 模式。
2. Claude Code CLI 支持安装、登录、`-p` 非交互模式、`--resume`、`--continue`、`--model`、`--permission-mode`、`--mcp-config` 等会话控制能力。
3. Claude Agent SDK 是 Claude Code 能力的程序化封装，复用了 Claude Code 的工具、agent loop、skills、memory、slash commands 和上下文管理。
4. Agent SDK 默认通过 Claude Code CLI 子进程工作，而不是直接替代 CLI 运行时。
5. Agent SDK 文档还明确给出了 branding guideline：第三方产品不应把自身展示成 “Claude Code” 本体。

这意味着：从 Anthropic 官方角度，agentGui 不应该把自己的实现叙述成“内建了 Claude Code ACP server”，而应更准确地描述为“通过 Claude 官方 Agent SDK 生态的 ACP adapter 接入 Claude 能力”。

### 3.4 Claude ACP adapter 的公开实现结论

根据 ACP 官网指向的公开 adapter 实现 `zed-industries/claude-agent-acp`，可以确认以下事实：

1. adapter 的定位就是 “ACP adapter for the Claude Agent SDK”。
2. 它可以作为独立 CLI 安装并运行，例如：
   `npm install -g @zed-industries/claude-agent-acp`
   然后运行：
   `claude-agent-acp`
3. 它通过 `@anthropic-ai/claude-agent-sdk` 驱动 Claude，而不是自己重新实现 Claude agent loop。
4. 它实现了 ACP 的 `initialize`、`authenticate`、`session/new`、`session/load`、`session/list`、`session/prompt`、`session/cancel`、`session/set_mode`、`session/set_config_option` 等方法。
5. 它广告 `loadSession: true`，并支持 `list`、`resume`、`fork`、`close` 等 session capabilities。
6. 它会把 Claude 的 slash commands 转换为 ACP `available_commands_update`，也会把使用情况转换为 `usage_update`。
7. 它支持 terminal auth，并提供 `claude-login` 风格的认证方法描述。
8. 新版 adapter 已明显向“使用 Claude 内建工具并将其事件投影为 ACP 更新”演进，而不是像通用 ACP agent 那样大量依赖 client `fs/*` 与 `terminal/*` 回调。

第 8 点会直接影响 agentGui 的架构判断：

1. permission center 仍然重要。
2. session/update normalizer 仍然重要。
3. 但 ACPLocalClientHandler 中的文件桥和终端桥，未必是 Claude adapter 主链。

## 4. 与当前仓库的契合点

### 4.1 当前已存在的可复用能力

当前仓库已经具备如下基础设施：

1. `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
   已经抽出了通用 external ACP provider 主骨架，负责 runtime 生命周期、capability-aware session negotiation、binding 持久化、prompt 派发和 turn 状态收敛。
2. `agentGui/Services/ACP/ACPClientRuntime.swift`
   已支持 `initialize`、`authenticate`、`session/new`、`session/load`、`session/prompt` 等核心请求。
3. `agentGui/Services/ACP/ACPPermissionCenter.swift`
   已经承担统一权限请求入口。
4. `agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift`、`ACPExternalUpdateProjector.swift`、`ACPSessionUpdateRouter.swift`
   已有外部 ACP 更新到本地消息/UI 状态的投影层。
5. `agentGui/Models/ACPExternalAgentDescriptor.swift`
   已具备 provider descriptor 概念。
6. `agentGui/Models/AppSettings.swift`
   已经有多 provider 的 CLI 配置槽位。
7. `agentGui/Services/ConversationExecutionProviderRegistry.swift`
   已支持 built-in、GitHub Copilot CLI、OpenCode 三类执行器。

结论：Claude Code 不需要“重做 external ACP provider 架构”，而是要在现有架构上新增一类 provider descriptor、配置、availability 探测与认证/事件差异处理。

### 4.2 当前架构中还缺的部分

Claude Code 接入还缺以下能力：

1. 新的 provider ID 与配置入口。
2. adapter CLI 专用 availability service。
3. adapter CLI runtime factory。
4. authenticate 流的 UI 与状态处理，尤其是 terminal auth。
5. 对 “此 provider 不依赖 client fs/terminal callbacks” 的能力描述与降级文案。
6. 对 adapter 额外 session capabilities 的使用策略，例如是否在 V1 开放 session/list。

### 4.3 与现有 OpenCode 方案的关键差异

OpenCode 接入文档中默认延续了“agentGui 提供 ACP file/terminal/permission bridge，agent 通过 ACP 回调使用这些能力”的思路。但 Claude adapter 的公开实现说明，至少在当前版本下：

1. 它更多依赖 Claude 自身的 built-in tools。
2. 它把运行结果投影成 ACP tool events。
3. 它不保证会大量调用 client `fs/read_text_file`、`fs/write_text_file`、`terminal/create` 等方法。

因此 Claude Code 接入不能简单套用 “OpenCode = 只换命令” 的模型。

## 5. 推荐架构

### 5.1 总体方案

推荐把 Claude 接入定义为新的 external ACP provider：

1. provider 对用户展示为 Claude 能力入口。
2. provider 实际启动的是 ACP adapter CLI。
3. adapter CLI 再调用 Claude Agent SDK / Claude Code CLI。

示意关系如下：

`agentGui -> ACP adapter CLI -> Claude Agent SDK -> Claude Code CLI / Claude runtime`

这条链路的好处是：

1. 与 ACP 官方生态一致。
2. 与当前 external ACP provider 架构一致。
3. 不需要把 Anthropic 私有控制协议直接塞进 agentGui。
4. 后续如果 adapter 升级支持更多 ACP 能力，agentGui 可以按 capability 增量启用。

### 5.2 新 provider 的命名策略

建议区分三层命名：

1. 用户心智层：`Claude` 或 `Claude Agent`。
2. 设置层：`Claude ACP Adapter`。
3. 代码层：`claude_adapter_cli` 或 `claude_agent_acp`。

不建议在代码层只写 `claudeCodeCLI`，原因有二：

1. 真正执行的不是 `claude` 本体，而是 adapter。
2. 一旦登录、PATH、Node、adapter 版本不兼容，排障时需要快速区分到底是 `claude` CLI 问题还是 adapter 问题。

### 5.3 配置模型

建议在现有 `ACPCLIConfiguration` 基础上，不立即做大改，但为 Claude adapter 补一个独立配置槽位：

```swift
struct ACPCLIConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var defaultModel: String
    var defaultApprovalMode: String
}
```

V1 可新增：

1. `claudeAdapterCLIConfigurationJSON`。
2. `AppSettings.claudeAdapterCLIConfiguration` 计算属性。
3. `ACPCLIConfiguration.claudeAdapterDefault` 默认值。

推荐默认值：

1. `executablePath = "claude-agent-acp"`
2. `defaultModel = ""`
3. `defaultApprovalMode = "default"`

后续若需要支持更强配置，再扩展为：

1. environment overrides
2. gateway auth metadata
3. adapter-specific extra args
4. explicit Claude executable override

但这些不应阻塞 V1。

### 5.4 Provider Descriptor

建议在 `ACPExternalAgentDescriptor` 中新增一项：

1. `static let claudeAdapter`

建议属性：

1. `providerID = .claudeAdapterCLI`
2. `displayName = "Claude"`
3. `defaultExecutablePath = ACPCLIConfiguration.claudeAdapterDefault.executablePath`
4. `defaultArguments = []`
5. `supportsSessionModelOverrideByDefault = true`
6. `supportsCustomAgentName = false`
7. `defaultEnvironment = [:]`

其中第 5 点需要解释：

1. ACP 协议里的 `session/set_model` 不是基线能力。
2. 但 Claude adapter 公开实现返回 `models` 与 `configOptions`，并实现了 session model 变更相关能力。
3. 因此 provider 可以“默认倾向支持模型切换”，但实际调用仍必须以 initialize 后的能力快照为准。

即：默认行为是 optimistic，但执行逻辑必须 capability-gated。

## 6. 启动与可用性探测

### 6.1 启动命令

V1 默认启动命令为：

`claude-agent-acp`

如果用户使用的是单文件发行版，则允许把 `executablePath` 指向绝对路径。

不建议在 agentGui 内部自动拼接：

1. `node .../dist/index.js`
2. `npx @zed-industries/claude-agent-acp`

原因是：

1. 这会把安装方式耦合进客户端。
2. `npx` 首次拉包、缓存与 PATH 行为不稳定。
3. 本仓库对 Copilot/OpenCode 的模式也是“探测一个用户可执行程序”，保持一致更稳妥。

### 6.2 Availability Service

建议新增：

1. `ClaudeAdapterCLIAvailabilityStatus = ACPCLIAvailabilityStatus`
2. `ClaudeAdapterCLIAvailabilityService`

检测层级：

1. 可执行文件是否存在。
2. 能否成功拉起子进程。
3. initialize 是否成功返回。
4. 若 initialize 返回 `authMethods` 但当前未认证，状态显示为“已安装，需登录/认证”，而不是简单的 unavailable。

状态建议至少区分：

1. `available`
2. `notInstalled`
3. `notAuthenticated`
4. `launchFailed`
5. `protocolMismatch`

这里尤其不能把 “adapter 可执行文件存在但 Claude 未登录” 误判成 “不可用”。

### 6.3 PATH 与安装提示

设置页的引导文案应明确写出两层依赖：

1. Claude Code / Claude Agent SDK 所需的登录或 API key 准备。
2. ACP adapter CLI 的安装。

建议文案中提供：

1. `npm install -g @zed-industries/claude-agent-acp`
2. 若 PATH 不可见，允许手动填写 adapter 可执行路径。

## 7. 会话与协议流

### 7.1 初始化流

推荐标准流：

1. 启动 adapter 子进程。
2. 发送 `initialize`。
3. 记录：
   1. `loadSession`
   2. `sessionCapabilities`
   3. `authMethods`
   4. `agentInfo`
   5. `models` 或可通过后续配置得到的模型状态
4. 若要求认证，则进入 authenticate 分支。
5. 认证完成后再允许进入 session negotiation。

### 7.2 认证流

Claude adapter 的公开实现支持 terminal auth，并暴露类似 `claude-login` 的 auth method。V1 建议：

1. 在 initialize 后若发现存在可识别 auth method，且当前未认证，则 provider 返回专门的认证错误模型。
2. UI 侧提供一个“完成登录”动作。
3. 该动作可触发 adapter 广告的 terminal-auth 命令，或者给出明确的终端登录引导。

不建议在 V1 做的事：

1. 自动代跑复杂浏览器登录。
2. 自行组装 gateway auth 元数据。
3. 把 adapter 的所有 authMethods 都映射为通用配置表单。

V1 的目标只是把“需要认证”从 opaque failure 提升为清晰、可恢复的状态。

### 7.3 会话创建与恢复

建议沿用现有 `ACPExternalExecutionProviderBase` 的机制：

1. 若本地 session 已存在 remote binding，且 `loadSession = true`，优先尝试 `session/load`。
2. 若 `session/load` 失败，则回退 `session/new` 并覆盖旧 binding。
3. 若 provider initialize 未广告 `loadSession`，则直接 `session/new`。

Claude adapter 公开实现支持 `session/load`，因此理论上可以复用当前的 restore path；但依然必须保留失败回退逻辑，原因是：

1. adapter 版本变化可能影响 resume 兼容性。
2. 底层 Claude session 目录可能被清理。
3. 认证状态变化也可能让历史 session 无法重建。

### 7.4 Prompt Turn

建议 V1 完全沿用当前通用 ACP turn pipeline：

1. 发送 `session/prompt`。
2. 消费 `session/update`。
3. 将 `agent_message_chunk`、`tool_call`、`tool_call_update`、`thinking`、`usage_update` 投影到现有时间线和执行 theater。
4. 收到 prompt response 后收敛 stop reason。

Claude adapter 的价值不在于需要新的 prompt API，而在于它会产生一组更接近 Claude 内部语义的 session updates。因此现有 normalizer 需要适配，但主链不必重写。

## 8. 工具、权限与本地桥接

### 8.1 权限桥仍是主链

Claude adapter 公开实现会调用 `session/request_permission`。因此：

1. `ACPPermissionCenter` 继续复用。
2. `ToolAuthorizationPolicy` 继续复用。
3. `ExecutionTheaterView` 中的审批卡片与 tool audit 继续复用。

换句话说，Claude 接入的 V1 核心不是文件桥，而是权限桥与工具状态桥。

### 8.2 文件与终端桥不是默认前提

Claude adapter 的新版本已转向“使用 Claude 内建工具，再把事件转换为 ACP 通知”。这带来一个重要差异：

1. agentGui 不应假设 adapter 会频繁请求 `fs/read_text_file`。
2. agentGui 不应假设 adapter 会频繁请求 `terminal/create`。
3. ACPLocalClientHandler 需要保留，因为协议上可能仍会被调用，但它不再是 Claude provider 成功工作的必要条件。

产品影响：

1. Claude provider 的“本地文件/终端能力”文案要更谨慎。
2. 调试面板要能分辨“这是 ACP client tool call”还是“这是 adapter 投影出的 Claude internal tool call”。
3. 不能用“没有看到 fs/terminal 回调”来判断 Claude provider 异常。

### 8.3 MCP 能力

Claude adapter 公开实现支持 client MCP servers。V1 的策略建议是：

1. 先复用现有 session/new / session/load 中的 `mcpServers` 注入管线。
2. 不因为 Claude adapter 可能还读取本地 `.claude` 配置，就放弃客户端注入。
3. 若发现 adapter 对 injected MCP servers 与本地配置合并存在冲突，再在 V2 引入 provider-specific 策略开关。

## 9. 数据模型与 UI 变更

### 9.1 Provider ID

建议在 `ConversationExecutionProviderID` 中新增：

1. `claudeAdapterCLI = "claude_adapter_cli"`

显示名称建议为：

1. `Claude`

### 9.2 AppSettings

建议在 `AppSettings` 中新增：

1. `claudeAdapterCLIConfigurationJSON`
2. `claudeAdapterCLIConfiguration` 计算属性

默认值建议为 `ACPCLIConfiguration.claudeAdapterDefault`。

### 9.3 Settings UI

在当前执行器设置页基础上新增一张卡片：

1. 可执行文件路径
2. 默认模型
3. 默认审批模式
4. 可用性状态
5. 一键刷新状态
6. 安装指引
7. 认证状态与登录引导

V1 不建议放入的字段：

1. 自定义 agent name
2. 自定义环境变量表单
3. gateway auth 配置
4. session/list 开关

### 9.4 认证状态投影

当 availability 为 `notAuthenticated` 时：

1. 该 provider 仍显示在执行器列表中。
2. 但发送消息前给出明确引导，而不是静默失败。
3. 用户可以保留它为默认执行器，但首次发送时需要先完成认证。

## 10. 测试策略

### 10.1 单元测试

建议新增测试组：

1. `ClaudeAdapterCLIAvailabilityServiceTests`
   验证 notInstalled / notAuthenticated / available / protocolMismatch。
2. `ClaudeAdapterCLIRuntimeFactoryTests`
   验证默认命令与工作目录传递。
3. `ClaudeAdapterExecutionProviderTests`
   验证 initialize、authenticate-required、session/load fallback、prompt、cancel。
4. `ClaudeAdapterEventNormalizerTests`
   验证 `usage_update`、slash commands、tool_call update 投影。
5. `ClaudeAdapterAuthFlowTests`
   验证 terminal auth method 被正确转换为 UI 状态与恢复动作。

### 10.2 测试夹具策略

不建议把真实 `claude-agent-acp` 或真实 `claude` 登录状态作为单元测试依赖。建议继续采用最小 stdio fixture，原因是：

1. 真实环境依赖 Node、adapter 版本、Claude 登录态、网络与 API 配额。
2. 本仓库当前 ACP 测试体系已经偏向最小协议夹具，这一点应该延续。
3. 我们真正要验证的是 agentGui 的 protocol handling，而不是第三方 adapter 本身是否工作。

### 10.3 手工验收

至少覆盖：

1. adapter 已安装但未登录时，设置页与发送链路能给出明确引导。
2. 初始化成功后可创建 session 并完成首轮 prompt。
3. 关闭应用后重新打开，若 `loadSession` 可用，则能恢复 remote session。
4. Claude slash commands 广告能进入本地 slash command provider。
5. permission request 能正确显示与回传。
6. tool_call / usage_update / stop reason 能正确投影到 UI。

## 11. 风险与兼容性

### 11.1 最大风险：把 adapter 当成原生 Claude CLI

这是最容易犯的设计错误。后果包括：

1. 错误的安装引导。
2. 错误的可用性诊断。
3. 错误的启动命令。
4. 错误地把认证故障归因到 `claude` 本体。

因此 V1 必须在设置、日志和错误消息里把 adapter 这一层显式展示出来。

### 11.2 第二风险：错误假设 client fs/terminal bridge 是主链

若沿用 OpenCode 的思维模型，容易误判 Claude provider 的行为。正确预期应是：

1. permission 和 update projection 是必须能力。
2. fs/terminal client callbacks 是可选能力。

### 11.3 第三风险：过早依赖扩展 session 能力

Claude adapter 虽然公开支持 list/resume/fork/close，但 V1 不建议全部开放，原因是：

1. 当前 agentGui 的核心价值仍是会话发送与恢复。
2. 一次引入过多 session operations 会把 UI、binding store 和错误语义复杂化。

### 11.4 命名与品牌风险

Claude Agent SDK 的官方品牌指引不鼓励第三方产品把自己包装成 “Claude Code” 本体。因此建议：

1. 对用户文案说“Claude”或“Claude Agent”。
2. 对技术设置说“Claude ACP Adapter”。
3. 避免在 UI 上把该 provider 描述成 “Claude Code 官方内置模式”。

## 12. 分阶段落地建议

### 阶段 1：最小可用接入

目标：让用户能在本地通过 adapter CLI 使用 Claude provider。

工作项：

1. 新增 `ConversationExecutionProviderID.claudeAdapterCLI`。
2. 新增 `AppSettings` 配置槽位与默认值。
3. 新增 `ACPExternalAgentDescriptor.claudeAdapter`。
4. 新增 `ClaudeAdapterCLIAvailabilityService`。
5. 新增 `ClaudeAdapterCLIExecutionProvider` 或 provider-specific wrapper。
6. 接入 settings UI。
7. 支持 initialize、notAuthenticated、session/new、session/load、session/prompt、session/cancel。

### 阶段 2：认证与模型体验打磨

目标：减少接入摩擦。

工作项：

1. terminal auth UI 动作。
2. 模型列表与 config options 更好投影。
3. `usage_update` 与 slash commands 的 UI 完善。

### 阶段 3：增强能力

目标：把 Claude adapter 的附加 session 能力逐步开放。

工作项：

1. `session/list`
2. `session/fork`
3. `session/close`
4. gateway auth
5. provider-specific MCP 策略

## 13. 推荐落点

建议本期最终交付物包括：

1. 一个新的 Claude external ACP provider。
2. 一套清晰的 adapter 安装与认证引导。
3. 一组最小协议测试与手工验收清单。

不建议本期交付物包括：

1. 直接内嵌 Agent SDK。
2. 重新设计 built-in agent。
3. 重构 ACP 基础设施主骨架。

## 14. 参考资料

1. ACP 官方介绍与架构
   https://agentclientprotocol.com/
   https://agentclientprotocol.com/get-started/architecture
2. ACP 官方协议文档与 schema
   https://agentclientprotocol.com/protocol/overview
   https://agentclientprotocol.com/protocol/initialization
   https://agentclientprotocol.com/protocol/session-setup
   https://agentclientprotocol.com/protocol/prompt-turn
   https://agentclientprotocol.com/protocol/slash-commands
   https://github.com/agentclientprotocol/agent-client-protocol
3. ACP 官方 Agents 页
   https://agentclientprotocol.com/get-started/agents
4. Claude Code 官方文档
   https://code.claude.com/docs/en/overview
   https://code.claude.com/docs/en/cli-reference
5. Claude Agent SDK 官方文档
   https://platform.claude.com/docs/en/agent-sdk/overview
6. Claude ACP adapter 公开实现
   https://github.com/zed-industries/claude-agent-acp
