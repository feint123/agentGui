# 2026-03-21 权限治理统一化技术改造说明

日期：2026-03-21

关联对象：`AppSettings`、`ToolAuthorizationPolicy`、`SessionExecutionPreferences`、`ConversationAuthorizationPolicyFactory`、`ACPPermissionCenter`、`ACPPermissionPolicyEvaluator`、`AgentLoopToolExecutionCoordinator`、`AgentLoopToolExecutionCoordinatorBuilder`、`ClaudeService+AgenticLoop`、`GitHubCopilotCLIExecutionProvider`、`OpenCodeCLIExecutionProvider`、`SettingsExecutorsView`、`SettingsToolsView`、`ChatView+Actions`、`ChatView+InputArea`

## 0. 文档结论

当前权限控制的根问题，不是某一个开关命名不好，而是权限语义被拆散在三条不同链路里：

1. 全局设置层用 `enableTextEditorTool`、`enableBashTool`、`enableWebSearchTool` 一类布尔位表达“是否可用”。
2. 外部 ACP 执行器用 `ToolAuthorizationPolicy` + `ACPPermissionCenter` 表达“是否需要审批”。
3. 内置执行器长期绕过 ACP 审批中心，形成另一套内置工具执行语义。

结果是：

1. 用户难以理解“全局开关”“局部授权”“审批模式”三者分别控制什么。
2. built-in 与外部执行器的审批体验不一致。
3. `allow always` 无法稳定表达“当前会话后续同类操作免重复审批”。

本次改造的核心结论是：

1. 持久化的全局工具权限开关不再作为风险控制入口，统一收敛为全局默认开启。
2. 风险控制下沉到两层：
   1. 局部运行时授权，决定某个场景里哪些工具真正可用。
   2. 审批模式，决定 Bash / Web 这类高风险操作是否需要人工确认。
3. built-in 与外部 ACP 执行器统一接入同一个审批中心和同一套审批语义。
4. `allow always` 的作用域明确为“当前会话 + 当前审批范围”，不会越权扩大到全局持久化配置。

一句话概括：

> 全局设置负责提供能力基线，局部授权负责裁剪可用范围，统一审批中心负责拦截高风险动作。

## 1. 现状问题

### 1.1 全局布尔开关与局部授权语义混杂

当前 `AppSettings` 中的工具布尔位同时承担了两个职责：

1. 持久化设置页上的“全局开关”。
2. 后台任务、渠道场景和运行时快照里的“局部裁剪结果”。

这会带来一个常见误解：如果直接删除这些字段，后台任务和渠道场景的局部授权也会失去承载位置。

因此这次改造不能简单理解为“删字段”，而必须拆开两个层次：

1. 持久化全局设置：一律归一为 all-on。
2. 运行时派生设置：仍可复用这些布尔位表达局部裁剪结果。

### 1.2 审批链路分裂

当前系统里至少存在两套审批语义：

1. 外部执行器通过 ACP permission request 进入 `ACPPermissionCenter`。
2. built-in 工具执行没有统一走 `ACPPermissionCenter`，导致审批入口、状态和 UI 行为不一致。

直接后果是：

1. 同样是 Bash 或 Web 操作，不同执行器的拦截点和体验不一致。
2. `allow once` / `allow always` 的语义无法对齐。
3. pending approval、取消、记忆授权都无法共享。

### 1.3 旧审批模式不符合现在的产品语义

旧的 `ToolApprovalMode` 使用 `none`、`subjectPolicy`、`alwaysRequireHuman` 三态，更多是在表达实现细节，而不是用户视角的策略。

用户真正需要的只有两档：

1. `default approvals`：需要审批 Bash 与 Web 操作。
2. `bypass approvals`：不做操作审批。

因此需要把旧语义压缩成用户可解释、跨执行器可统一的一致模型。

## 2. 改造目标

本次改造目标如下：

1. 去除设置页对全局工具权限开关的依赖，默认全局能力开启。
2. 保留局部运行时授权裁剪能力，不影响后台任务、渠道和其他隔离场景。
3. built-in 与外部 ACP 执行器统一进入同一个审批中心。
4. 审批模式统一为 `default approvals` 与 `bypass approvals` 两档。
5. `default approvals` 下只审批 shell / web 范围的操作。
6. 审批 UI 保留 `allow once` 与 `allow always` 区分。
7. `allow always` 仅在当前会话内、当前审批范围内生效，避免变成跨会话长期授权。

## 3. 设计原则

### 3.1 全局能力基线与局部授权分离

