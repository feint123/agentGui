# Claude Code 源码对照下的 Built-in Agent 能力增强设计

**Goal:** 基于对 Claude Code v2.1.88 解包源码的结构化分析，识别其中可迁移到 agentGui 内置 agent 的设计，并形成一份面向当前 Swift/SwiftUI 架构的增强方案，重点提升上下文治理、计划执行、团队协作、工具编排与会话恢复能力。

**Architecture:** 不复制 Claude Code 的具体实现，也不引入其遥测、远控或 Anthropic 内部 feature gate 体系；仅抽取其在 production harness 层的有效设计模式，并映射到 agentGui 现有的 ClaudeService、ConversationExecutionOrchestrator、Agent Team、ToolCall/Message/Session 模型与 SwiftUI 工作台中。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, SwiftAnthropic, 现有 execution orchestrator/runtime snapshot store/Agent Team workbench，外部参考来自 Claude Code TypeScript 源码结构。

---

## 1. 结论先行

当前 agentGui 的 built-in agent 已经具备一个可用的 agent loop、工具系统、执行编排和 team workbench 雏形，但它仍然更像“能运行任务的单体 agent”，而不是“带治理层的生产级 agent runtime”。

Claude Code 最值得学习的并不是某个单点工具，而是它围绕最小 agent loop 额外构建的一层 harness。对 agentGui 最有价值的可迁移设计有六类：

1. 把 agent loop 和会话生命周期剥离成显式的执行引擎，而不是继续让 ClaudeService 承担过多职责。
2. 在工具系统上增加“暴露前过滤 + 执行期并发分批 + 前后置钩子”的治理层。
3. 把“计划模式”升级为一等状态机，而不是仅靠普通对话提示词约束复杂任务。
4. 建立上下文治理层，包括自动压缩、会话摘要、工具结果摘要和恢复提示。
5. 把 Agent Team 从“任务板 + 顺序派发”升级为“可恢复、多 agent 通信、共享团队记忆”的协作控制面。
6. 把任务追踪从简单 todo 推进到 typed task runtime，允许依赖、阻塞、owner、元数据和钩子。

其中最值得优先落地的是：计划模式、上下文治理、工具钩子、团队消息总线。这四项会直接提升当前 built-in agent 的可靠性和复杂任务完成率。

## 2. 分析范围与方法

本次分析同时对照了两类代码：

### 2.1 agentGui 当前基线

重点查看了以下现有实现：

1. ClaudeService 主体与消息发送入口。
2. runCoreAgentLoop 与子代理循环复用机制。
3. ConversationExecutionProviderRegistry、ConversationExecutionOrchestrator、ConversationExecutionRuntimeCoordinator。
4. ToolDefinition、ToolRegistry、ToolCall 持久化模型。
5. Agent Team 的 mission brief、task board、launch coordinator、workbench UI。

当前基线说明 agentGui 已经具备以下基础能力：

1. built-in 与 external ACP provider 的统一执行入口。
2. per-session runtime projection 与恢复快照。
3. 子代理循环复用与工具调用记录。
4. Team 会话、Mission Brief、Task Board、Artifact Board 的基础模型。
5. SwiftUI 层面的 Team Workbench 展示壳层。

### 2.2 Claude Code 对标样本

重点阅读了 Claude Code 解包源码中的以下模块：

1. QueryEngine.ts：会话级 query lifecycle engine。
2. tools.ts：工具注册、启用条件、暴露过滤。
3. services/tools/toolOrchestration.ts：并发安全工具调度。
4. services/tools/toolHooks.ts：工具前后置钩子。
5. services/compact/autoCompact.ts 与 sessionMemoryCompact.ts：上下文压缩治理。
6. memdir/memdir.ts 与 teamMemPrompts.ts：文件化记忆与 team memory 提示结构。
7. tools/EnterPlanModeTool 与 ExitPlanModeV2Tool：显式计划模式。
8. tools/TeamCreateTool 与 SendMessageTool：多 agent 团队与消息投递。
9. services/toolUseSummary/toolUseSummaryGenerator.ts 与 awaySummary.ts：恢复与摘要。
10. hooks/useSwarmInitialization.ts：team session 恢复初始化。

这批模块足够回答一个关键问题：Claude Code 哪些地方是“真正提升 agent 能力的设计”，哪些只是 Anthropic 内部产品化特性。

## 3. 当前 built-in agent 的能力边界

### 3.1 已经做对的部分

agentGui 当前设计并不落后，至少在以下方面已经接近现代 agent runtime：

1. 已经把执行器抽象成 provider registry，而不是把 built-in agent 写死在 UI 层。
2. 已经有 ConversationExecutionOrchestrator 和 runtime coordinator，说明执行队列、激活、取消、恢复并非散落在视图中。
3. 已经有 ToolCall、AgentRound、ExecutionProjectionStore 等可观测执行记录。
4. 已经有 run_subagent 和 Team Workbench，说明系统已具备“多执行主体”的概念。
5. 已经有变更审查投影、权限中心、运行时快照等治理基础设施。

这意味着本次设计不应该推翻现有架构，而应该补全“治理层”和“控制层”。

### 3.2 当前明显不足的部分

和 Claude Code 对比后，当前 built-in agent 有五个短板：

1. ClaudeService 仍然承担过多责任，既管 API、又管工具、又管会话交互、又管 team dispatch，聚合度过高。
2. 复杂任务缺少显式 plan mode，用户与 agent 很难形成“先设计、后执行”的受控切换。
3. 上下文治理不足，目前更多依赖单轮 prompt 拼装和 token 预算，没有形成自动压缩、恢复摘要、工具摘要的组合策略。
4. Team 模式当前更偏“共享任务板 + 顺序派发”，还不是“可通信、可恢复、可共享记忆”的多 agent runtime。
5. 工具系统已有注册和记录，但缺少 Claude Code 那种 concurrency-safe batching、前后置 hook、工具结果二次摘要和可恢复控制。

## 4. Claude Code 中最值得迁移的设计

### 4.1 显式 Query Engine，而不是超级服务对象

Claude Code 的 QueryEngine 有一个非常清晰的定位：它拥有一次会话的 query lifecycle、mutable messages、权限拒绝记录、file cache、usage 状态，并对外暴露 submitMessage。

这类设计的价值不是“多一层抽象”，而是把以下东西收敛成一个稳定边界：

1. turn 级输入处理。
2. 持久消息状态。
3. 工具使用上下文。
4. 压缩与恢复切入点。
5. SDK/headless 与 UI 共用的统一执行内核。

对 agentGui 的启发是：当前的 ClaudeService 应继续作为 UI-facing facade，但应拆出一个 BuiltInAgentQueryEngine 或 BuiltInAgentRuntime。ClaudeService 只负责桥接 SwiftUI、Session、AppSettings、projection store；真正的 turn lifecycle、tool context、compaction、resume logic 应下沉到专门执行引擎。

这会直接减少当前 ClaudeService 持续膨胀的风险。

### 4.2 工具暴露前过滤与并发安全分批

Claude Code 在 tools.ts 与 toolOrchestration.ts 中体现了两个关键设计：

1. 工具不是无条件暴露给模型，而是先按环境、feature、权限上下文、工具类型做过滤。
2. 工具执行不是简单顺序跑，而是按 concurrency-safe 与非安全工具切批，读型工具可以并发，写型工具串行。

