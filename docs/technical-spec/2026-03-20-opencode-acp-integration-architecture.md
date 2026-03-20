# agentGui OpenCode ACP 接入技术方案

日期：2026-03-20

## 1. 文档目标

本文档用于回答一个具体问题：在 agentGui 已经具备 ACP 客户端基础设施、且已经完成 GitHub Copilot CLI ACP 接入第一版的前提下，如何以最小风险、可持续演进的方式，为 ACP 功能增加 OpenCode 支持。

文档范围包括：

1. OpenCode 与 ACP 官方资料整理。
2. 当前仓库中 ACP 与 GitHub Copilot CLI 接入现状梳理。
3. OpenCode 接入的推荐架构、数据模型、UI 与运行时改造点。
4. 风险、兼容性约束、测试范围与阶段性落地顺序。

非目标：

1. 本文档不直接提交代码实现。
2. 本文档不覆盖 OpenCode HTTP Server 全量集成，只讨论它与 ACP 路径的取舍。
3. 本文档不假设 OpenCode 一定支持所有 GitHub Copilot CLI 当前已使用的非标准 ACP 扩展。

## 2. 结论先行

推荐结论如下：

1. OpenCode 应作为第三个会话执行器接入，而不是作为现有 GitHub Copilot CLI provider 的分支特例。
2. 接入主路径应选择 OpenCode 官方 ACP 子进程模式，也就是运行 opencode acp，而不是抓取 TUI 文本，也不是优先走 HTTP Server API。
3. 当前 GitHub Copilot CLI 接入中真正可复用的是 Services/ACP 下的通用 ACP 连接、进程监管、文件与终端桥，以及权限桥；当前 GitHubCopilot 命名空间里的大部分逻辑需要上移成通用 ACP 外部执行器层。
4. 在实现上，不建议继续复制一份 GitHubCopilotCLIExecutionProvider 改名成 OpenCodeExecutionProvider；推荐先抽出通用 ACP CLI 执行器骨架，再让 GitHub Copilot CLI 与 OpenCode 通过 descriptor 或 configuration 注入差异。
5. OpenCode 的模型选择、Agent 切换、会话恢复等能力必须走初始化能力探测与降级逻辑，不能直接照搬当前 GitHub Copilot 的 session/load 与 session/set_model 调用路径。
6. V1 应只做 OpenCode ACP stdio 集成；OpenCode 的 HTTP Server / OpenAPI 能力保留为后续增强路径，而不是首版主链。

一句话概括：

> 这不是“再接一个 CLI”，而是“把现有 Copilot 特化的 ACP 执行器抽象升级为通用 ACP 外部执行器框架，并让 OpenCode 作为第二个 ACP 兼容 Agent 落地”。

## 3. 外部资料调研摘要

### 3.1 ACP 官方协议结论

根据 Agent Client Protocol 官方文档，可以确认以下事实：

1. ACP 采用 JSON-RPC 2.0 语义。
2. 典型交互顺序是 initialize -> authenticate（如需要）-> session/new 或 session/load -> session/prompt -> session/update -> session/cancel。
3. Agent 基线能力包括 session/new、session/prompt、session/cancel 与 session/update。
4. session/load 是能力探测后的可选能力，客户端只有在 initialize 响应中确认 loadSession 为 true 时才能调用。
5. Client 可声明 fs/read_text_file、fs/write_text_file、terminal 等能力，Agent 再通过这些回调复用本地文件系统和终端能力。
6. 工具调用通过 session/update 中的 tool_call / tool_call_update 投影，权限通过 session/request_permission 往客户端请求。
7. 所有文件路径必须是绝对路径，行号是 1-based。
8. 能力扩展依赖 capability 与自定义方法，不能把非标准方法当作所有 Agent 的默认能力。

这与当前 agentGui 已实现的 ACP 基础设施是高度匹配的。

### 3.2 OpenCode 官方文档结论

根据 OpenCode 官方文档，可以确认以下事实：

