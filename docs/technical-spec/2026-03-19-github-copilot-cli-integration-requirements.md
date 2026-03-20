# GitHub Copilot CLI 接入与双执行器会话技术需求文档

日期：2026-03-19

## 当前实现摘要（2026-03-20）

当前仓库已完成第一阶段双执行器主链，具体包括：

1. `AppSettings.defaultExecutionProviderID` 与 `Session.defaultExecutionProviderID` 已落地，并用于全局默认值与会话级覆盖。
2. 设置窗口已新增“执行器”页，可配置 GitHub Copilot CLI 可执行文件、默认模型、自定义 agent 名称与 ACP stdio 开关。
3. 聊天输入区已加入执行器选择器；新建会话会继承全局默认执行器，发送前切换会直接写回当前会话。
4. 消息发送、重试、编辑重发与取消已通过 `ConversationExecutionProviderRegistry` 路由到 `BuiltInConversationExecutionProvider` 或 `GitHubCopilotCLIExecutionProvider`。
5. GitHub Copilot CLI 路径当前仅支持 `copilot --acp --stdio`，并通过 `ACPManagedClientRuntime` 与 `ACPLocalClientHandler` 复用本地文件、终端与权限桥接。
6. Copilot ACP `session/update` 已归一化为本地消息增量、thinking 内容与工具调用状态，从而继续复用现有聊天投影与执行 Theater。

## 1. 结论先行

基于当前 `agentGui` 已具备的 ACP 基础设施，以及 GitHub Copilot CLI 在 2026-03 的官方能力边界，推荐将“接入 GitHub Copilot CLI”定义为一个 **新的会话执行器接入项目**，而不是一个简单的 shell 工具封装。

建议结论如下：

1. 产品上，在聊天输入区下方新增“执行器选择器”，至少提供 `内置 Agent` 与 `GitHub Copilot CLI` 两个选项。
2. 技术上，**首选通过 Copilot CLI 的 ACP server 模式接入**，即使用 `copilot --acp --stdio`，而不是抓取交互式终端 UI。
3. `agentGui` 现有 `ACPManagedClientRuntime`、`ACPLocalClientHandler`、权限策略、终端托管能力可以直接复用，作为 Copilot CLI 的本地能力桥。
4. 会话层需要把“模型提供方”升级为“执行器提供方”，因为 `GitHub Copilot CLI` 本质上不是另一个大模型 provider，而是一个带工具、权限、会话、子代理、GitHub MCP 能力的外部 agent runtime。
5. 现有文档中规划的 `DelegationRuntime` / `ACPWorkerProvider` 方向，与本次接入高度一致；本需求应以该方向为主线推进，避免再新增一条平行运行时。
6. 不推荐把 MVP 做成终端屏幕嵌入或 alt-screen 抓屏方案。该方案对 Copilot CLI 的计划模式、审批、任务视图、子代理和交互控件不稳定，维护成本高。

一句话概括：

> 本项目不是“把 Copilot CLI 当命令跑起来”，而是“把 Copilot CLI 作为 ACP 外部执行器接入 agentGui 的会话执行平面”。

## 2. 背景与目标

当前 `agentGui` 已具备两类关键资产：

1. 一套本地主链聊天与 agent-loop 能力，现阶段主要通过 `ClaudeService` 驱动。
2. 一套已经成型的 ACP client 基础设施，包含传输、连接、消息路由、进程托管、本地文件/终端/权限回调桥接。

用户的新需求不是简单“增加一个模型”，而是希望在同一个聊天产品里支持两种执行路径：

1. 继续走应用自身的内置 agent。
2. 切换到 GitHub Copilot CLI 作为外部 agent。

本需求的核心目标是：

1. 在同一个会话产品中，让用户显式选择本轮对话或本会话使用哪一个执行器。
2. 保持现有聊天 UI、会话持久化、权限控制、工具可观测性和消息投影框架尽量不被推翻。
3. 复用现有 ACP 基础设施，避免再引入一套新的外部 agent 通信协议。
4. 为后续接入更多 ACP 兼容执行器保留统一抽象，而不是把 GitHub Copilot CLI 写成特例。

非目标：

1. 第一阶段不要求把 Copilot CLI 的全部交互 UI 原样映射进 `agentGui`。
2. 第一阶段不要求支持 Copilot CLI 的全部实验特性，例如完整插件市场、计划审批面板、fleet 等。
3. 第一阶段不要求替换当前内置 agent 主链，只要求实现双执行器并存与可切换。