agentGui 当前已经有 ToolDefinition、ToolRegistry、ToolAuthorizationDescriptor、ToolContext，但还缺少一层更显式的 tool admission policy。建议新增：

1. ToolExposurePolicy：决定某轮哪些工具真的出现在 schema 中。
2. ToolExecutionBatchPlanner：基于工具属性把同一轮 tool calls 分成 read-only batch、stateful batch、interactive batch。
3. ToolContextMutationQueue：并发读工具执行完后再统一合并上下文变化，避免工具并行时污染共享上下文。

这会直接提升大模型在一轮中发出多个读工具时的吞吐，并减少对话型 agent 因工具顺序不当导致的延迟。

### 4.3 工具前后置钩子

Claude Code 的 toolHooks 不是“脚本系统”，而是一种通用治理层。它允许在工具前、工具后、失败后插入：

1. 附加上下文。
2. 阻断执行。
3. 结果重写。
4. 审计消息。
5. 特定故障的恢复策略。

这类设计对 agentGui 的价值非常大，因为当前 agentGui 已经有多类特殊逻辑：

1. ACP 权限请求。
2. 变更评审投影。
3. terminal planner / terminal takeover。
4. memory payload shaping。
5. LSP 自动启动。

这些逻辑如果继续直接挂在 ClaudeService 或单个工具 executor 上，会越来越难维护。建议引入：

1. ToolExecutionHook 协议：preExecute、postExecute、postFailure。
2. 内建 hook 集：ChangeReviewHook、TerminalObservationHook、MemoryBudgetHook、VerificationEvidenceHook。
3. HookAttachment 模型：把 hook 产出的附加信息投影到 ToolCall 时间线，而不是静默吞掉。

这能让 agentGui 的 built-in agent 从“能调用工具”升级到“能治理工具调用副作用”。

### 4.4 计划模式是一等状态机

Claude Code 对复杂任务的关键增强，不是多了一个 plan prompt，而是明确区分：

1. enter plan mode。
2. 只读探索阶段。
3. exit plan mode。
4. 用户审批或 leader 审批。
5. 执行阶段。

这点对于 agentGui 当前的 built-in agent 尤其关键。因为当前系统已经具备工具、队列、子代理、team mode，但复杂改动依旧容易直接进入执行，没有明确的“设计冻结点”。

建议在 agentGui 中新增 Plan Mode Runtime：

1. SessionExecutionPreferences 中新增 executionMode：normal | plan。
2. PlanArtifact 持久化模型，保存当前 plan 文本、状态、最近批准记录。
3. EnterPlanModeTool 和 ExitPlanModeTool 的 Swift 版本，绑定到 built-in agent。
4. Plan Approval Sheet，用于普通用户审批。
5. Team 会话中的 leader approval path，用于 card owner 提交方案后再开始执行。

落地后，Agent Team 的 worker card 也可以先进入 plan，再获得 claim 执行权限，这会显著减少错误修改和返工。

### 4.5 上下文治理层：auto compact + session memory compact + summaries

Claude Code 在上下文管理上最值得借鉴的是“组合策略”，不是单一摘要器。它实际上做了四件事：

1. 根据上下文窗口和输出保留量计算 auto-compact threshold。
2. 做 session memory compaction，保留 API invariant，避免 tool_use/tool_result 被切断。
3. 给长时间离开后的用户生成 away summary。
4. 给已完成工具批次生成 tool use summary。

对 agentGui 的直接启发如下：

#### A. 引入 CompactionCoordinator

负责：

1. 跟踪每 session token headroom。
2. 决定何时触发压缩。
3. 在压缩前验证 message/tool invariants。
4. 把压缩结果投影为系统事件，而不是隐式替换上下文。

#### B. 引入 Session Recall Layer

包含两类摘要：

1. ResumeSummary：用户重新打开会话时，用 1 到 3 句解释当前在做什么、下一步是什么。
2. ToolBatchSummary：多工具完成后生成短标签，直接显示在消息时间线或 execution theater 中。

#### C. 引入 Memory-preserving Compaction

当前 agentGui 已有 session 级 execution evidence、todo、verification、tool payload store，但缺少“压缩后保留什么”的统一协议。建议压缩优先保留：

1. 活跃计划与未完成 todo。
2. 当前 card / claim / artifact 状态。
3. 最近一次失败原因与验证结果。
4. 用户尚未回答的问题。

这会让 built-in agent 在长任务中更稳定，也更适合日后支持后台执行或 session 恢复。

### 4.6 Team 协作不只是任务板，还要有消息总线和 team memory

Claude Code 的 TeamCreateTool、SendMessageTool、useSwarmInitialization、teamMemPrompts 展示了一个很重要的观点：多 agent 协作不能只靠任务板和共享 prompt，还需要：

1. team identity。
2. teammate inbox / message routing。
3. resumed session 的 team context 恢复。
4. shared team memory。

当前 agentGui 的 Agent Team 已经有 mission brief、task board、artifact board，但还缺三层：

1. Team Message Bus：conductor 与 workers 之间的结构化 memo、approval request、review request。
2. Team Context Bootstrap：恢复 team session 时自动恢复 roster、active card、claim owner、pending approvals。
3. Team Shared Memory：把跨 card 可复用事实沉淀为 team-scoped memory，而不是只停留在消息文本或 artifact summary。

这三层落地后，Agent Team 才会从“任务 UI”进化为“真实协作 runtime”。

### 4.7 从 Todo 到 Typed Task Runtime

Claude Code 源码里保留了 TodoWriteTool，同时也演进出了 TaskCreate/Get/Update/List 一套 typed task API。这个方向对 agentGui 很有意义。

当前 agentGui 的 todo list 适合单线程推进，但不够表达：

1. owner。
2. blockedBy。
3. metadata。
4. active form。
5. task created hooks。

建议 agentGui 不要继续把 todo 作为唯一的任务抽象，而是：

1. 对普通单 agent 会话保留轻量 todo UI。
2. 在执行层新增 TypedExecutionTask，用于复杂任务和 team cards。
3. 允许 task 和 Team Task Card 做一一映射。
4. 允许 future verifier / reviewer 读取 task metadata，而不是重新解析自然语言。

这会让 built-in agent 的执行过程更适合被验证、恢复和协作。

## 5. 不建议照搬的设计

Claude Code 有些设计是产品形态或 Anthropic 内部控制面的产物，不适合 agentGui 直接迁移：

1. 遥测与强制日志收集。
2. 远程 managed settings 与 killswitch 体系。
3. 内部 feature gate、隐藏命令、动物代号模型管理。
4. undercover mode 相关行为。
5. 大量依赖 Bun compile-time feature 的条件模块装配方式。

这些内容对 agentGui 的 built-in agent 能力提升价值很低，且会引入额外透明性和维护风险。


## 6. 新增分析发现（第二轮深度阅读）

本节补充第一轮分析后，从以下额外模块中提取的设计细节：

### 6.1 TokenBudget 决策树（`query/tokenBudget.ts`）

Claude Code 在每个 agent turn 内设计了一个显式决策对象 `TokenBudgetDecision`：

```
continue → nudgeMessage + continuationCount + pct + budget
stop    → completionEvent(diminishingReturns, durationMs) | null
```

关键行为：当 `continuationCount >= 3` 且最近两次 delta 均 `< 500 tokens` 时触发 **diminishing returns stop**，而非继续消耗 context。这个检测直接避免了 agent 在 token 将尽时反复徒劳输出的问题。agentGui 当前没有对应机制。