1. OpenCode 是一个官方支持 ACP 的编码 Agent，官方接入方式就是运行 opencode acp。
2. OpenCode ACP 作为兼容 ACP 的子进程，通过 stdio 上的 JSON-RPC 与编辑器通信。
3. OpenCode 官方文档明确给出了在 Zed、JetBrains、Avante.nvim、CodeCompanion.nvim 中通过 opencode acp 进行 ACP 接入的配置样例。
4. OpenCode 官方说明其 ACP 使用体验与终端模式基本一致，支持内置工具、自定义工具、自定义命令、MCP 服务器、AGENTS.md 规则、格式化器、代码检查器、代理与权限系统。
5. OpenCode 官方也明确说明，部分内置斜杠命令目前不支持，例如 /undo 与 /redo。
6. OpenCode CLI 文档明确存在 acp 子命令，说明它并不是实验性隐藏入口，而是公开能力。
7. OpenCode 配置系统支持全局配置、项目配置、远程组织配置、环境变量覆盖，并且支持 provider、model、permission、mcp、instructions、agent、plugin 等完整配置面。
8. OpenCode 还提供独立 HTTP Server 能力，opencode serve 会暴露 OpenAPI 3.1 文档与会话、消息、配置、文件、MCP、事件等接口。

对本项目最重要的结论是：

1. OpenCode 的 ACP 路径是官方一等能力。
2. OpenCode 的工具、权限、规则、MCP 生态可以通过 ACP 原样映射给 agentGui。
3. OpenCode 同时存在 HTTP Server 路径，这给后续远程接入、无子进程接入和多客户端共享后端提供了第二阶段演进空间。

### 3.3 OpenCode ACP 额外实现细节

基于 OpenCode 源码文档摘录，还可以确认两点：

1. OpenCode ACP Server 可通过 opencode acp --cwd /path/to/project 显式指定工作目录。
2. 如需启用交互式问答工具，可通过环境变量 OPENCODE_ENABLE_QUESTION_TOOL=1 启动 ACP Server。

第二点不是 ACP 标准能力，因此不应作为 V1 默认接入内容，而应视为 OpenCode 扩展能力。

## 4. 与当前仓库的契合点

### 4.1 当前已存在的可复用基础设施

当前仓库中，以下模块已经具备较强复用价值：

1. agentGui/Services/ACP/ACPProcessSupervisor.swift
   负责外部进程启动、PATH 解析、stdio 管理。
2. agentGui/Services/ACP/ACPManagedClientRuntime.swift
   负责拉起 ACP Client Runtime，并绑定进程生命周期。
3. agentGui/Services/ACP/ACPLocalClientHandler.swift
   已实现本地文件读写、终端创建与输出、权限请求桥接。
4. agentGui/Services/ACP/ACPClientRuntime.swift 与 ACPModels.swift
   已实现 initialize、session/new、session/load、session/prompt、session/cancel 等核心模型和请求封装。
5. agentGui/Services/ACP/ACPPermissionCenter.swift
   已具备 ACP 权限桥与 UI 对接基础。

这些模块本身不依赖 GitHub Copilot CLI，因此完全可以为 OpenCode 复用。

### 4.2 当前存在的特化耦合

当前仓库对 GitHub Copilot CLI 的 ACP 接入已经落地，但很多层次仍然是产品特化命名和单一 provider 假设：

1. agentGui/Models/ConversationExecutionProviderID.swift 当前只枚举 built_in_agent 与 github_copilot_cli。
2. agentGui/Models/AppSettings.swift 只有 githubCopilotCLIConfigurationJSON，没有通用 ACP 外部执行器配置槽位。
3. agentGui/Models/GitHubCopilotCLIConfiguration.swift 当前把 executablePath、defaultModel、customAgentName、defaultApprovalMode、useACPStdIO 都绑定在 GitHub Copilot 命名空间下。
4. agentGui/Services/ConversationExecutionProviderRegistry.swift 当前 provider registry 只知道 builtIn 与 copilot 两个分支。
5. agentGui/Services/GitHubCopilot/GitHubCopilotCLIRuntimeFactory.swift 将启动参数硬编码为 --acp --stdio。
6. agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift 在会话握手、模型设置、session bridge、事件归一化和错误语义上均带有 Copilot 特定假设。