## 3. 调研结论

### 3.1 GitHub Copilot CLI 当前可用能力

结合 GitHub 官方文档与公开仓库更新记录，可以确认以下事实：

1. Copilot CLI 已 GA，可运行于 macOS、Linux、Windows。
2. CLI 支持两类使用方式：
   - 交互式会话
   - 程序化 prompt mode，即 `copilot -p` / `--prompt`
3. CLI 已支持 `--output-format json`，适合程序化输出消费。
4. CLI 支持 `--model` 指定模型，默认模型由 GitHub 控制，当前默认文档仍指向 Claude Sonnet 4.5，但官方保留随时调整默认值的权利。
5. CLI 支持细粒度工具审批参数，例如 `--allow-all-tools`、`--allow-tool`、`--deny-tool`。
6. CLI 支持 custom instructions、custom agents、skills、MCP servers、GitHub MCP 能力、LSP 配置，以及后台 delegate / task 视图等能力。
7. 更关键的是，**Copilot CLI 已官方支持 ACP server**，启动方式为：

```bash
copilot --acp --stdio
```

8. 官方文档明确给出了 `initialize -> newSession -> prompt -> sessionUpdate` 的 ACP 集成示例。
9. Copilot CLI 的 ACP server 当前仍处于 public preview，意味着协议与行为可能变化，需要版本兼容策略。

### 3.2 为什么 ACP 是主接入路径

ACP 路径优于终端抓屏，原因如下：

1. 现有 `agentGui` 已有 NDJSON over stdio 的 ACP transport，与 Copilot CLI 的 ACP server 模式直接兼容。
2. ACP 可以获得结构化 `session/update` 增量事件，而不是从终端文本中猜测当前状态。
3. ACP 可以直接接住 Copilot CLI 的权限请求、文件读写、终端创建与输出，不需要把 alt-screen 当成 UI 协议解析。
4. ACP 更适合做会话恢复、取消、重试、会话 ID 绑定和统一可观测性。
5. 终端抓屏无法稳定承载计划模式、子代理、审批、表单、任务列表、MCP 事件等高阶语义。

### 3.3 prompt mode 的定位

`copilot -p` 不是主方案，但仍然有价值：

1. 可作为 ACP 不可用时的降级路径。
2. 可用于快速健康检查、安装验证、认证验证。
3. 可用于某些“单次请求、无需长期会话状态”的脚本型场景。

但它不适合成为聊天主链，原因是：

1. 多轮会话状态控制弱于 ACP 模式。
2. 工具事件、权限请求、终端生命周期、子代理与后台任务投影能力不如 ACP 直接。
3. 聊天产品若长期基于 prompt mode 拼装，会把会话和增量状态管理重新做一遍。

### 3.4 与当前仓库的契合点

当前仓库里已有以下现成能力，可以直接复用：

1. `Services/ACP/ACPManagedClientRuntime.swift`
   - 已能拉起外部进程并建立 ACP client runtime。
2. `Services/ACP/ACPLocalClientHandler.swift`
   - 已能响应 `request_permission`、文件读写、终端创建/输出/等待/终止/释放。
3. `Views/ChatView+InputArea.swift`
   - 输入区已经有辅助 surface、chips、上下文注入能力，适合增加“执行器选择器”。
4. `Views/ChatView+Actions.swift`
   - 当前发送消息主链集中，适合把“发送到内置 agent / 发送到 Copilot CLI”在此处分流。
5. `Models/AppSettings.swift`
   - 已承载模型、LSP、代理、后台任务等运行时设置，适合作为 Copilot CLI 安装与策略配置入口。
6. 已有委托架构设计文档
   - `DelegationRuntime`
   - `DelegationCoordinator`
   - `LocalLoopWorkerProvider`
   - `ACPWorkerProvider`

这说明本项目不是从零开始，而是正好落在仓库近期已明确的演进方向上。

## 4. 产品需求

### 4.1 输入区执行器选择器

聊天输入区下方新增执行器选择器，要求如下：

1. 默认值为 `内置 Agent`。
2. 备选项至少包括：
   - `内置 Agent`
   - `GitHub Copilot CLI`