### 6.2 QueryConfig 不可变快照（`query/config.ts`）

Claude Code 在每次 `query()` 调用入口把所有配置快照为不可变 `QueryConfig`，包括所有 feature gate、model 名称、运行时 flag。这样做的好处是：同一次 agent loop 执行过程中，配置不会因并发状态变化而中途变形。agentGui 的 agent loop 目前从 `AppSettings` 按需读取，存在同样的隐患。

### 6.3 StopHook 管道（`query/stopHooks.ts`）

每次 API 采样结束后，Claude Code 运行 `handleStopHooks()`，它是一个异步生成器，负责：

1. 执行外部用户配置的 stop hooks。
2. 检测 task_completed 事件并触发 hook。
3. 检测 teammate_idle 事件并触发 hook。
4. 阻断或放行 continuation。

这是一个"turn 结束边界"的统一钩子点，agentGui 目前没有对应抽象。

### 6.4 InProcessTeammateTask 内存 Cap（`tasks/InProcessTeammateTask/types.ts`）

BQ 分析（2026-03-20）显示：whale session `9a990de8` 在 2 分钟内启动 292 个 agent，每个 agent 在 `task.messages` 中维护完整对话副本，导致 36.8 GB RSS。解法是 `TEAMMATE_MESSAGES_UI_CAP = 50`：UI 镜像最多保留 50 条消息，完整历史仅持久化到磁盘。**agentGui 的 `AgentTeamWorkbenchPresentation` 中 worker messages 应做相同 cap 设计**，避免大型 team session 内存暴增。

### 6.5 SendMessageTool 的三种结构化消息类型（`tools/SendMessageTool`）

Claude Code 把 teammate 间通信归结为三类 discriminated union：

1. `shutdown_request / shutdown_response`：安全终止协商。
2. `plan_approval_response`：plan 审批回复（含 `request_id`、`approve bool`、`feedback`）。
3. 普通字符串消息（非结构化 memo）。

这个设计说明大多数 multi-agent 协调只需要这三种原语，不需要全协议栈。agentGui 的 `TeamMessageBus` 可以照此设计。

### 6.6 TeamMemory 的 secret scanner（`services/teamMemorySync/`）

Claude Code 的 team memory sync 模块包含 `secretScanner.ts`，在写入 team memory 前扫描潜在密钥/凭证。这是一个值得迁移的安全特性，在 agentGui 的 `TeamMemoryStore` 中应设置内容校验拦截。

### 6.7 AutoCompact 熔断机制（`services/compact/autoCompact.ts`）

Claude Code 的 autocompact 有一个熔断器：`consecutiveFailures` 达到 3 次后停止重试，原因是 BQ 分析（2026-03-10）发现 1,279 个 session 有 50+ 次连续失败（最高 3,272 次），每天浪费约 25 万次 API 调用。关键参数：`AUTOCOMPACT_BUFFER_TOKENS = 13,000`，压缩触发阈值 = `contextWindow - maxOutputTokens - 13,000`。

### 6.8 ToolBatchSummary 的提示词工程（`services/toolUseSummary/toolUseSummaryGenerator.ts`）

Claude Code 使用 Haiku 生成工具批次标签，核心提示词约束是：

> "git-commit-subject style, 30 chars, past tense verb + most distinctive noun. Drop articles, connectors, long location context."

示例：`Searched in auth/`、`Fixed NPE in UserService`、`Ran failing tests`。agentGui 可以完整复用这个 prompt 设计（不依赖任何内部 API）。

### 6.9 TodoWriteTool 的验证 nudge 机制（`tools/TodoWriteTool`）

当 agent 把所有 3+ 个 todo 标记为 completed 但没有任何验证步骤时，`TodoWriteTool` 在 tool result 里注入提醒。这个 nudge 在"loop exit moment"触发，因为这正是 agent 最容易跳过验证的时机。agentGui 的内置 todo 工具没有这个保护。

### 6.10 SkillTool：技能作为可调度子代理（`tools/SkillTool`、`skills/`）

Claude Code 的 Skill 是带 frontmatter 的 `.md` 文件，执行时 fork 一个子代理运行。`BundledSkillDefinition` 支持：

- `allowedTools`：限制 skill 可用工具。
- `model`：覆盖执行 skill 用的模型。
- `hooks`：skill 级别的 hook 配置。
- `files`：skill 附带的参考文件，按需解压到磁盘。

这为 agentGui 提供了一个轻量技能/提示词模板系统的参考设计。未来可考虑 `SkillCatalog` 类型的机制。

---

## 7. Feature 清单

以下是基于以上所有分析整理出的具体 Feature，每个 Feature 对应一个可独立开发的工作单元。按模块分组，标注优先级和依赖关系。

---

### Layer C — 工具治理层（Tool Governance）

工具治理层不依赖其他新增层，可以最早落地，直接提升现有 agent 的吞吐和可观测性。

---

#### F-C1 · ToolConcurrencyBatchPlanner

**优先级:** P0  
**来源:** `services/tools/toolOrchestration.ts` → `partitionToolCalls()`

**做什么:** 在 `runCoreAgentLoop` 的工具执行阶段，把同一轮 `ToolUseBlock[]` 按 `isConcurrencySafe` 属性分批：凡标记为 concurrency-safe 的工具（只读）合并为一个并发批次，其他工具独自串行执行。上下文修改（context mutation）在并发批次完成后统一合并，避免互相污染。

**要定义的类型:**

```swift
enum ToolExecutionBatch {
    case concurrent([ToolCall])   // all isConcurrencySafe = true
    case serial(ToolCall)         // stateful / interactive / unknown
}

protocol ToolConcurrencyClassifiable {
    var isConcurrencySafe: Bool { get }
}
```

**新增文件:** `agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift`

**接入点:** `AgentLoopToolExecutionCoordinatorBuilder` 或 `runCoreAgentLoop` 中构建工具执行 pipeline 的位置。

> **⚠️ 后续扩展：** `2026-04-01-subagent-capability-enhancement-design.md` 中的 **S-F3**（Fork 并发调度器）会在本文件中新增对 fork 模式子代理的并发安全标记（`isConcurrencySafe = true`），请保留 `ToolConcurrencyBatchPlanner` 中对 `subagentType` 的判断分支预留点以便 S-F3 接入。

**验收标准:**
- 同一轮调用多个只读工具（例如 bash_read、search）时，它们并发执行，总耗时等于最长的单工具耗时，而非叠加。
- 两个写工具（例如 file_write + bash_write）在同一轮时，串行执行，不并发。
- 有覆盖并发执行顺序不确定性的单元测试。

**依赖:** 无

---

#### F-C2 · ToolExecutionHookPipeline

**优先级:** P0  
**来源:** `services/tools/toolHooks.ts`

**做什么:** 建立标准的工具前后置钩子协议，让所有 built-in 工具执行都能在不修改工具本体的情况下挂接附加行为。钩子可以附加上下文、阻断执行、重写结果、注入审计消息。

**要定义的类型:**