全局设置不再承担高风险控制职责，只表达“产品默认具备这些工具能力”。

真正的风险控制分两步：

1. 局部运行时授权先决定当前场景是否允许这个工具出现。
2. 如果工具属于高风险范围，再由审批中心决定是否允许执行。

### 3.2 审批必须在统一门口发生

审批逻辑不应散落在单个工具实现、单个 provider 或单个 UI 按钮中，而应挂在统一执行门口：

1. 外部执行器继续经由 `ACPPermissionCenter.resolve(...)`。
2. built-in 在 `AgentLoopToolExecutionCoordinatorBuilder` 里统一走 `resolveBuiltInToolApproval(...)`。

这样才能保证：

1. pending request 的生命周期一致。
2. 取消和拒绝行为一致。
3. remembered grant 的作用域一致。

### 3.3 remembered grant 只做会话级短期记忆

`allow always` 并不等于修改全局设置，更不应持久化成长期授权。

本次设计把它定义为：

1. 以 `localSessionID` 为主作用域。
2. 以 `ToolApprovalScope` 为分类键。
3. 当前会话结束或切换后自然失效。

这样既满足减少重复审批的体验，也不会把一次点击扩大为长期越权。

## 4. 统一权限模型

### 4.1 审批模式

新的 `ToolApprovalMode` 只有两档：

1. `defaultApprovals = "default"`
2. `bypassApprovals = "never"`

兼容规则：

1. 旧值 `on-request`、`auto`、`always`、空值等统一归并到 `defaultApprovals`。
2. 旧值 `never`、`none`、`bypass` 统一归并到 `bypassApprovals`。

这能保证旧配置不会在升级后失效，同时让新语义对用户保持简单清晰。

### 4.2 审批范围

新增 `ToolApprovalScope`：

1. `shell`
2. `web`

判定规则由 `ACPPermissionPolicyEvaluator.approvalScope(...)` 统一提供：

1. 执行命令类工具归入 `shell`。
2. `web_fetch` 归入 `web`。
3. `web_search` 或带有 web / browser 语义的搜索工具归入 `web`。
4. 只读文件工具、文本编辑工具、LSP 工具不进入审批范围。

### 4.3 remembered grant 规则

`allow always` 的生效规则如下：

1. 只对 `default approvals` 模式有效。
2. 只对存在明确 `ToolApprovalScope` 的操作有效。
3. 以 `localSessionID + ToolApprovalScope` 作为记忆键。
4. 命中 remembered grant 后，优先自动选择 `allowAlways`，不再排队人工审批。

## 5. 架构调整

### 5.1 设置层

`AppSettings` 新增 `builtInDefaultApprovalMode`，作为 built-in 默认审批策略。

同时新增 `normalizeGlobalToolPermissionBaseline()`，在 `AppSettings.getOrCreate(...)` 中自动执行：

1. `enableTextEditorTool = true`
2. `enableBashTool = true`
3. `enableWebSearchTool = true`
4. `enableWebFetchTool = true`
5. `enableLSPTools = true`

这一步的目的不是让运行时永远不裁剪，而是强制持久化全局设置回到一致基线。

### 5.2 会话偏好层

`SessionExecutionPreferences` 新增 `builtInApprovalMode`，用于会话级覆盖 built-in 审批模式。

解析规则由 `SessionExecutionPreferencesResolver.builtInApprovalMode(...)` 提供：

1. 优先使用会话覆盖值。
2. 没有覆盖值时回退到 `AppSettings.builtInDefaultApprovalMode`。

### 5.3 built-in 执行链

`AgentLoopRunRequest` 新增 `toolApprovalMode`，并在以下入口透传：

1. 主 built-in 对话：使用解析后的 built-in 审批模式。
2. subagent：默认 `bypassApprovals`。
3. background task：默认 `bypassApprovals`。
4. remote / channel / core loop：默认 `bypassApprovals`。

统一审批拦截点落在：

1. `AgentLoopToolExecutionCoordinator` 新增 `requestApprovalIfNeeded` dependency。
2. `AgentLoopToolExecutionCoordinatorBuilder` 负责根据当前 `toolApprovalMode` 调用 `ACPPermissionCenter.resolveBuiltInToolApproval(...)`。

### 5.4 外部执行器链

`GitHubCopilotCLIExecutionProvider` 与 `OpenCodeCLIExecutionProvider` 不再自行解释旧三态审批语义，而统一使用 `ToolApprovalMode.resolved(from:)`。

