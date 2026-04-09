# agentGui Built-in Agent Tool 设计增强方案

> 基于 Claude Code 源码深度分析（2026-04-02）
> 对比目标: agentGui 现有 `ToolDefinition` / `ToolRegistry` / `ToolExecutionHookPipeline` 体系

---

## 背景

通过阅读 Claude Code (claude-code-source-code-main) 的完整工具架构，识别到 agentGui 在 built-in agent 工具层面存在若干可系统性提升的设计空白。本文档将差距归纳为 12 个独立 Feature，每个 Feature 可独立实现、独立测试，互不阻塞。

---

## 现状摘要

| 维度 | agentGui 现状 | Claude Code |
|------|--------------|-------------|
| 工具注册 | `ToolRegistry` + `ToolDefinition` | `Tool<Input,Output,P>` 泛型协议 |
| 暴露控制 | 全量暴露给 LLM | `shouldDefer` / `alwaysLoad` 分级 |
| 权限层 | `ToolAuthorizationDescriptor` + riskTier | `validateInput` + `checkPermissions` 两级 |
| Hooks | `ToolExecutionHookPipeline` (pre/post/failure) | PreToolUse/PostToolUse frontmatter hooks |
| 并发 | `isConcurrencySafe` + `ToolConcurrencyBatchPlanner` | 同上 + `interruptBehavior` |
| 内置代理 | GeneralPurpose | General/Explore/Plan/Verification/CodeGuide |
| Agent Memory | 全局 MemoryRecord | per-agentType 三范围目录 |
| 团队消息 | SendMessage | SendMessage + 语义消息类型 |
| 任务管理 | BackgroundAgentTask | Task v2 (Create/Get/List/Update/Stop/Output) |
| Plan Mode | ExecutionPlan 模型层 | EnterPlanMode/ExitPlanMode **工具** |
| 工具搜索 | 无 | `ToolSearchTool` (延迟工具按需发现) |
| 结果预算 | `ToolResultBudgetController` | ContentReplacementState (跨 subagent 透传) |

---

## Feature 列表

---

### Feature 1 — 工具延迟加载与按需发现

**问题**  
agentGui 当前将所有工具定义一次性注入 system prompt，在工具数量增长（LSP、MCP、multi-agent）时会消耗大量 context token，并可能让 LLM 在不需要专用工具时仍"看见"它们。

**Claude Code 参考**  
- `Tool.shouldDefer: Bool` — 工具标记为延迟，不进入初始工具列表
- `Tool.alwaysLoad: Bool` — 强制进入初始列表（MCP `_meta["anthropic/alwaysLoad"]`）
- `ToolSearchTool` — 专用工具，接受 `query` 参数，按关键词或 `select:<name>` 直接激活延迟工具
- `Tool.searchHint: String` — 3–10 词的 capability phrase，供关键词匹配

**agentGui 需要做的**

1. `ToolDefinition` 新增字段：
   ```swift
   var loadPolicy: ToolLoadPolicy  // .eager | .deferred | .alwaysEager
   var searchHint: String?         // 供 ToolSearchTool 关键词匹配
   ```
2. `ToolsetResolver` 拆分为两份工具列表：eagerly-exposed list（注入 prompt）+ deferred pool
3. 新建内置工具 `ToolSearchTool`（`tool_search`）：
   - 输入: `query: String, max_results: Int?`
   - 从 deferred pool 按 `searchHint` + description 关键词打分，返回 top-k 工具名
   - 支持 `select:<name>` 直接激活
4. 新增 `toolSearchEnabled` AppSettings 开关，默认**关闭**，等工具数 > 阈值时自动建议开启

**收益**  
- 减少空跑 token ~30%（实测 Claude Code 数据：延迟 20+ 低频工具）
- LLM 调用精准工具集而非"扫描全量"

---

### Feature 2 — 工具活动描述与 UI 信息增强