```swift
protocol ToolExecutionHook {
    var hookID: String { get }
    func preExecute(toolCall: ToolCallPreview, context: ToolExecutionContext) async throws -> PreExecuteDecision
    func postExecute(toolCall: ToolCallRecord, result: ToolResult, context: ToolExecutionContext) async -> PostExecuteAction
    func postFailure(toolCall: ToolCallRecord, error: Error, context: ToolExecutionContext) async -> FailureAction
}

enum PreExecuteDecision {
    case allow
    case block(reason: String)
    case attachContext(String)
}

enum PostExecuteAction {
    case passthrough
    case appendAttachment(String)
    case rewriteResult(ToolResult)
}

enum FailureAction {
    case propagate
    case recover(ToolResult)
    case appendDiagnostic(String)
}
```

**新增文件:** `agentGui/Services/ToolGovernance/ToolExecutionHookPipeline.swift`

**接入点:** 在 `runCoreAgentLoop` 的工具执行层，包裹每个 `ToolCall.execute()` 调用。

**验收标准:**
- 已注册钩子的 preExecute 在工具执行前被调用，返回 block 时工具不执行且错误消息注入会话。
- postExecute 返回 appendAttachment 时，附加内容出现在 ToolCall 时间线（ExecutionProjectionStore）中。
- 钩子执行失败不影响主工具执行路径（非致命）。

**依赖:** 无

---

#### F-C3 · ChangeReviewHook

**优先级:** P0  
**来源:** agentGui 现有 change review 逻辑 + `services/tools/toolHooks.ts` 设计

**做什么:** 把现有分散在 `ClaudeService` / 文件工具中的 change review projection 逻辑，迁移为一个标准 `ToolExecutionHook`，在文件写入工具（`file_write`、`file_edit`、`apply_patch`）执行后自动触发，不需要修改工具本体。

**新增文件:** `agentGui/Services/ToolGovernance/Hooks/ChangeReviewHook.swift`

**接入点:** 注册到 `ToolExecutionHookPipeline`，在 `postExecute` 阶段检测工具名称，若为文件写入类则触发 change review projection。

**验收标准:**
- 文件编辑后，change review attachment 出现在执行时间线中，与当前行为一致。
- 不再需要在文件工具本体或 `ClaudeService` 中保留 change review 逻辑副本。

**依赖:** F-C2

---

#### F-C4 · VerificationEvidenceHook

**优先级:** P0  
**来源:** `tools/TodoWriteTool` 验证 nudge + Claude Code tool post-hook 模式

**做什么:** 在 bash/terminal 工具执行后，检测命令是否为测试运行（`xcodebuild test`、`swift test`、`npm test` 等）。若是，从输出中提炼验证摘要（pass/fail count、失败原因），作为 `VerificationEvidence` 附加到 ToolCall 时间线。同时，若 agent 完成全部 todo 但没有任何 verification evidence，在 todo 更新时注入 nudge 提示（同 Claude Code 的 `verificationNudgeNeeded`）。

**新增文件:** `agentGui/Services/ToolGovernance/Hooks/VerificationEvidenceHook.swift`

**接入点:** 注册到 `ToolExecutionHookPipeline`，在 bash/terminal 工具 `postExecute` 阶段运行。

**验收标准:**
- 运行测试命令后，执行时间线中出现可识别的 pass/fail 摘要 attachment。
- 所有 todo 标记完成但无 verification evidence 时，会话中出现提醒消息。

**依赖:** F-C2

---

#### F-C5 · PayloadBudgetHook

**优先级:** P1  
**来源:** `agentGui` 现有 `ToolPayloadStore` + hook 模式

**做什么:** 在工具 `postExecute` 阶段检测结果大小。若超过配置阈值（默认 16KB），自动把完整结果存入 `ToolPayloadStore`，并在消息上下文中替换为 payload reference（`[payload:id, size:xxx]`），避免大型工具结果撑爆 context window。

**新增文件:** `agentGui/Services/ToolGovernance/Hooks/PayloadBudgetHook.swift`

**接入点:** 注册到 `ToolExecutionHookPipeline`，在 `postExecute` 阶段检测 result size。

**验收标准:**
- 工具返回超过阈值的内容时，context 中只保留 reference，payload 可单独读取。
- payload reference 格式与现有 `ToolPayloadStore` 兼容。

**依赖:** F-C2

---

#### F-C6 · ToolExposurePolicy

**优先级:** P1  
**来源:** `tools.ts` → `getTools()` 工具过滤逻辑

**做什么:** 在每个 agent turn 构建工具 schema 时，引入一个 `ToolExposurePolicy` 协议，基于当前执行上下文（session mode、plan mode、worker/conductor role、权限级别）过滤最终暴露给模型的工具集合。例如：plan mode 期间不暴露写工具；普通单 agent 不暴露 team 工具；外部 ACP provider session 不暴露内部系统工具。

**要定义的类型:**

```swift
protocol ToolExposurePolicy {
    func allowedTools(from registry: ToolRegistry, context: ToolExposureContext) -> [ToolDefinition]
}

struct ToolExposureContext {
    var sessionMode: SessionExecutionMode    // normal, plan, team_conductor, team_worker
    var permissionLevel: ToolPermissionLevel
    var activeWorkspace: WorkspaceContext?
}
```

**新增文件:** `agentGui/Services/ToolGovernance/ToolExposurePolicy.swift`

**接入点:** `runCoreAgentLoop` 构建 tools schema 前。

**验收标准:**
- Plan mode 期间，模型收不到任何写文件工具的 schema。
- 受控单元测试覆盖各 mode 下的工具可见性。

**依赖:** F-D1（Plan Mode 状态）

---

### Layer B — 上下文治理层（Context Governance）

上下文治理层直接决定 agent 在长任务中的持续能力，P0/P1 项应与工具治理层并行推进。

---

#### F-B1 · ContextWindowBudgetTracker

**优先级:** P0  
**来源:** `services/compact/autoCompact.ts` → `calculateTokenWarningState()`、`query/tokenBudget.ts` → `checkTokenBudget()`

**做什么:** 在 built-in agent loop 中跟踪每 session 的累计 token 使用量，基于模型 context window 大小计算四个阈值状态：`normal`、`warning`、`critical`、`autoCompactReady`。同时实现 **diminishing returns 检测**：当 `continuationCount >= 3` 且连续两次 token delta 均低于阈值（建议 500 tokens）时，主动停止而非继续消耗。

**要定义的类型:**

```swift
struct ContextBudgetState {
    var tokenUsage: Int
    var contextWindow: Int
    var percentRemaining: Int
    var level: BudgetLevel              // normal / warning / critical / autoCompactReady
    var continuationCount: Int
    var lastDeltaTokens: Int
    var isShowingDiminishingReturns: Bool
}

enum BudgetLevel { case normal, warning, critical, autoCompactReady }
```

**新增文件:** `agentGui/Services/ContextGovernance/ContextWindowBudgetTracker.swift`

**接入点:** `AgentLoopRuntime` / `runCoreAgentLoop` 的每次 API 响应消费处，从 usage 字段更新 tracker。

**验收标准:**
- tracker 在 token 达到 warning 阈值（context window 的 ~85%）时更新状态为 `.warning`，视图层可响应式展示警告。
- diminishing returns 检测在连续低效输出后正确触发 stop，单元测试覆盖边界条件。

**依赖:** 无

---

#### F-B2 · MessageInvariantValidator

**优先级:** P1  
**来源:** `services/compact/sessionMemoryCompact.ts` 对 API invariant 的保持

**做什么:** 在任何压缩操作前运行不变量校验，确保以下关系不被截断：