这意味着当前结构适合“继续打磨 Copilot”，但不适合“再接第二个 ACP Agent”。

### 4.3 当前实现中的协议风险

当前 GitHub Copilot ACP 路径还有两类逻辑，不适合直接照搬给 OpenCode：

1. session/load 的调用虽然已经在当前仓库里作为主恢复路径使用，但对于其他 Agent，必须先经过 initialize capability 探测后才能调用。
2. session/set_model 在 ACPMethodCatalog 里作为扩展方法存在，但当前 ACP 官方文档公开强调的是 session/set_mode，而不是 session/set_model。因此 OpenCode 是否支持会话级模型切换，不能在实现前默认成立。

换句话说，OpenCode 接入前必须先把“Copilot 恰好可用”的逻辑改成“能力探测后再启用”的逻辑。

## 5. 方案对比

### 5.1 方案 A：复制一套 OpenCode 特化执行器

做法：

1. 新增 OpenCodeExecutionProvider。
2. 复制 GitHubCopilotCLIExecutionProvider、RuntimeFactory、AvailabilityService、SessionBridge。
3. 仅替换命令为 opencode acp。

优点：

1. 上手最快。
2. 对现有 Copilot 代码入侵最小。

缺点：

1. 代码会立刻复制两套近似的 ACP runtime 封装。
2. 后续再接第三个 ACP Agent 时会继续复制。
3. capability 差异、权限差异、模型差异会散落到多份 provider 中。
4. Settings、Availability、SessionBridge、测试矩阵都会快速膨胀。

结论：不推荐。

### 5.2 方案 B：抽象通用 ACP 外部执行器层，再挂载 Copilot 与 OpenCode

做法：

1. 提取通用 ACPCLIExecutionProvider 骨架。
2. GitHub Copilot CLI 与 OpenCode 只保留 descriptor、配置模型、可用性探测与事件归一化差异。
3. 所有 capability 协商、session 生命周期、权限桥、fs/terminal bridge 统一走通用层。

优点：

1. 与仓库“后续支持更多 ACP 兼容执行器”的方向一致。
2. 能从根上消除 GitHub Copilot 特化命名带来的扩展阻力。
3. OpenCode 和 Copilot 的差异可以集中到少量可测试的 capability / launch / normalization 模块。
4. 后续接入 Claude Code、Codex CLI、Gemini CLI 等 ACP Agent 时可复用。

缺点：

1. 首版工作量高于简单复制。
2. 需要重构部分现有 Copilot 命名与测试夹具。

结论：推荐方案。

### 5.3 方案 C：不用 ACP，直接走 OpenCode HTTP Server

做法：

1. 运行 opencode serve。
2. 通过 HTTP / SSE / OpenAPI 与 OpenCode 对接。
3. 自己适配会话、消息、事件和权限。

优点：

1. 适合未来远端共享后端或多客户端场景。
2. OpenCode HTTP API 比 ACP 暴露更多服务端语义。

缺点：

1. 与当前仓库已完成的 ACP fs / terminal / permission bridge 复用度低。
2. 需要重新设计 HTTP 认证、会话事件流、状态同步与错误映射。
3. 首版无法直接复用现有 ACP 工具调用 UI 投影。

结论：可作为第二阶段增强路线，不适合作为当前版本主接入路径。

## 6. 推荐架构

### 6.1 新的分层目标

建议把当前“GitHub Copilot CLI 特化 ACP 接入”升级成以下四层：

1. External ACP Executor Layer
   统一处理 ACP 连接、initialize、capability 协商、session 生命周期、prompt、cancel、权限桥、文件桥、终端桥。