**问题**  
Spinner / 进度列表仅显示 `displayName`，无法反映"正在做什么"。结果列表也缺少 compact summary 和 trailing tag（超时提示、模型标识等）。

**Claude Code 参考**  
- `Tool.getActivityDescription(input:) -> String?` — 例："Reading src/foo.ts"
- `Tool.getToolUseSummary(input:) -> String?` — compact view 单行摘要
- `Tool.renderToolUseTag(input:) -> ReactNode?` — 工具结果后的 badge（超时/模型名）
- `Tool.isResultTruncated(output:) -> Bool` — 控制"点击展开"交互

**agentGui 需要做的**

1. `ToolDefinition` 新增：
   ```swift
   var activityDescriptionBuilder: ((any Encodable) -> String?)?   // "Reading api.swift"
   var toolUseSummaryBuilder: ((any Encodable) -> String?)?         // "3 files changed"
   var trailingTagBuilder: ((any Encodable) -> String?)?            // "timed out · 30s"
   var isResultTruncated: ((any ToolExecutionResult) -> Bool)?
   ```
2. `AgentLoopRoundStreamAssembler` 在 streaming 时调用 `activityDescriptionBuilder` 刷新 spinner text
3. `ChatView` / `ToolCall` SwiftUI 渲染层使用 `trailingTag` 在工具结果右侧显示 badge
4. 对现有工具（`str_replace_based_edit_tool` / `bash` / `web_fetch`）补全上述 builders

**收益**  
- Spinner 从"文本编辑器…"变为"Editing agentGui/Services/ClaudeService.swift"
- 用户一眼可见工具结果摘要，无需展开

---

### Feature 3 — 工具并发与中断行为精细化

**问题**  
`ToolConcurrencyBatchPlanner` 仅识别 `isConcurrencySafe`，无法区分"应立即取消"还是"应先等结果再处理新消息"；也没有 per-input 的破坏性评估。

**Claude Code 参考**  
- `Tool.interruptBehavior() -> 'cancel' | 'block'` — 用户输入新消息时，cancel 停止工具；block 等待结果再消费新消息
- `Tool.isDestructive(input:) -> Bool` — per-input 破坏性标记（删除/覆盖时为 true）
- `Tool.aliases: [String]?` — 工具别名支持（重命名时向后兼容）

**agentGui 需要做的**

1. 新增枚举：
   ```swift
   enum ToolInterruptBehavior: String, Codable {
       case cancel   // 用户发新消息 → 中止工具
       case block    // 用户发新消息 → 先等工具完成
   }
   ```
2. `ToolDefinition` 新增：
   ```swift
   var interruptBehavior: ToolInterruptBehavior   // default: .block
   var isDestructiveEvaluator: ((any Encodable) -> Bool)?
   var aliases: [String]
   ```
3. `AgentLoopToolExecutionCoordinator` 处理新消息时，按 `interruptBehavior` 决策
4. `ToolRegistry.definition(for:)` 支持 alias 查找
5. 破坏性工具在 `ToolExecutionHookPipeline.preExecute` 触发二次确认（已有 riskTier.high，整合逻辑）

**收益**  
- Bash 长命令可配置为 `cancel`（用户可中断），编辑器操作保持 `block`
- alias 允许无缝重命名工具而不破坏历史对话 replay

---

### Feature 4 — 工具结果预算跨 Subagent 透传

**问题**  
`ToolResultBudgetController` 只在主 agent 线程工作；subagent / background task 独立计算预算，导致大型 subagent 调用可能撑爆整体 context。

**Claude Code 参考**  
- `ToolUseContext.contentReplacementState` — per-conversation ContentReplacementState，subagent 默认从 parent clone，fork subagent 共享以利用 prompt cache
- 主线程一次性初始化，stale UUID key 是惰性的（不会误触发）
- resume 路径从 sidechain records 重建 state

**agentGui 需要做的**