1. 每个 `tool_use` block 必须有对应的 `tool_result` block。
2. 每个 pending approval 对应的 `ToolCall` 不能被截断。
3. 每个 subagent round 的 parent `ToolCall` 不能和 round 消息分离。
4. team card / claim / artifact 的跨消息引用必须完整保留。

**新增文件:** `agentGui/Services/ContextGovernance/MessageInvariantValidator.swift`

**接入点:** `CompactionCoordinator`（F-B3）执行压缩前调用。

**验收标准:**
- 校验函数返回所有无法被截断的消息 ID 集合，`CompactionCoordinator` 在确定压缩边界时尊重这批 ID。
- 单元测试覆盖各类引用完整性场景。

**依赖:** 无

---

#### F-B3 · CompactionCoordinator

**优先级:** P1  
**来源:** `services/compact/autoCompact.ts`

**做什么:** 负责触发和协调会话压缩的完整生命周期：

1. 接收来自 `ContextWindowBudgetTracker` 的 `autoCompactReady` 信号。
2. 调用 `MessageInvariantValidator` 确定安全压缩边界。
3. 生成摘要（通过快速模型调用保留关键状态）。
4. 替换 messages 数组（保留不变量集合 + 压缩摘要系统消息）。
5. 实现熔断器：连续失败 3 次后停止尝试（参考 Claude Code `MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3`）。
6. 压缩优先保留：活跃 plan、未完成 todo、pending approval、最近验证证据、用户未回答问题。

**新增文件:** `agentGui/Services/ContextGovernance/CompactionCoordinator.swift`

**接入点:** `BuiltInAgentQueryEngine` / `runCoreAgentLoop` 的 AutoCompact 触发点。

**验收标准:**
- 超过阈值的长会话经压缩后能继续正常执行，context 保持有效。
- 压缩后 todo 和 plan（若存在）仍然可见。
- 连续 3 次压缩失败后停止尝试，不再消耗 API。

**依赖:** F-B1, F-B2

---

#### F-B4 · ResumeSummaryService

**优先级:** P0  
**来源:** `services/awaySummary.ts`

**做什么:** 当用户重新打开一个已有对话历史的 session 时，用快速模型（小模型）生成 1-3 句摘要，内容为"当前在做什么 + 下一步是什么"。展示在会话顶部或切换 session 时的预览区域。生成过程异步，不阻塞会话加载。

Claude Code 的提示词设计可完整复用：

> "The user stepped away and is coming back. Write exactly 1-3 short sentences. Start by stating the high-level task — what they are building or debugging, not implementation details. Next: the concrete next step. Skip status reports and commit recaps."

**新增文件:** `agentGui/Services/ContextGovernance/ResumeSummaryService.swift`

**接入点:** `SessionListView` / `ContentView` 中 session 被选中且有历史消息时触发。

**验收标准:**
- 切换到有历史消息的 session 时，1-3 秒内在 UI 中出现摘要卡片。
- 空 session 或 session 被中断时不触发。
- 摘要生成失败时静默处理，不影响 session 加载。

**依赖:** 无

---

#### F-B5 · ToolBatchSummaryService

**优先级:** P0  
**来源:** `services/toolUseSummary/toolUseSummaryGenerator.ts`

**做什么:** 在一批工具执行完成后，用快速模型（Haiku / small model）生成一个 30 字以内的 git-commit-subject 风格标签，显示在消息时间线或 execution theater 中（而非显示每个工具调用的完整 I/O）。

提示词（可直接复用 Claude Code 设计）：

> "Write a short summary label describing what these tool calls accomplished. git-commit-subject style, ~30 chars. Past tense verb + most distinctive noun. Examples: Searched in auth/, Fixed NPE in UserService, Ran failing tests"

**新增文件:** `agentGui/Services/ContextGovernance/ToolBatchSummaryService.swift`

**接入点:** `ToolConcurrencyBatchPlanner`（F-C1）每批工具执行完成后触发。

**验收标准:**
- 3 个或以上工具执行后，时间线中显示批次标签而非逐条展开。
- 标签长度不超过 40 字符。
- 生成失败时静默降级，退回展示工具名列表。

**依赖:** F-C1

---

#### F-B6 · SubagentProgressSummarizer

> **⚠️ 与 subagent 增强设计文档对齐：** 本 Feature 与 `2026-04-01-subagent-capability-enhancement-design.md` 中的 **S-C4** 定义的是同一组件。以 S-C4 为规范实现，本条目保留作交叉引用。

**优先级:** P1（与 S-C4 同步，高于本文档原定 P2）  
**来源:** `services/AgentSummary/agentSummary.ts`

**做什么:** 对于长时间运行的子代理（run_subagent），每 30 秒 fork 一个摘要请求，生成 3-5 词的现在时进度标签（如 "Reading runAgent.ts"、"Fixing null check"），显示在子代理的 task indicator 旁。使用与主 agent 相同的 prompt cache key，不额外消耗 cache。详细设计见 S-C4（含 `CacheSafeParams` 共享策略与 `previousSummary` 去重机制）。

**规范文件路径:** `agentGui/Services/SubagentGovernance/SubagentProgressSummarizer.swift`（非 ContextGovernance/）

**接入点:** `SubagentBackgroundExecutor.launch`（S-C2）启动后同时启动摘要计时器；`AgentLoopRuntime` 的 subagent 启动路径中也可触发。

**验收标准:**
- 运行超过 30 秒的子代理，task indicator 显示当前进度短语。
- 摘要每 30 秒更新一次，内容不重复上一条（有 `previousSummary` avoid-repeat 约束）。
- 摘要 API 调用失败时沉默降级，不影响主 loop。

**依赖:** F-C1，S-C1，S-C2

---

### Layer D — 计划模式运行时（Plan Mode Runtime）

计划模式是提升复杂任务成功率最直接的结构性改进，P1 优先级，可紧接 P0 工具治理层之后落地。

---

#### F-D1 · PlanArtifact SwiftData 模型

**优先级:** P1  
**来源:** `tools/ExitPlanModeTool/ExitPlanModeV2Tool.ts` → plan file/state

**做什么:** 新增 `PlanArtifact` SwiftData `@Model`，作为 session 级 plan 的持久化容器。每个 session 最多一个活跃 PlanArtifact。

**要定义的类型:**

```swift
@Model final class PlanArtifact {
    var id: UUID
    var sessionID: UUID
    var planText: String              // markdown plan content
    var status: PlanStatus            // drafting | awaitingApproval | approved | rejected | executing
    var createdAt: Date
    var approvedAt: Date?
    var rejectedAt: Date?
    var rejectionFeedback: String?
    var allowedActions: [String]      // semantic permissions requested by plan
    var requestID: String             // for matching approval responses
    var isTeamWorkerPlan: Bool        // false = single-agent, true = team worker card plan
    var workerCardID: UUID?
}

enum PlanStatus: String, Codable {
    case drafting, awaitingApproval, approved, rejected, executing
}
```

**新增文件:** `agentGui/Models/PlanArtifact.swift`

**接入点:** 纳入 SwiftData `ModelContainer` schema；`Session` 以 `@Relationship` 引用。

**验收标准:**
- PlanArtifact 可随 session 持久化和恢复。
- 状态机转换（drafting → awaitingApproval → approved/rejected）有单元测试。

**依赖:** 无

---

#### F-D2 · EnterPlanModeTool（Swift）

**优先级:** P1  
**来源:** `tools/EnterPlanModeTool/EnterPlanModeTool.ts`