2. Provider Descriptor Layer
   定义不同外部 Agent 的启动方式、能力偏好、状态探测、事件归一化策略。
3. Settings / Session Preferences Layer
   承载每个外部 Agent 的全局默认值与会话级覆盖值。
4. UI Projection Layer
   在执行器选择器、设置页、权限卡片、时间线中投影外部 Agent 的状态和能力差异。

### 6.2 建议新增的核心抽象

#### 6.2.1 外部 ACP Agent 标识

建议把 ConversationExecutionProviderID 扩展为至少三项：

1. built_in_agent
2. github_copilot_cli
3. opencode_cli

如果后续还会继续扩展，可以进一步引入：

1. ExternalAgentKind
2. ACPCompatibleAgentID

但对于当前版本，只新增 opencode_cli 即可。

#### 6.2.2 通用 ACP CLI 配置模型

建议新增通用配置结构，例如：

```swift
struct ACPCLIProviderConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var arguments: [String]
    var defaultModel: String
    var defaultAgentName: String
    var defaultApprovalMode: String
    var environment: [String: String]
    var useACPStdIO: Bool
}
```

然后：

1. GitHubCopilotCLIConfiguration 退化为 descriptor + 兼容层，或直接迁移到通用结构。
2. OpenCodeConfiguration 复用相同结构，只改变默认命令、默认参数与附加环境变量。

推荐默认值：

1. GitHub Copilot CLI：command = copilot，args = ["--acp", "--stdio"]。
2. OpenCode：command = opencode，args = ["acp"]。

#### 6.2.3 通用 ACP Agent Descriptor

建议新增只读 descriptor：

```swift
struct ACPExternalAgentDescriptor: Sendable {
    let providerID: ConversationExecutionProviderID
    let displayName: String
    let defaultExecutablePath: String
    let defaultArguments: [String]
    let supportsSessionModelOverrideByDefault: Bool
    let supportsCustomAgentName: Bool
    let defaultEnvironment: [String: String]
}
```

用途：

1. 设置页渲染默认值。
2. 可用性探测使用统一入口。
3. 运行时工厂根据 descriptor 生成启动参数。

#### 6.2.4 通用 ACP Session Bridge

当前 CopilotSessionBridge 建议提升为通用 ACPExternalSessionBridge，至少保存：

1. localSessionID
2. providerID
3. remoteSessionID
4. remoteAgentVersion
5. lastHandshakeAt
6. lastSelectedModel
7. lastSelectedAgentName
8. negotiatedCapabilities 快照

这样 OpenCode 与 Copilot 可以共用同一持久化映射结构。

### 6.3 通用运行时生命周期

推荐运行时流程如下：

1. 根据当前执行器选择到 providerID。
2. 从 AppSettings + SessionExecutionPreferences 解析出最终 provider configuration。
3. 通过 descriptor + configuration 生成 launch configuration。
4. 启动 ACPManagedClientRuntime，并绑定 ACPLocalClientHandler。
5. 发送 initialize，请求 protocolVersion = 1，并声明 fs.readTextFile、fs.writeTextFile、terminal 能力。
6. 记录 Agent 返回的：
   - protocolVersion
   - agentInfo
   - loadSession
   - promptCapabilities
   - mcpCapabilities
   - 可能的自定义 capability
7. 若本地 session 已绑定 remoteSessionID，且 loadSession 为 true，则尝试 session/load；否则走 session/new。
8. 若 provider 明确支持模型切换，再发 session/set_model 或对应扩展；否则跳过并回退到 provider 自身配置。
9. 发送 session/prompt。
10. 将 session/update 中的消息块、thinking、tool_call、tool_call_update、permission request 继续投影到现有聊天 UI 与 Execution Theater。
11. 用户取消时发送 session/cancel，并立即本地收敛未完成工具状态。

### 6.4 OpenCode 的差异化策略