1. 新建 `ToolResultBudgetState`（值类型 Sendable）记录 per-toolCallId 的裁剪决策
2. `AgentLoopRunner` 持有 top-level state；`createSubagentContext` 复制给子 agent
3. `ToolResultBudgetController` 注入 state，对已裁剪的 toolCallId 做 idempotent decisions
4. per-tool maxResultSizeChars 配置（在 `ToolDefinition` 新增 `maxResultSizeChars: Int`，默认 100_000）
5. 超限时保存到 `ToolPayloadStore`，LLM 收到 preview + payload ref（现有机制增强）

**收益**  
- Subagent 结果膨胀不再影响主 agent context
- 可精准控制哪些工具结果可以变大（如 web_fetch/read_payload 永不截断）

---

### Feature 5 — Plan Mode 工具级集成

**问题**  
agentGui 有 `ExecutionPlan` 数据模型，但 Plan Mode 只能由用户手动切换；LLM 无法主动进入"只读规划模式"后再请求批准执行。

**Claude Code 参考**  
- `EnterPlanModeTool` — 无参数，LLM 调用后进入只读权限模式（prePlanMode 存档）
- `ExitPlanModeTool` — 需要用户/协调者批准
- `ToolPermissionContext.prePlanMode` — 进入前的权限模式快照，退出时还原
- `handlePlanModeTransition` — goroutine 安全的状态切换

**agentGui 需要做的**

1. 新增两个内置工具：`enter_plan_mode` 和 `exit_plan_mode`
   - `enter_plan_mode`: 将 session permission mode 切到 `.planOnly`，保存 `prePlanMode`
   - `exit_plan_mode`: 向用户显示审批 UI（ExitPlanModeTool.UI），批准后还原权限
2. `ToolAuthorizationResolver` 在 planOnly 模式下拒绝所有 mutating 工具（riskTier > .readonly）
3. `AgentLoopRunState` 新增 `currentPermissionMode: AgentPermissionMode`
4. 批准 UI 在 `ChatView` 中展示计划摘要 + 允许/拒绝按钮

**收益**  
- LLM 复杂任务可自主进入 plan → review → execute 闭环
- 用户可 review 完整计划再放行，减少"LLM 直接修改文件"的不可逆风险

---

### Feature 6 — 工具执行上下文追踪增强

**问题**  
`ToolCall` 模型已有 `toolExecutionContext`，但其他执行上下文信息（调用链追踪、per-call 决策记录、拒绝累计计数）分散在不同服务里，缺乏统一的运行时上下文对象。

**Claude Code 参考**  
- `ToolUseContext.toolDecisions: Map<toolUseId, {source, decision, timestamp}>` — per-call 记录批准/拒绝
- `QueryChainTracking: {chainId, depth}` — 嵌套调用链 ID 和深度，用于日志和调试
- `localDenialTracking: DenialTrackingState` — 本地拒绝计数（async subagent 无法写主 AppState）
- `fileReadingLimits / globLimits` — per-context 工具读取上限

**agentGui 需要做的**

1. 新建 `AgentLoopExecutionContext`（actor-isolated，跟随 round executor）：
   ```swift
   struct AgentLoopExecutionContext: Sendable {
       var chainID: String              // root session 或 subagent launch ID
       var chainDepth: Int              // nesting depth
       var toolDecisions: [String: ToolDecisionRecord]
       var denialCount: Int
       var fileReadingLimits: ToolReadingLimits?
   }
   ```
2. `AgentLoopRoundExecutor` 初始化时从 parent context 继承，subagent clone 并递增 depth
3. `ToolExecutionHookPipeline` 注入 context，hook 可读取/更新 decisions
4. 达到 denial 阈值时自动 fallback 到交互式确认提示

**收益**  
- 调试 subagent 嵌套调用变得可追溯
- 拒绝计数机制防止 LLM 无限重试被拒工具

---

### Feature 7 — Agent Memory 多范围持久化