**做什么:** 内置工具，当 agent 调用时，将当前 session 的 `executionMode` 从 `normal` 切换为 `plan`。工具结果注入只读约束指令：「在 plan mode 中，你只能探索代码库，不能写或删除任何文件。使用 ExitPlanMode 提交方案。」

工具启用条件：仅在 `executionMode == .normal` 且非子代理 context 中启用（同 Claude Code：`agent context` 中禁用）。

**新增文件:** `agentGui/Services/BuiltInTools/EnterPlanModeTool.swift`

**接入点:** 注册到 `ToolRegistry`。触发 `SessionExecutionPreferences.executionMode = .plan`。

**验收标准:**
- 工具调用后，同一 session 的后续工具 schema 中写工具消失（F-C6 配合）。
- 调用记录出现在 execution theater 中，UI 层显示 "plan mode" 状态标识。

**依赖:** F-D1, F-C6

---

#### F-D3 · ExitPlanModeTool（Swift）

**优先级:** P1  
**来源:** `tools/ExitPlanModeTool/ExitPlanModeV2Tool.ts`

**做什么:** 内置工具，当 agent 调用时：

1. 从 agent 输出或临时文件中提取 plan 文本。
2. 创建 `PlanArtifact`，状态设为 `awaitingApproval`。
3. 将 `executionMode` 切换回等待态（不立即切回 normal）。
4. 向 session 注入 approval-pending 消息（含 plan 预览）。
5. 暂停 agent loop，等待用户或 conductor 审批。

输入 schema：

```swift
struct ExitPlanModeInput: Codable {
    var allowedActions: [String]?     // semantic actions e.g. "run xcodebuild test", "edit Files"
}
```

**新增文件:** `agentGui/Services/BuiltInTools/ExitPlanModeTool.swift`

**接入点:** 注册到 `ToolRegistry`；调用后 agent loop 进入 suspended 态直到 approval。

> **与 subagent 增强设计文档对齐：** `2026-04-01-subagent-capability-enhancement-design.md` 中的 **S-B1**（Plan 内置子代理）与本工具协同工作：主代理进入 plan mode 后，可选择将只读探索工作委托给 plan 子代理（`run_subagent agent_name: plan`），plan 子代理返回的 `plan_report` 即作为本工具的 `planText` 入参，主代理随后调用 ExitPlanModeTool 提交审批。主代理也可以不使用子代理而自行在 plan mode 内探索，两种路径均合法。

**验收标准:**
- 工具调用后 agent loop 暂停，不继续执行任何操作。
- PlanArtifact 持久化，关闭再打开 app 后 plan 仍在 awaiting 状态。
- 由 plan 子代理（S-B1）产出的 plan_report 可作为 planText 直接传入，不需要格式转换。

**依赖:** F-D1, F-D2

---

#### F-D4 · PlanApprovalFlowView

**优先级:** P1  
**来源:** Claude Code 交互式 approval dialog + SwiftUI sheet pattern

**做什么:** 当 session 中有 `PlanArtifact` 处于 `awaitingApproval` 状态时，在 `ChatView` 底部展示一个审批面板，包含：

- Plan 内容预览（Markdown 渲染）
- 「Approve & Execute」按钮：将 PlanArtifact 状态改为 `approved`，恢复 agent loop。
- 「Request Changes」输入框 + 发送：注入用户反馈，保持 plan mode 继续探索。
- 「Reject」按钮：将 PlanArtifact 改为 `rejected`，允许 agent 重新规划或退出。

**新增文件:** `agentGui/Views/PlanApprovalFlowView.swift`

**接入点:** `ChatView` 或 `SessionDetailView` 中，监听 session 的 active `PlanArtifact`。

**验收标准:**
- Plan 提交后，用户在 5 秒内看到审批面板（无需刷新）。
- 点击 Approve 后，agent loop 在 1 秒内恢复执行，写工具重新出现在 schema 中。
- Reject 后 plan 文本保留，agent 收到 rejection feedback。

**依赖:** F-D1, F-D3

---

#### F-D5 · PlanModeSystemPromptInjector

**优先级:** P1  
**来源:** `tools/EnterPlanModeTool` tool result + `tools/ExitPlanModeTool` → `mapToolResultToToolResultBlockParam`

**做什么:** 在 plan mode 期间，在每次构建 system prompt 时注入只读约束块，并在 plan 已 approved 后注入 `allowedActions` 权限上下文（例如"你被允许运行 xcodebuild test，但不允许修改 Package.swift"）。这把 plan 审批的结果结构化注入到模型上下文，而不是依靠用户记得约束。

**新增文件:** `agentGui/Services/BuiltInTools/PlanModeSystemPromptInjector.swift`

**接入点:** `ClaudeService` 或 `BuiltInAgentQueryEngine` 构建 system prompt 时。

**验收标准:**
- Plan mode 下，system prompt 中包含只读约束，不包含写操作权限。
- Plan approved 后，system prompt 包含 `allowedActions` 列表。

**依赖:** F-D1, F-D2, F-D3

---

#### F-D6 · WorkerCardPlanGate

**优先级:** P2  
**来源:** `tasks/InProcessTeammateTask/types.ts` → `awaitingPlanApproval: boolean`

**做什么:** Team Worker card 在进入"执行"阶段前，检查该 worker 是否已完成 plan 阶段（`PlanArtifact.status == .approved`）。若 team 设定了 `planRequired = true` 但 worker 尚未提交 plan，则阻止 claim 进入执行，并在 task board 上显示「等待 Plan 审批」状态。

**新增文件:** `agentGui/Services/AgentTeam/WorkerCardPlanGate.swift`

**接入点:** `AgentTeamClaimExecutionGate` 的前置校验。

**验收标准:**
- `planRequired` team 中的 worker 在 plan 未批准前，不能进入 executing 状态。
- conductor 收到 plan approval request 后，approval UI 出现在 conductor 的 session 中。

**依赖:** F-D1, F-D3, F-D4

---

### Layer E — 团队协作控制面（Team Control Plane）

这一层让 Agent Team 从"任务板 UI"进化为真实的 multi-agent runtime，P2 优先级，建议在 Plan Mode 稳定后启动。

---

#### F-E1 · TeammateMessage SwiftData 模型

**优先级:** P2  
**来源:** `tools/SendMessageTool/SendMessageTool.ts` → `StructuredMessage` discriminated union

**做什么:** 新增 `TeammateMessage` SwiftData `@Model`，表示 Agent Team 内部的结构化通信单元。消息类型参考 Claude Code 的三类原语：

```swift
@Model final class TeammateMessage {
    var id: UUID
    var teamSessionID: UUID
    var senderAgentID: String          // agentID (workerName@teamName)
    var recipientAgentID: String       // agentID or "*" (broadcast)
    var type: TeammateMessageType
    var summary: String?               // 5-10 word preview
    var textPayload: String?           // plain text memo
    var requestID: String?             // for shutdown_request / plan_approval_response
    var approved: Bool?                // for response types
    var feedback: String?              // for plan_approval_response
    var createdAt: Date
    var readAt: Date?
}

enum TeammateMessageType: String, Codable {
    case memo                          // plain text message
    case shutdownRequest
    case shutdownResponse
    case planApprovalRequest
    case planApprovalResponse
    case reviewRequest
    case reviewResponse
}
```

**新增文件:** `agentGui/Models/TeammateMessage.swift`

**接入点:** 纳入 SwiftData schema；`AgentTeamSessionState` 以 `@Relationship` 引用。