OpenCode 接入时建议采用以下特化规则：

1. 启动命令：默认使用 opencode acp。
2. 工作目录：沿用 currentDirectoryURL + session/new 的 cwd 双重传递，不额外依赖 --cwd；只有后续验证存在行为偏差时，再启用 --cwd。
3. 模型覆盖：默认不假设 ACP 会话级模型切换存在；只有当 OpenCode 文档或 capability 明确支持时，才启用 session/set_model 或扩展方法。
4. 自定义 Agent 名称：默认不把 GitHub Copilot 的 customAgentName 语义直接迁移过来；OpenCode 的 agent 选择优先走它自己的配置和命令体系，V1 可仅保留默认 agent。
5. Question Tool：V1 不开启 OPENCODE_ENABLE_QUESTION_TOOL，避免引入新的非标准交互面；后续如果 agentGui 计划支持外部 Agent 发起结构化提问，再通过环境变量开启。
6. 权限桥：继续使用现有 ACPPermissionCenter 与 ToolAuthorizationPolicy。OpenCode 官方说明 ACP 下权限系统受支持，因此可直接复用。
7. MCP：OpenCode 官方说明 ACP 模式会保留其配置中的 MCP 服务器，因此 V1 不要求 agentGui 主动注入额外 MCP server 列表，先以 OpenCode 自身配置为主。

## 7. 设置与 UI 设计

### 7.1 执行器选择器

聊天输入区的执行器选择器建议新增：

1. 内置 Agent
2. GitHub Copilot CLI
3. OpenCode

并展示状态提示：

1. 已安装
2. 路径不可用
3. 未完成 provider 配置
4. ACP 能力受限

### 7.2 设置页

建议把当前“GitHub Copilot CLI 设置区”升级为“外部 ACP 执行器”分组，至少包含两张配置卡片：

1. GitHub Copilot CLI
2. OpenCode

OpenCode 卡片建议字段：

1. 可执行文件路径，默认 opencode。
2. 默认模型，初期为可选文本，不强制内置固定枚举。
3. 默认审批模式。
4. 可选环境变量配置。
5. 是否启用 ACP stdio，V1 固定为 true。
6. 可用性与版本探测结果。

不建议在 V1 直接暴露太多 OpenCode 内部配置项，例如 provider map、plugin、formatter、theme、share、server 端口等。那些属于 OpenCode 自身配置域，应继续由它自己的配置文件承担。

### 7.3 可用性探测

当前 GitHub Copilot CLIAvailabilityService 建议抽象成通用 ACPCLIAvailabilityService。OpenCode 的探测逻辑建议分层：

1. 快速探测：只查找可执行文件是否存在。
2. 深度探测：启动一次轻量 initialize 或执行 opencode --version。
3. 运行时错误回填：如果首次 prompt 失败且错误表现为 provider 未认证、模型不可用、配置不合法，则把错误回写到 UI 状态提示中。

原因是 OpenCode 的认证模型不是“统一登录状态”，而是 provider 级凭据、环境变量、项目配置组合，无法像 Copilot 那样用单一登录状态概括。

## 8. 数据模型与持久化建议

### 8.1 AppSettings

建议新增：

1. opencodeConfigurationJSON

或者更进一步：

1. externalACPProviderConfigurationsJSON

如果只考虑当前版本，为了减少重构面，可以先新增 opencodeConfigurationJSON，待第三个 ACP Agent 接入时再收敛成字典结构。

### 8.2 SessionExecutionPreferences

当前 SessionExecutionPreferences 已具备 provider-specific composer override 思路。建议为 OpenCode 增加：

1. modelID override
2. approvalMode override

但注意：

1. modelID override 不代表运行时一定能下发到 ACP Agent。
2. 如果 initialize 后无法确认支持模型切换，则 override 只作为“下次启动时写入 OpenCode 环境或配置”的候选，不直接影响当前会话。

### 8.3 Session Bridge