**问题**  
agentGui 的 `MemoryRecord` 是全局存储，没有 per-agentType 的隔离。Built-in agent 积累的工作记忆会与用户对话记忆混杂，且跨 session 无法"延续上次进度"。

**Claude Code 参考**  
- 三个范围：`user` (`~/.claude/agent-memory/<agentType>/`)，`project` (`<cwd>/.claude/agent-memory/<agentType>/`)，`local` (project-specific, gitignore)
- `loadAgentMemoryPrompt(agentType, scope)` — 启动时注入到 system prompt
- `agentMemorySnapshot` — 快照机制，resume 时快速恢复状态而无需全量注入

**agentGui 需要做的**

1. 新增 `AgentMemoryScope: user | project | local`
2. `AgentDefinitionDocument` 新增 `memoryScope: AgentMemoryScope`（默认 `.local`）
3. 新建 `AgentMemoryStore` 管理 per-agentType 目录读写
4. `AgentLoopMemoryBootstrapComposer` 在 run 开始时从对应 scope 注入 agent memory prompt
5. 新增两个内置工具：`agent_memory_read` / `agent_memory_write`（仅 built-in agents 可用）
6. `AgentMemoryStore` 支持快照（session 结束时保存，resume 时优先加载快照）

**收益**  
- VerificationAgent 可记忆"上次发现的问题列表"跨任务延续
- PlanAgent 可记忆项目约定，不重复询问

---

### Feature 8 — Agent Team 结构化消息类型

**问题**  
`SendMessage` 工具只支持纯文本消息。多代理团队的协调操作（请求关闭、批准计划）通过自由文本传递，LLM 理解不稳定，也无法在 UI 上展示专有样式。

**Claude Code 参考**  
- `StructuredMessage` discriminated union：
  - `shutdown_request { reason? }`
  - `shutdown_response { request_id, approve, reason? }`
  - `plan_approval_response { request_id, approve, feedback? }`
- 邮箱协议 (`writeToMailbox`) — per-agent 消息队列，poll-based
- broadcast `"*"` — 全体团队广播

**agentGui 需要做的**

1. 在 `SendMessage` 工具的 input schema 新增 `messageType` 枚举字段
2. 新建 `AgentTeamStructuredMessage` Swift enum：
   ```swift
   enum AgentTeamStructuredMessage: Codable {
       case shutdownRequest(reason: String?)
       case shutdownResponse(requestID: String, approve: Bool, reason: String?)
       case planApprovalResponse(requestID: String, approve: Bool, feedback: String?)
       case text(String)
   }
   ```
3. `AgentTeamSessionState` 新增 per-agent 消息队列（mailbox）
4. `SendMessage` 工具执行时路由到目标 mailbox，支持 `"*"` 广播
5. `ChatView` 为 structured message types 展示专用气泡样式（审批卡片等）

**收益**  
- 团队协调（计划审批、优雅关闭）有类型安全保障
- UI 可展示"Agent A 请求批准计划"卡片而非纯文本

---

### Feature 9 — Built-in Agent 扩展：Explore / Plan / Verification

**问题**  
agentGui 只有 GeneralPurpose built-in agent。Claude Code 的实践证明，专用代理在对应场景下成功率远高于通用代理（Verification Agent 专注于破坏性测试，Explore Agent 专注于代码探索）。

**Claude Code 参考**  
- `ExploreAgent` — 专用代码探索，tools 限制为只读工具
- `PlanAgent` — 专用任务规划，`mode: plan`，全程只读
- `VerificationAgent` — 专用验证，禁止写文件，强调对抗性探测（边界值、并发、幂等性）
- 每个代理有详细的 system prompt，显式列出"你的偏见/你的理由化借口"

**agentGui 需要做的**

1. 新增 `ExploreAgentDefinition`：
   - 工具白名单：read / search / LSP query 类工具
   - system prompt：代码探索专用，强调 broad-to-narrow 策略