**验收标准:**
- 消息可随 team session 持久化，重启后可读取。
- 所有消息类型 Codable，可完整往返序列化。

**依赖:** 无

---

#### F-E2 · TeamMessageBus

**优先级:** P2  
**来源:** `utils/teammateMailbox.ts` → `writeToMailbox`、`tools/SendMessageTool`

**做什么:** 提供 conductor 与 workers 之间的结构化消息路由服务：

- `sendMessage(from:, to:, message:)` — 单播；`to == "*"` 时广播。
- `pendingMessages(forAgent:)` — 返回某个 agent 的未读消息队列。
- `markRead(messageID:)` — 标记已读。

消息持久化到 `TeammateMessage` SwiftData 存储，不依赖运行时内存。

**新增文件:** `agentGui/Services/AgentTeam/TeamMessageBus.swift`

**接入点:** Worker/Conductor built-in agent 表达 SendMessage 工具时调用；`AgentTeamWorkbenchPresentation` 监听未读消息。

**验收标准:**
- Conductor 发出的 memo 可在 worker 进度页面中显示。
- Plan approval request 发出后，conductor 侧收到 pending approval 通知。
- 跨 session 恢复后，未读消息仍存在。

**依赖:** F-E1

---

#### F-E3 · TeamMemoryStore

**优先级:** P2  
**来源:** `memdir/memdir.ts` + `services/teamMemorySync/` + `memdir/teamMemPaths.ts`

**做什么:** 提供 team-scoped 的跨 card 持久化事实存储。每个 team session 有一个 `TeamMemoryStore`，workers 可以读写。写入前运行简单的 secret scanner（检测明显的 credential 模式：API keys、passwords），阻止意外持久化凭证。

**数据结构:**

```swift
struct TeamMemoryEntry: Codable, Identifiable {
    var id: UUID
    var key: String                    // human-readable label
    var value: String                  // fact content
    var addedByAgentID: String
    var addedAt: Date
    var tags: [String]
}
```

作为 team-scoped MEMORY.md 的结构化补充，也可以序列化为 Markdown 注入 system prompt（参考 Claude Code `teamMemPrompts.ts`）。

**新增文件:** `agentGui/Services/AgentTeam/TeamMemoryStore.swift`

**接入点:** 内置 `team_memory_write` / `team_memory_read` 工具注册到 conductor/worker 可见的 `ToolRegistry`。

**验收标准:**
- Worker A 写入的 team memory 可被 Worker B 在不同 session 中读取。
- 写入包含明显凭证模式的 key 时被拦截并提示。
- Team memory 内容可注入 system prompt。

**依赖:** F-E1

---

#### F-E4 · TeamResumeBootstrapper

**优先级:** P2  
**来源:** `hooks/useSwarmInitialization.ts`

**做什么:** 在恢复一个 team session 时，自动重建 runtime 上下文：

1. 加载 team roster（conductor + workers）和各自状态。
2. 恢复 active card、claim owner、task board 状态。
3. 恢复 pending approvals（plan approval、review request）。
4. 恢复 `AgentTeamSessionState` 的执行上下文（哪些 card 在执行/等待/完成）。
5. 恢复 pending `TeammateMessage`（未读消息重新进入 inbox）。

**新增文件:** `agentGui/Services/AgentTeam/TeamResumeBootstrapper.swift`

**接入点:** `AgentTeamLaunchCoordinator` 在恢复已有 team session 时调用（区别于 launch fresh）。

**验收标准:**
- 关闭 app 后重新打开 team session，所有 card 状态和未读消息均正确恢复。
- 处于 `awaitingPlanApproval` 的 worker card 在恢复后仍处于等待态。

**依赖:** F-E1, F-E2, F-E3

---

#### F-E5 · WorkerIdentity 内存上限

**优先级:** P1  
**来源:** `tasks/InProcessTeammateTask/types.ts` → `TEAMMATE_MESSAGES_UI_CAP = 50`

**做什么:** 为 `AgentTeamWorkbenchPresentation` 中每个 worker 的 UI 消息镜像数组设置上限（建议 50 条），超出时丢弃最旧的消息。完整历史仅保留在 SwiftData `Message` 持久化记录中，不在内存中保留双份。

BQ 数据支撑：292 个并发 agent × 每个全量消息数组 ≈ 36.8 GB RSS。50 条 cap 将每个 worker 的内存占用降低约 90%。

**修改文件:** `agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift`（或对应的 ViewModel）

**接入点:** Worker 消息追加逻辑处，加入 cap 截断。

**验收标准:**
- Worker 消息数组长度不超过 50。
- 超出 cap 后，最旧的消息被丢弃，UI 不崩溃，滚动逻辑正常。

**依赖:** 无

---

### Layer F — 类型化任务运行时（Typed Task Runtime）

此层为长期演进方向，使 agent 任务从 flat todo list 升级为可依赖、可验证的结构化任务图。

---

#### F-F1 · TypedExecutionTask SwiftData 模型

**优先级:** P2  
**来源:** `tools/TaskCreateTool/TaskCreateTool.ts`、`utils/tasks.ts`

**做什么:** 新增 `TypedExecutionTask` SwiftData `@Model`，作为替代 flat todo 的结构化任务单元。

```swift
@Model final class TypedExecutionTask {
    var id: UUID
    var sessionID: UUID
    var taskListID: String             // namespaced by session/team
    var subject: String
    var taskDescription: String
    var activeForm: String?            // present continuous e.g. "Running tests"
    var status: TypedTaskStatus        // pending / inProgress / completed / blocked / cancelled
    var ownerAgentID: String?
    var blockedBy: [UUID]              // other task IDs
    var blocks: [UUID]                 // downstream tasks
    var metadata: Data?                // arbitrary JSON-encoded metadata
    var createdAt: Date
    var completedAt: Date?
    var teamCardID: UUID?              // maps to AgentTeamCard if team mode
}

enum TypedTaskStatus: String, Codable {
    case pending, inProgress, completed, blocked, cancelled
}
```

**新增文件:** `agentGui/Models/TypedExecutionTask.swift`

**接入点:** 纳入 SwiftData schema；`Session` 以 `@Relationship` 引用；与现有 todo 工具并存，通过 `isTodoV2Enabled` gate 控制切换。

**验收标准:**
- 任务可被 agent 创建、更新、阻塞、完成。
- blockedBy 依赖关系可被校验（blocked task 不能进入 inProgress）。

**依赖:** 无

---

#### F-F2 · TypedTaskStore

**优先级:** P2  
**来源:** `utils/tasks.ts` CRUD functions

**做什么:** 提供 `TypedExecutionTask` 的 CRUD 接口，包含状态机验证（禁止非法状态转换）和依赖关系查询（`isBlocked(taskID:)`）。

**新增文件:** `agentGui/Repositories/TypedTaskStore.swift`

**接入点:** 内置工具（TaskCreate / TaskUpdate / TaskList / TaskGet）调用此 store。

**验收标准:**
- 全部 CRUD 操作有单元测试。
- 状态机非法转换（如 completed → inProgress）被拦截。

**依赖:** F-F1

---

#### F-F3 · Task 内置工具集（task_create / task_update / task_list / task_get）

**优先级:** P2  
**来源:** `tools/TaskCreateTool`、`tools/TaskUpdateTool`、`tools/TaskListTool`、`tools/TaskGetTool`