3. 选择器应展示当前可用状态：
   - 已安装
   - 未安装
   - 未登录
   - 不可用
4. 若 `GitHub Copilot CLI` 不可用，选项可见但不可执行，并提供原因。
5. 切换执行器只影响后续发送的消息，不篡改历史消息执行器归属。

推荐 UI 文案：

1. `执行器：内置 Agent`
2. `执行器：GitHub Copilot CLI`

不建议使用“模型选择器”去承载这个能力，因为语义层级不同。

### 4.2 会话绑定规则

需要同时支持：

1. **会话级默认执行器**
   - 每个聊天会话保存一个默认执行器。
2. **发送前可切换**
   - 用户可在输入区切换后再发送下一条消息。

MVP 推荐规则：

1. 每个 `Session` 记录 `defaultExecutionProvider`。
2. 输入区切换时立即更新会话默认值。
3. 新建会话继承全局默认值。

### 4.3 发送与接收体验

当用户选择 `GitHub Copilot CLI` 后，发送行为应满足：

1. 仍使用现有聊天列表呈现消息，不弹出独立窗口。
2. assistant 回复应支持增量流式投影。
3. 若 Copilot CLI 发起工具调用或权限请求，应在现有 tool/timeline 表达体系中投影，而不是静默发生。
4. 如果外部 agent 在运行中需要用户确认，应在 `agentGui` 内给出统一审批 UI。
5. 用户应能取消当前回复。
6. 出错后应允许重试，并保留错误原因。

### 4.4 设置页需求

需要新增 GitHub Copilot CLI 专用设置区，至少包含：

1. 可执行文件路径
   - 自动发现 `copilot`
   - 允许自定义覆盖路径
2. 安装状态检测
3. 认证状态检测
4. ACP 启动模式
   - MVP 固定 `stdio`
5. 默认工作目录策略
6. 默认审批策略
   - 建议映射到现有 `ToolAuthorizationPolicy`
7. 可选默认模型
8. 可选自定义 agent 名称
9. 版本信息展示

### 4.5 状态提示与可观测性

界面至少需要展示：

1. 当前执行器。
2. Copilot CLI 安装/登录/启动失败原因。
3. 当前外部 session 是否已建立。
4. 当前任务是否正在等待权限审批。
5. 外部 agent 的最近进度摘要。

## 5. 技术架构要求

### 5.1 新的抽象层：会话执行器

当前主链更多是“模型 + ClaudeService”语义，本项目要求提升到“会话执行器”语义。

建议新增统一协议：

```swift
protocol ConversationExecutionProvider: Sendable {
    var id: ConversationExecutionProviderID { get }
    func send(
        session: Session,
        prompt: ConversationPrompt,
        modelContext: ModelContext
    ) async throws -> ConversationExecutionHandle
    func cancel(sessionID: String) async
}
```

至少实现两个 provider：

1. `BuiltInAgentExecutionProvider`
2. `GitHubCopilotCLIExecutionProvider`

### 5.2 GitHub Copilot CLI provider 的实现边界

`GitHubCopilotCLIExecutionProvider` 应基于 ACP，承担以下职责：

1. 启动或复用 `copilot --acp --stdio` 进程。
2. 完成 `initialize` 握手。
3. 创建、恢复、关闭 Copilot session。
4. 把本地用户输入映射为 ACP `prompt`。
5. 接收 `session/update` 增量并投影为本地消息/事件。
6. 接住 Copilot 的权限、文件、终端回调，并通过现有 `ACPLocalClientHandler` 完成桥接。
7. 把 ACP 错误、进程退出、认证失败、策略拒绝等映射成统一错误模型。

### 5.3 会话桥接层

建议增加 `CopilotSessionBridge` 或等价模块，负责处理本地 Session 与外部 session ID 的映射。

至少需要保存：

1. 本地 `session.sessionId`
2. 外部 `copilotSessionID`
3. 外部 CLI 版本
4. 外部执行器类型
5. 最近一次成功握手时间
6. 当前 session 使用的模型与 agent

### 5.4 事件归一化层

Copilot CLI 通过 ACP 发回的事件需要被归一化为本地事件流。建议统一成：

1. `assistantTextDelta`
2. `toolCallStarted`
3. `toolCallUpdated`
4. `toolCallCompleted`
5. `permissionRequested`
6. `statusChanged`
7. `taskCompleted`
8. `taskFailed`