2. 新增 `PlanAgentDefinition`：
   - `permissionMode: .planOnly`（依赖 Feature 5）
   - system prompt：任务分解专用，以 task board 输出作为交付物

3. 新增 `VerificationAgentDefinition`：
   - 工具黑名单：禁用所有写文件工具（str_replace, bash write operations）
   - system prompt：完整的对抗性测试策略（边界值/并发/幂等/孤儿操作）
   - `allowTmpWrite: true`（允许 /tmp 写入用于测试脚本）
   - 参考 Claude Code `verificationAgent.ts` 的完整 prompt 结构

4. `AgentCatalog` 中注册以上三个 built-in agent，并在 `AgentDefinitionLoader` 中暴露

**收益**  
- 代码探索任务: ExploreAgent 专注搜索，不会误触发编辑工具
- 复杂任务: PlanAgent 先规划再交用户确认，然后切回 GeneralPurpose 执行
- 质量保障: VerificationAgent 跑破坏性测试，填补"自测通过但实际有 bug"的盲区

---

### Feature 10 — Task v2：Agent 可操作的任务管理工具

**问题**  
`BackgroundAgentTask` 是 agentGui 的后台任务模型，但 LLM 运行时无法通过工具调用来管理任务板（创建、更新状态、读取输出）。TodoItem 是扁平结构，缺少层次关系和元数据。

**Claude Code 参考**  
- `TaskCreateTool` — `subject`, `description`, `activeForm`, `metadata`
- `TaskGetTool`, `TaskListTool` — 任务查询
- `TaskUpdateTool` — 状态流转（pending → in_progress → completed/failed）
- `TaskOutputTool` — 读取任务输出（大结果时用 streaming）
- `TaskStopTool` — 中止任务
- `executeTaskCreatedHooks` — 任务创建时触发 hooks
- `activeForm` — present continuous tense，用于 spinner 显示

**agentGui 需要做的**

1. `TodoItem` 扩展（或新建 `AgentTask` model）：
   ```swift
   struct AgentTask: Identifiable, Codable {
       var id: String
       var subject: String
       var description: String
       var activeForm: String?   // "Running tests"
       var status: AgentTaskStatus  // pending|active|completed|failed
       var owner: String?
       var blockedBy: [String]
       var metadata: [String: JSON]
       var outputRef: String?
   }
   ```
2. 实现六个内置工具：`task_create`, `task_get`, `task_list`, `task_update`, `task_stop`, `task_output`
3. `AgentTeamTaskBoard` 作为 session-scoped task store，响应上述工具
4. hooks 集成：task_create 后触发 `ToolExecutionHook` 的 taskCreated 事件
5. UI 集成：AgentTeamWorkbench 的任务板实时反映 task status

**收益**  
- Agent 可自我管理工作列表并向用户展示进度
- 多 agent 协作时可通过任务板协调分工（task owner 字段）

---

### Feature 11 — 工具安全自动分类器接口

**问题**  
`ToolAuthorizationResolver` 的权限决策依赖静态规则（riskTier）。对于"bash 具体指令是否危险"这类动态判断，缺乏工具层面的分类器接口，需要专门实现 BashCommandClassifier 而非通用化。

**Claude Code 参考**  
- `Tool.toAutoClassifierInput(input:) -> unknown` — 返回工具的安全分类输入，供外部分类器消费
  - BashTool 返回: 命令字符串
  - FileEditTool 返回: `"path: content_diff_summary"`
  - AgentTool 返回: `"agent_type: prompt_preview"`
- coordinator mode 的 worker agent 在展示权限对话框前，先等待自动分类器结果

**agentGui 需要做的**

1. `ToolDefinition` 新增：
   ```swift
   var autoClassifierInputBuilder: ((any Encodable) -> String?)?
   ```