这样 built-in 与外部执行器最终都会落到：

1. 同样的审批模式值。
2. 同样的审批中心。
3. 同样的 remembered grant 行为。

### 5.5 审批中心

`ACPPermissionCenter` 成为唯一的统一审批中心，新增两类内部状态：

1. `requestScopes`：记录 pending request 对应的审批范围。
2. `rememberedSessionApprovals`：记录当前会话已经 `allow always` 的范围集合。

同时新增 built-in 专用入口：

1. `resolveBuiltInToolApproval(...)`

built-in 固定提供三种选项：

1. `reject-once`
2. `allow-once`
3. `allow-always`

当用户选择 `allow-always` 时，把对应 scope 写入当前会话的 remembered set。

## 6. UI 改造

### 6.1 设置页

`SettingsToolsView` 不再展示全局工具开关，而改为：

1. 说明全局能力默认开启。
2. 强调风险控制由局部授权和审批模式负责。
3. 保留工作目录、Ollama、LSP 路由与管理这类配置项。

`SettingsExecutorsView` 新增 built-in 默认审批模式设置，使用与外部执行器一致的两档选项：

1. `default approvals`
2. `bypass approvals`

### 6.2 会话输入区

`ChatView+Actions` 与 `ChatView+InputArea` 新增 built-in 会话级审批模式绑定与 picker。

这样用户可以在当前会话里单独调整 built-in 审批模式，而不影响全局默认值。

### 6.3 会话生命周期

built-in provider 在 `cancel(...)` 与 `resetSessionState(...)` 中会主动取消当前会话的 pending permission request，避免切换或取消时留下悬挂审批。

## 7. 迁移策略

### 7.1 配置兼容

旧配置升级时不需要迁移脚本，原因是：

1. `ToolApprovalMode` 通过自定义 `Codable` 自动兼容旧值。
2. 全局工具开关在读取 `AppSettings` 时自动归一为 true。
3. 会话级 built-in 审批模式缺省时自动回退到新的全局字段。

### 7.2 行为兼容

本次改造刻意保留以下行为：

1. 局部运行时授权仍可裁剪工具集。
2. 背景任务与远端场景默认继续跳过人工审批。
3. 外部执行器现有 approval mode 配置值不会失效。

## 8. 验证计划

本次改造至少需要覆盖以下测试面：

1. `ACPPermissionCenterTests`
   1. 高风险工具在 `default approvals` 下会排队审批。
   2. 只读工具不会排队审批。
   3. `allow always` 能让同会话同 scope 的后续请求自动放行。
2. `AgentLoopToolExecutionCoordinatorTests`
   1. built-in 审批拒绝会在执行前短路。
3. `GitHubCopilotCLIExecutionProviderTests`
   1. 外部执行器旧配置值会映射到新的两档审批模式。
4. `OpenCodeCLIExecutionProviderTests`
   1. OpenCode 与 Copilot 保持一致映射规则。
5. `SessionExecutionPreferencesTests`
   1. built-in 审批模式的全局回退与会话覆盖正确。

此外还需要通过 UI 与设置检查验证：

1. 设置页已经不再出现全局工具权限 toggle。
2. built-in 在设置页和会话输入区都能配置审批模式。

## 9. 风险与边界

### 9.1 不在本次范围内的内容

本次改造不包含以下内容：

1. 不改变后台任务或远端渠道默认 `bypass approvals` 的产品决策。
2. 不把 `allow always` 做成跨会话持久化授权。
3. 不把局部运行时授权字段从底层模型中删除。

### 9.2 主要风险

需要重点关注以下风险：

1. 如果误把全局布尔位完全删除，会破坏后台任务和渠道的局部裁剪链路。
2. 如果 built-in 审批拦截点放在具体工具实现里，会再次形成分裂语义。
3. 如果 `allow always` 的作用域设计过大，会把一次会话级确认升级成长期越权。

## 10. 最终建议

本次权限治理改造的关键不在“删掉几个 toggle”，而在于把系统收敛成三层清晰模型：

1. 全局能力基线：默认开启，不承担风险控制。
2. 局部运行时授权：决定某个场景里工具是否可用。
3. 统一审批中心：对 shell / web 这种高风险范围做会话级审批与记忆授权。

只有这样，系统才能同时满足：

1. 用户体验上更简单。
2. built-in 与外部执行器行为一致。
3. 后台任务、渠道和其他局部场景继续可控。
4. 审批语义可扩展，可继续增加新的 scope 或 provider，而不再回到分散判断的旧结构。