这样可以最大化复用现有 tool call bubble、timeline、subagent card 等投影能力。

### 5.5 输入区与发送主链改造点

最小改造点明确如下：

1. `Views/ChatView+InputArea.swift`
   - 增加执行器选择器 UI。
2. `Views/ChatView+Actions.swift`
   - 当前 `sendMessage()` 需要按执行器分流，而不是固定进入 `claudeService.sendMessage(...)`。
3. `Models/AppSettings.swift`
   - 增加 Copilot CLI 相关配置字段。
4. `Session` 或等价持久化模型
   - 增加默认执行器字段。

### 5.6 与 DelegationRuntime 的关系

本项目必须遵守“统一执行平面”原则，不应再开一条平行链路。

推荐关系如下：

1. 对话主链的“执行器选择”与委托执行平面的 `WorkerProvider` 是同一演进方向的两个入口。
2. `GitHubCopilotCLIExecutionProvider` 的底层可进一步沉淀为 `ACPWorkerProvider` 的特化实现。
3. 后续若把 Copilot CLI 暴露为后台代理、研究代理、PR 代理，也应复用同一 provider 与事件模型。

换句话说：

1. 聊天执行器是用户显式选择入口。
2. Delegation worker 是系统内部执行入口。
3. 两者最终应落到同一外部 runtime 适配层。

## 6. 安装、认证与权限要求

### 6.1 安装检测

系统需要检测：

1. `copilot` 是否在 PATH 中。
2. 用户配置的自定义路径是否存在且可执行。
3. CLI 版本是否满足最低支持版本。

最低版本策略建议：

1. MVP 要求 ACP server 可用。
2. 建议要求支持 `--acp`、`session/update`、基础 shell/file permission 回调的稳定版本。
3. 若版本过低，应提示升级，而不是尝试兼容不可控行为。

### 6.2 认证检测

需要支持以下认证来源识别：

1. 用户已在本机 CLI 完成登录。
2. 用户通过 `COPILOT_GITHUB_TOKEN`、`GH_TOKEN` 或 `GITHUB_TOKEN` 提供 token。
3. 组织策略关闭 Copilot CLI 时，应给出明确错误。

MVP 不要求 `agentGui` 自己重做完整登录流程，但至少要支持：

1. 检测未登录。
2. 提示用户前往 CLI 完成登录。
3. 在 ACP 模式下若触发 terminal-auth 或相关认证流程，能正确展示状态。

### 6.3 权限桥接

Copilot CLI 自身有工具权限体系，`agentGui` 也有 `ToolAuthorizationPolicy`。两者需要统一，不允许产生“双重失控”。

推荐规则：

1. `agentGui` 是宿主，最终权限边界以宿主为准。
2. Copilot CLI 发来的 `request_permission`，统一走 `agentGui` 的审批 UI。
3. 默认不使用 `--allow-all-tools`。
4. 默认只授予工作区内文件访问与受控 shell/网络能力。
5. 所有 allow/deny 决策都要被审计。

### 6.4 工作区与信任目录

Copilot CLI 官方强调 trusted directories。`agentGui` 必须落实：

1. 默认仅将当前工作区目录作为允许根目录。
2. 不默认暴露用户 home 目录。
3. 多工作区支持放到后续阶段。

## 7. 持久化模型需求

至少新增以下状态：

### 7.1 AppSettings 级别

1. `defaultExecutionProvider`
2. `copilotCLIExecutablePath`
3. `copilotCLIUsePathDiscovery`
4. `copilotCLIDefaultModel`
5. `copilotCLIDefaultAgent`
6. `copilotCLIApprovalProfile`
7. `copilotCLILastKnownVersion`

### 7.2 Session 级别

1. `executionProvider`
2. `externalRuntimeKind`
3. `externalSessionID`
4. `externalSessionState`

### 7.3 审计记录

建议记录：

1. 启动外部 runtime 的命令摘要
2. 握手成功/失败
3. 权限请求与决策
4. 终端创建与结束
5. 外部会话恢复与关闭

## 8. 交互与投影要求

### 8.1 消息列表

需要在 assistant 消息或会话头部显示执行器来源，例如：

1. `内置 Agent`
2. `GitHub Copilot CLI`

### 8.2 Tool Call 投影