2. 新建 `ToolAutoClassifierService`：
   - 接受 `(toolName, classifierInput)` → `ClassificationDecision: safe | review | block`
   - 初始实现：基于规则（BashCommandClassifier 已有逻辑迁移至此）
   - 预留接口：可接入 LLM-based 分类器
3. `ToolExecutionHookPipeline.preExecute` 在 `checkPermissions` 前调用分类器
4. 分类结果缓存在 `AgentLoopExecutionContext.toolDecisions`（Feature 6）

**收益**  
- 危险 bash 命令（`rm -rf`, `git push --force`）在到达权限弹窗之前已被标记
- 分类器接口统一，后续接入 ML 模型只需替换实现

---

### Feature 12 — AgentDefinitionDocument Frontmatter 扩展

**问题**  
`AgentDefinitionDocument` frontmatter 支持有限，无法声明工具白/黑名单、专属 MCP 服务器、hooks 配置、effort level、permission mode 覆盖。这使得自定义代理能力弱于 Claude Code。

**Claude Code 参考**  
- `AgentDefinition.tools: string[]` — 白名单（`["*"]` = 全部）
- `AgentDefinition.disallowedTools: string[]` — 黑名单
- `AgentDefinition.mcpServers: AgentMcpServerSpec[]` — 代理专属 MCP 服务器（启动时连接）
- `AgentDefinition.hooks: HooksSettings` — 代理级别的 PreToolUse/PostToolUse hooks
- `AgentDefinition.effort: EffortValue` — low/medium/high，影响 thinking budget
- `AgentDefinition.model: string` — 覆盖模型（sonnet/opus/haiku）
- `AgentDefinition.mode: PermissionMode` — 覆盖权限模式

**agentGui 需要做的**

1. `AgentDefinitionDocument` 新增 frontmatter 字段：
   ```swift
   struct AgentFrontmatter: Codable {
       var tools: [String]?           // 白名单
       var disallowedTools: [String]? // 黑名单
       var permissionMode: AgentPermissionMode?
       var model: String?             // "sonnet" | "opus" etc
       var effort: AgentEffortLevel?  // .low | .medium | .high
       var hooks: AgentHooksConfig?   // PreToolUse / PostToolUse per-agent
       var mcpServers: [AgentMcpServerSpec]? // 代理专属 MCP
   }
   ```
2. `AgentDefinitionLoader` 解析以上字段并传递给 `AgentLoopRunner`
3. `AuthorizedToolsetProjector` 根据 `tools` + `disallowedTools` 过滤工具池
4. hooks 配置合并到 `ToolExecutionHookPipeline`（代理级 hooks 优先于全局 hooks）
5. MCP 服务器：代理启动时初始化，代理结束时清理（参考 `initializeAgentMcpServers`）
6. effort level 影响 `thinkingBudget` 分配（低 effort = 不启用 extended thinking）

**收益**  
- 用户可用纯 Markdown 文件创建功能精准的自定义代理
- Verification 代理天然可声明 `disallowedTools: ["str_replace_based_edit_tool", "bash_write"]`
- 代理可声明自己的 MCP 服务器（如 browser automation 只对 UI 测试代理暴露）

---

## 实现优先级建议

| 优先级 | Feature | 理由 |
|--------|---------|------|
| P0 | Feature 9 (Built-in Agent 扩展) | 直接提升复杂任务成功率，无需基础设施变更 |
| P0 | Feature 5 (Plan Mode 工具级) | 高风险任务安全兜底，用户体验关键路径 |
| P1 | Feature 12 (Frontmatter 扩展) | 解锁自定义代理能力，是 Feature 9 的自然延伸 |
| P1 | Feature 7 (Agent Memory 多范围) | 多 session 任务延续性，显著提升 agent quality |
| P1 | Feature 8 (结构化消息类型) | Agent Team 协调质量提升，依赖现有 SendMessage |
| P2 | Feature 1 (工具延迟加载) | Token 效率，工具数 < 20 时收益有限 |
| P2 | Feature 10 (Task v2) | 需要 UI 联动改造，工程量较大 |
| P2 | Feature 2 (UI 信息增强) | 用户体验提升，不影响功能 |
| P3 | Feature 3 (并发/中断精细化) | 现有 isConcurrencySafe 可满足大部分场景 |
| P3 | Feature 4 (结果预算透传) | 当前 ToolResultBudgetController 已覆盖主流程 |
| P3 | Feature 6 (执行上下文追踪) | 调试工具，用户不可见 |
| P3 | Feature 11 (安全分类器接口) | 现有 BashCommandClassifier 够用，接口统一化可延后 |