推荐将当前 CopilotSessionBridge 命名泛化，并把 negotiatedCapabilities 持久化。这样可以：

1. 避免每次都在 UI 层猜测当前 provider 支持哪些能力。
2. 为后续诊断与兼容问题提供真实握手快照。

## 9. 事件归一化与兼容性策略

### 9.1 统一 ACP 更新模型

建议把当前 CopilotACPUpdate / CopilotACPEventNormalizer 抽象成：

1. ACPExternalAgentUpdate
2. ACPExternalAgentEventNormalizer

原因：

1. OpenCode 同样会走 session/update 投影。
2. tool_call、tool_call_update、agent_message_chunk、thinking、plan 都是 ACP 层语义，不应绑定 Copilot 命名。

### 9.2 非标准能力必须探测后启用

以下能力必须视为 provider-specific optional：

1. session/load
2. session/set_model
3. session/set_mode
4. question tool 或任何自定义 ACP 方法

OpenCode V1 的最低要求应只有：

1. initialize
2. session/new
3. session/prompt
4. session/update
5. session/cancel
6. fs / terminal / permission callback

### 9.3 会话恢复策略

推荐恢复策略：

1. 如果 provider 返回 loadSession = true，则继续使用现有 remoteSessionID -> session/load。
2. 如果 provider 不支持 loadSession，则只在单次运行时内复用已存在 runtime，不跨 runtime 恢复。
3. 如果 provider 支持 loadSession 但 load 失败，则记录错误并回退为 session/new，同时更新绑定。

## 10. 测试策略

### 10.1 单元测试

建议新增以下测试组：

1. OpenCodeLaunchConfigurationTests
   验证默认命令为 opencode acp。
2. ACPExternalAgentDescriptorTests
   验证 Copilot 与 OpenCode 的 descriptor 差异。
3. ACPExternalSessionNegotiationTests
   验证 loadSession false 时不会调用 session/load。
4. OpenCodeExecutionPreferencesTests
   验证 model / approval override 的解析与降级行为。
5. ACPExternalEventNormalizerTests
   验证 OpenCode 更新事件仍能落入现有 Message / ToolCall 投影。

### 10.2 夹具测试

和当前 Copilot 一样，建议使用最小 stdio ACP fixture，而不是依赖真实 opencode 二进制。原因：

1. 测试更稳定。
2. 能独立验证 initialize、session/new、session/load、prompt、permission、terminal 等链路。
3. 可以分别构造“支持 loadSession”与“不支持 loadSession”的 Agent。

### 10.3 手工验证

至少覆盖：

1. OpenCode 可执行文件自动发现。
2. 新建会话并发送第一条消息。
3. 文件读取与写入工具调用投影。
4. 终端工具调用投影。
5. 权限请求卡片与本地拒绝流程。
6. 取消当前 turn。
7. 重开应用后会话恢复或正确降级。
8. OpenCode 未配置 provider 凭据时的错误提示。

## 11. 分阶段实施建议

### 阶段 1：抽通用 ACP 外部执行器层

目标：消除 GitHub Copilot ACP 实现中的命名和结构性耦合。

动作：

1. 提取通用 launch configuration。
2. 提取通用 runtime client 与 capability 协商。
3. 泛化 session bridge 与 event normalizer。
4. 保持 GitHub Copilot 现有行为不回归。

### 阶段 2：增加 OpenCode Provider

目标：让 OpenCode 成为可选择的执行器。

动作：

1. 新增 opencode_cli 枚举项。
2. 新增 OpenCode 配置模型与设置页。
3. 新增 OpenCode availability service。
4. 接入 OpenCode runtime factory，默认命令 opencode acp。

### 阶段 3：补齐 capability-aware 降级逻辑

目标：解决不同 ACP Agent 能力差异。

动作：

1. loadSession 探测与降级。
2. set_model 探测与降级。
3. 对不支持的扩展方法做 UI 解释。

### 阶段 4：增强体验