若 Copilot CLI 通过 ACP 触发文件、shell、MCP、GitHub 等动作，必须投影到现有 tool call 体系，至少保证：

1. 用户能看见做了什么。
2. 用户能知道是否在等待审批。
3. 用户能看到执行结果或失败原因。

### 8.3 进度与子任务

Copilot CLI 已有 background agents、subagents、tasks 等概念。MVP 不要求全量还原，但至少需要：

1. 能显示进度状态。
2. 能显示有无后台任务或子任务。
3. 对无法细分投影的事件，至少以 timeline 文本事件呈现，不得静默丢失。

## 9. 风险与限制

### 9.1 ACP server 仍在 public preview

这是当前最大外部风险。

应对要求：

1. 引入版本门槛与能力探测。
2. 将 Copilot CLI 适配层与通用 ACP 层隔离，避免协议变动污染全局。
3. 对未知事件类型做前向兼容处理。

### 9.2 权限模型重叠

宿主与 Copilot CLI 都有权限概念，如果边界不清，会产生：

1. 一次操作被重复审批。
2. 或更糟的是某一层绕过另一层限制。

因此必须坚持“宿主最终裁决”。

### 9.3 组织策略与订阅限制

用户即便本地安装了 CLI，也可能因为：

1. 没有 Copilot 订阅。
2. 所属组织禁用了 Copilot CLI。
3. 某些模型无 entitlement。

导致该执行器不可用。

### 9.4 语义层级不同

`内置 Agent` 当前更接近“模型驱动的应用内 agent-loop”，而 Copilot CLI 是“外部 agent runtime”。

若继续沿用旧的 `selectedModel` 思维来接这个能力，会导致：

1. 设置项混乱。
2. 发送链路分叉。
3. 后续再接更多外部 agent 时继续膨胀。

所以本项目必须推动“执行器层抽象”落地。

## 10. 实施范围建议

### 10.1 MVP

MVP 建议只做以下范围：

1. 输入区执行器选择器。
2. 设置页中的安装/认证/路径检测。
3. 通过 ACP 启动 Copilot CLI。
4. 单会话绑定一个外部 Copilot session。
5. 文本流式回复。
6. 基础权限请求桥接。
7. 基础文件与终端工具桥接。
8. 失败、取消、重试。

MVP 不做：

1. prompt mode 降级。
2. 复杂计划模式 UI 还原。
3. `/tasks`、`/delegate`、背景代理完整投影。
4. 全量 Copilot custom agents 管理 UI。

### 10.2 第二阶段

1. prompt mode 作为降级通道。
2. 会话恢复与 resume。
3. Copilot model / agent 选择器。
4. 与 DelegationRuntime 打通，允许 Copilot CLI 作为后台 worker。
5. GitHub MCP 事件的 richer UI 投影。

### 10.3 第三阶段

1. 将 Copilot CLI 纳入统一 `DelegationWorkerProvider` 注册体系。
2. 支持同一会话中显式委托给 Copilot 子执行器。
3. 支持任务列表、后台任务和多执行器协作。

## 11. 验收标准

以下条件同时满足，才算本需求完成：

1. 用户能在聊天输入区下方明确选择 `内置 Agent` 或 `GitHub Copilot CLI`。
2. 未安装或未登录 Copilot CLI 时，UI 能明确提示不可用原因。
3. 选择 `GitHub Copilot CLI` 后，发送消息能通过 ACP 成功建立外部 session 并返回流式结果。
4. Copilot CLI 发起的权限请求能在 `agentGui` 内完成审批，而不是落回外部终端交互。
5. 文件与终端相关回调能通过现有 ACP 本地 handler 正常执行。
6. 用户能取消当前外部回复，并看到明确状态变化。
7. 会话能持久化当前默认执行器与外部 session 绑定信息。
8. 不破坏现有 `内置 Agent` 主链。
9. 不引入终端抓屏或 alt-screen 解析作为主运行机制。

## 12. 推荐后续实现顺序

建议实施顺序如下：

1. 先建立 `ConversationExecutionProvider` 抽象与 Session 执行器字段。
2. 再接入 GitHub Copilot CLI 的安装/认证探测。
3. 然后实现 ACP 启动、握手、session 映射与最小文本流投影。
4. 最后接权限桥接、tool call 投影与设置页完善。

这样可以先把系统的抽象层修正到正确方向，再增量接入外部 runtime，避免后续返工。