**做什么:** 将 Claude Code 的 typed task API 移植为 agentGui 内置工具集：

- `task_create`：创建任务，支持 subject / description / activeForm / metadata / blockedBy。
- `task_update`：更新任务状态、owner、blockedBy。
- `task_list`：列出当前 session/team 的所有任务，可按 status 过滤。
- `task_get`：按 ID 读取任务详情。

工具结果触发 `TaskCreatedHookDispatcher`（F-F4）。

**新增文件:** `agentGui/Services/BuiltInTools/TypedTask/` 目录下四个工具文件

**接入点:** 注册到 `ToolRegistry`，通过 `isTodoV2Enabled` gate 和 `TodoWriteTool` 互斥。

**验收标准:**
- Agent 可通过 task_create 创建有依赖关系的任务，task board 能正确展示。
- task_update 把 status 改为 inProgress 时，`activeForm` 文本显示在 task indicator 中。

**依赖:** F-F1, F-F2

---

#### F-F4 · TaskCreatedHookDispatcher

**优先级:** P2  
**来源:** `tools/TaskCreateTool` → `executeTaskCreatedHooks()`

**做什么:** 每次通过 `task_create` 工具创建 `TypedExecutionTask` 后，运行一组 task created hooks。Hook 可以校验任务合法性、检测依赖冲突、或注入初始化数据。若 hook 返回 blocking error，任务创建回滚。

**新增文件:** `agentGui/Services/ToolGovernance/TaskCreatedHookDispatcher.swift`

**接入点:** `TypedTaskStore.create()` 调用后。

**验收标准:**
- Hook 返回 blocking error 时，任务不被持久化，agent 收到明确错误消息。
- Hook 执行失败（非 blocking）不影响任务创建。

**依赖:** F-C2, F-F1, F-F2

---

## 8. Feature 优先级汇总

| Feature | 名称 | 优先级 | 依赖 |
|---------|------|--------|------|
| F-C1 | ToolConcurrencyBatchPlanner | P0 | — |
| F-C2 | ToolExecutionHookPipeline | P0 | — |
| F-C3 | ChangeReviewHook | P0 | F-C2 |
| F-C4 | VerificationEvidenceHook | P0 | F-C2 |
| F-B1 | ContextWindowBudgetTracker | P0 | — |
| F-B4 | ResumeSummaryService | P0 | — |
| F-B5 | ToolBatchSummaryService | P0 | F-C1 |
| F-E5 | WorkerIdentity 内存上限 | P1 | — |
| F-C5 | PayloadBudgetHook | P1 | F-C2 |
| F-C6 | ToolExposurePolicy | P1 | F-D1 |
| F-B2 | MessageInvariantValidator | P1 | — |
| F-B3 | CompactionCoordinator | P1 | F-B1, F-B2 |
| F-D1 | PlanArtifact 模型 | P1 | — |
| F-D2 | EnterPlanModeTool | P1 | F-D1, F-C6 |
| F-D3 | ExitPlanModeTool | P1 | F-D1, F-D2 |
| F-D4 | PlanApprovalFlowView | P1 | F-D1, F-D3 |
| F-D5 | PlanModeSystemPromptInjector | P1 | F-D1, F-D2, F-D3 |
| F-E1 | TeammateMessage 模型 | P2 | — |
| F-E2 | TeamMessageBus | P2 | F-E1 |
| F-E3 | TeamMemoryStore | P2 | F-E1 |
| F-E4 | TeamResumeBootstrapper | P2 | F-E1, F-E2, F-E3 |
| F-D6 | WorkerCardPlanGate | P2 | F-D1, F-D3, F-D4 |
| F-F1 | TypedExecutionTask 模型 | P2 | — |
| F-F2 | TypedTaskStore | P2 | F-F1 |
| F-F3 | Task 内置工具集 | P2 | F-F1, F-F2 |
| F-F4 | TaskCreatedHookDispatcher | P2 | F-C2, F-F1, F-F2 |
| F-B6 | SubagentProgressSummarizer | P1（与 S-C4 对齐） | F-C1，S-C1，S-C2 |

---

## 9. 新增文件目录结构

```text
agentGui/
  Models/
    PlanArtifact.swift                     ← F-D1
    TeammateMessage.swift                  ← F-E1
    TypedExecutionTask.swift               ← F-F1
  Services/
    ToolGovernance/
      ToolConcurrencyBatchPlanner.swift    ← F-C1
      ToolExecutionHookPipeline.swift      ← F-C2
      ToolExposurePolicy.swift             ← F-C6
      TaskCreatedHookDispatcher.swift      ← F-F4
      Hooks/
        ChangeReviewHook.swift             ← F-C3
        VerificationEvidenceHook.swift     ← F-C4
        PayloadBudgetHook.swift            ← F-C5
    ContextGovernance/
      ContextWindowBudgetTracker.swift     ← F-B1
      MessageInvariantValidator.swift      ← F-B2
      CompactionCoordinator.swift          ← F-B3
      ResumeSummaryService.swift           ← F-B4
      ToolBatchSummaryService.swift        ← F-B5
    SubagentGovernance/
      SubagentProgressSummarizer.swift     ← F-B6/S-C4（规范路径，见 subagent 增强设计文档 S-C4）
    BuiltInTools/
      EnterPlanModeTool.swift              ← F-D2
      ExitPlanModeTool.swift               ← F-D3
      PlanModeSystemPromptInjector.swift   ← F-D5
      TypedTask/
        TaskCreateTool.swift               ← F-F3
        TaskUpdateTool.swift               ← F-F3
        TaskListTool.swift                 ← F-F3
        TaskGetTool.swift                  ← F-F3
    AgentTeam/
      TeamMessageBus.swift                 ← F-E2
      TeamMemoryStore.swift                ← F-E3
      TeamResumeBootstrapper.swift         ← F-E4
      WorkerCardPlanGate.swift             ← F-D6
  Repositories/
    TypedTaskStore.swift                   ← F-F2
  Views/
    PlanApprovalFlowView.swift             ← F-D4
```

---

## 10. 最终判断

Claude Code 源码对 agentGui 最有价值的启发不是"多几个工具"，而是以下三个更本质的产品结论：

1. **真正强的 built-in agent，一定有独立于聊天 UI 的执行治理层。** P0 层（F-C1/C2/C3/C4/B1/B4/B5，共 7 个 Feature）立即可落地，几乎不改 UI 大结构，但能显著提升复杂任务的可观测性和吞吐。

2. **复杂任务的成功率，很大程度上取决于 plan mode、context governance 和 hook pipeline，而不是模型本身。** P1 层（F-B2/B3/C5/C6/D1~D5/E5，共 9 个 Feature）是最有杠杆力的结构性改进，能把当前"能运行但容易跑偏"的 agent 升级为"有设计冻结点、有上下文治理"的生产级 agent。

3. **多 agent 协作要想真正有效，必须同时具备任务板、消息路由、共享记忆和恢复机制。** P2 层（F-E1~E4/D6/F1~F4/B6，共 11 个 Feature）让 Agent Team 从可视化任务板升级为真实的协作 runtime，缺任何一层都会退化成并排运行的多个单体 agent。

对 agentGui 而言，最正确的路线是：先落 P0（7 个 Feature，纯服务层，无 UI 破坏），再落 P1（9 个 Feature，plan mode + compaction），最后落 P2（11 个 Feature，team control plane + typed tasks）。