目标：利用 OpenCode 的额外能力但不破坏协议通用性。

候选项：

1. 支持 OPENCODE_ENABLE_QUESTION_TOOL。
2. 把 OpenCode HTTP Server 作为后台共享 runtime。
3. 将 OpenCode 的 model / agent 目录做动态读取，而不是静态配置输入。

## 12. 主要风险与应对

### 12.1 模型切换能力不一致

风险：当前 GitHub Copilot 使用 session/set_model，但这不是 ACP 官方基线能力，OpenCode 是否支持不能先验确定。

应对：

1. V1 不把会话级模型切换作为阻塞条件。
2. 先 capability probe，再决定是否下发扩展方法。
3. 若不支持，则把默认模型控制留在 OpenCode 自身配置层。

### 12.2 会话恢复能力不一致

风险：如果 OpenCode 不支持 loadSession，当前 Copilot 的恢复路径不能复用。

应对：

1. initialize 后缓存 loadSession 能力。
2. 不支持时只做进程内复用，不做跨运行时恢复。

### 12.3 OpenCode 认证状态难以在设置页单点表达

风险：OpenCode 不是统一账号登录模型，而是 provider / env / project config 组合，无法像 Copilot 那样简单标记“已登录”。

应对：

1. 设置页只承诺“可执行文件可用”和“最近一次运行错误”。
2. 更细粒度的认证失败通过首次 turn 错误回填给用户。

### 12.4 非标准扩展污染通用层

风险：如果把 OpenCode question tool、Copilot model override 等直接写死进通用层，会让抽象再次失效。

应对：

1. 所有非标准能力通过 provider-specific extension hook 管理。
2. 通用层只理解标准 ACP 与 capability gating。

## 13. 验收标准

当以下条件全部满足时，可认为 OpenCode ACP 接入完成：

1. 用户可在聊天输入区明确选择 OpenCode。
2. agentGui 能成功启动 opencode acp 并完成 initialize。
3. 用户消息可通过 session/new 或 session/load 后进入 session/prompt。
4. OpenCode 的消息增量、工具调用、权限请求能在现有聊天 UI 与 Execution Theater 中正确投影。
5. 文件与终端能力通过现有 ACPLocalClientHandler 正常工作。
6. 不支持的能力会被清晰降级，而不是直接报协议错误。
7. GitHub Copilot 现有 ACP 能力不回归。

## 14. 资料来源

本方案参考了以下外部资料：

1. ACP 官方站介绍与协议总览
   https://agentclientprotocol.com/
   https://agentclientprotocol.com/protocol/overview
2. ACP 初始化、会话与 Prompt 生命周期
   https://agentclientprotocol.com/protocol/initialization
   https://agentclientprotocol.com/protocol/session-setup
   https://agentclientprotocol.com/protocol/prompt-turn
   https://agentclientprotocol.com/protocol/tool-calls
3. OpenCode 官方文档
   https://opencode.ai/docs/zh-cn/
   https://opencode.ai/docs/zh-cn/cli/
   https://opencode.ai/docs/zh-cn/config/
   https://opencode.ai/docs/zh-cn/acp/
   https://opencode.ai/docs/zh-cn/server/
4. OpenCode 源码文档摘录
   https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/acp/README.md

## 15. 对当前仓库的直接建议

如果下一步要落代码，我建议按下面的顺序推进：

1. 先把 GitHubCopilotCLIExecutionProvider 中的通用 ACP 握手、session 生命周期和 event normalizer 抽出来。
2. 再新增 OpenCode provider，而不是先复制一份 Copilot provider。
3. 最后才去做设置页和输入区的 OpenCode UI 暴露。

原因很直接：

1. 先做 UI，后面一定返工命名与数据结构。
2. 先做通用抽象，可以确保 OpenCode 不是一次性分支实现。
3. 先处理 capability-aware 逻辑，能避免 OpenCode 接入后才发现 session/load 或 model override 假设不成立。