---

## 依赖关系图

```
Feature 5 (Plan Mode) ──────────────────┐
Feature 12 (Frontmatter) ───────────────┤
Feature 9 (Built-in Agents) ────────────┤──→ 均可独立启动
Feature 8 (Structured Messages) ────────┘

Feature 7 (Agent Memory)  → 可独立实现，Feature 9 增强后收益更大
Feature 1 (Tool Lazy Load) → Feature 12 完成后更自然集成（agent tools whitelist）
Feature 10 (Task v2) → Feature 8 完成后更自然集成（task created → team notification）

Feature 6 (Exec Context) → Feature 3 依赖其 toolDecisions
Feature 4 (Budget Sharing) → 依赖 Feature 6 的 context 对象
Feature 11 (Classifier) → 依赖 Feature 6 的 toolDecisions 缓存
```

---

## 附：Claude Code vs agentGui 工具接口字段对照

| Claude Code `Tool<>` 字段 | agentGui 对应 | 状态 |
|--------------------------|--------------|------|
| `name` | `ToolDefinition.id` | ✅ |
| `aliases` | — | ❌ Feature 3 |
| `searchHint` | — | ❌ Feature 1 |
| `shouldDefer` / `alwaysLoad` | — | ❌ Feature 1 |
| `description(input:)` | `descriptionBuilder` | ✅ |
| `prompt()` | `descriptionBuilder`（同一字段） | ⚠️ 未分离 |
| `inputSchema` (Zod) | `inputSchemaBuilder` (JSONSchema) | ✅ |
| `outputSchema` | — | ❌ |
| `call()` | `ToolExecutionCoordinator` | ✅ |
| `validateInput()` | `ToolExecutionHookPipeline.preExecute` | ⚠️ 部分 |
| `checkPermissions()` | `ToolAuthorizationResolver` | ✅ |
| `isConcurrencySafe()` | `ToolDefinition.isConcurrencySafe` | ✅ |
| `interruptBehavior()` | — | ❌ Feature 3 |
| `isDestructive(input:)` | `riskTier`（静态） | ⚠️ 无 per-input |
| `isReadOnly(input:)` | — | ❌ |
| `isSearchOrReadCommand(input:)` | `BashCommandClassifier`（局部） | ⚠️ 非通用接口 |
| `maxResultSizeChars` | `ToolResultBudgetController`（全局） | ⚠️ 无 per-tool |
| `backfillObservableInput()` | — | ❌ |
| `preparePermissionMatcher()` | 权限规则匹配 | ⚠️ 无 per-tool 定制 |
| `getActivityDescription(input:)` | — | ❌ Feature 2 |
| `getToolUseSummary(input:)` | — | ❌ Feature 2 |
| `toAutoClassifierInput(input:)` | `BashCommandClassifier`（局部） | ⚠️ Feature 11 |
| `userFacingName(input:)` | `displayName` | ✅ |
| `renderToolUseTag(input:)` | — | ❌ Feature 2 |
| `isResultTruncated(output:)` | — | ❌ Feature 2 |
| `isTransparentWrapper()` | — | ❌ |
| `renderGroupedToolUse()` | — | ❌ |
| `strict` | — | ❌ |

---

*文档版本: v1.0 · 2026-04-02*
