# Built-in Agent 长任务处理能力提升 — 设计文档

> 基于 Claude Code 源码（`/Users/feint/Downloads/claude-code-source-code-main`）深度分析，结合 agentGui 现状，制定的重构路线图。
>
> 文档日期：2026-04-02

---

## 一、现状与差距分析

### 1.1 Claude Code 在长任务处理上的核心设计

分析 Claude Code 源码后，识别出以下与长任务直接相关的子系统：

| 子系统 | 关键文件 | 核心能力 |
|---|---|---|
| QueryEngine | `src/QueryEngine.ts` | 跨 turn 的会话状态、HISTORY_SNIP 机制、maxTurns/maxBudget 注入 |
| Auto-Compact | `src/services/compact/autoCompact.ts` | Token 阈值触发压缩，连续失败熔断（MAX=3次） |
| Micro-Compact | `src/services/compact/microCompact.ts` | 工具结果级别粗化，TIME_BASED_MC 策略 |
| Full Compact | `src/services/compact/compact.ts` | Fork-agent 生成摘要，写入 CompactBoundaryMessage |
| SessionMemory Compact | `src/services/compact/sessionMemoryCompact.ts` | 感知 session memory 的精准压缩，min/maxToken 配置 |
| Task 生命周期 | `src/Task.ts` / `src/tasks/` | 6 种任务类型，formal 状态机，isTerminalTaskStatus 守卫 |
| Progress Tracker | `src/tasks/LocalAgentTask/LocalAgentTask.tsx` | 工具调用计数、Input/Output Token 分离统计、recentActivities |
| Agent Summary | `src/services/AgentSummary/agentSummary.ts` | 每 30s Fork-agent 生成 3-5 词进度摘要 |
| Tool Use Summary | `src/services/toolUseSummary/toolUseSummaryGenerator.ts` | Haiku 生成 ≤30 字符的工具批次摘要标签 |
| Token Budget | `src/utils/tokenBudget.ts` | 解析用户消息中的 token 预算（+500k、2M tokens），超出时发送续行注入 |
| Resume | `src/tools/AgentTool/resumeAgent.ts` | Transcript 重建，过滤孤立 ToolCall，重建 contentReplacementState |
| Plan Mode | `src/tools/EnterPlanModeTool/` + `src/utils/plans.ts` | 独立 Plan 文件、word-slug 命名、ExitPlanMode 工具触发审批 |
| Hook Pipeline | `src/utils/hooks.ts` | Pre/post-compact hooks、sessionStart hooks、tool permission hooks |
| In-Process Teammate | `src/utils/swarm/inProcessRunner.ts` | AsyncLocalStorage 隔离、mailbox 消息总线、Leader 权限桥接 |

### 1.2 agentGui 当前状态

- ✅ 已有：`ConversationExecutionRuntimeCoordinator`、`ToolCall` 模型、`AgentTeam Workbench`、`RuntimeSnapshot`、`ClaudeService` streaming
- ✅ 已有：基础 Plan Mode（来自历史 feature）、Agent Team task board
- ❌ 缺失：**Context Compaction 策略**（上下文窗口满时无处理）
- ❌ 缺失：**Token 预算治理**（无 maxTokens/maxTurns 控制层）
- ❌ 缺失：**任务 Resume/Recovery**（agent 中断后无法续接）
- ❌ 缺失：**Progress Tracking 标准化**（无工具级别进度聚合）
- ❌ 缺失：**Micro-Compact**（工具结果无老化清除机制）
- ❌ 缺失：**Hook Pipeline**（无 pre/post-compact、tool-use 事件钩子）
- ❌ 缺失：**Tool Use Summary 轻量标签**（轮次间没有可读进度提示）

---

## 二、Feature 划分

按优先级（P0 = 阻塞长任务基本可用；P1 = 显著提升稳定性；P2 = 体验增强）划分为 10 个独立 Feature。

---

### Feature L-1：Token 预算与轮次上限治理  `P0`

**问题**：长任务无 maxTurns / maxTokens 约束，会话可能无限运行或因 API 报错 `prompt_too_long` 而崩溃。

**参考**：`QueryEngineConfig.maxTurns`、`QueryEngineConfig.maxBudgetUsd`、`tokenBudget.ts`

**设计要点**
```
┌─────────────────────────────────────────────────┐
│  AgentExecutionPolicy (new struct)               │
│    maxTurns: Int?                                │
│    maxInputTokens: Int?                          │
│    maxCostUSD: Double?                           │
│    tokenBudgetContinuationThreshold: Double      │
└─────────────────────────────────────────────────┘
         │ injected into
         ▼
┌─────────────────────────────────────────────────┐
│  ConversationExecutionRuntimeCoordinator         │
│    - 每轮检查 turnCount >= maxTurns → 停止       │
│    - 累计 tokens ≥ maxInputTokens → 发送续行注入 │
│    - 用量超 maxCostUSD → 触发 L-3 压缩           │
└─────────────────────────────────────────────────┘
```

**工作项**
1. 新建 `AgentExecutionPolicy` struct（`Models/AgentExecutionPolicy.swift`）
2. `ConversationExecutionRuntimeCoordinator` 添加 `policy: AgentExecutionPolicy` 属性
3. 每轮 round 开始前检查 turn count 和 accumulated token 用量
4. token 超阈值时注入 "Keep working — do not summarize. (X% of budget used)" 系统消息
5. UI：`AgentPolicyEditorView`（最大轮次 / 最大 token 滑块），默认：maxTurns=50，maxInputTokens = 180k

**测试**：`AgentExecutionPolicyTests` — 5 个用例（阈值触发、注入消息格式、超限停止）

---

### Feature L-2：Progress Tracker 标准化  `P0`

**问题**：长任务运行时用户无法知晓 agent 做了什么（工具调用数、token 消耗、最近活动）。

**参考**：`LocalAgentTask.tsx`：`ProgressTracker`，`updateProgressFromMessage`，`MAX_RECENT_ACTIVITIES = 5`

**设计要点**
```swift
struct AgentProgressSnapshot {
    var turnCount: Int
    var toolCallCount: Int
    var inputTokensLatest: Int     // cumulative from API (keep latest)
    var outputTokensCumulative: Int // per-turn sum
    var recentActivities: [ToolActivity] // max 5
    var currentSummary: String?
}

struct ToolActivity {
    var toolName: String
    var displayLabel: String       // "Reading src/foo.swift"
    var isSearch: Bool
    var timestamp: Date
}
```

**工作项**
1. 新建 `AgentProgressSnapshot.swift` 和 `ToolActivity.swift`
2. `ConversationExecutionRuntimeCoordinator` 每收到 assistant message 时更新 snapshot
3. Input token 计数策略：取 API response 最新值（而非累加）；output 累加
4. `AgentProgressView`：工具调用数 badge、token pill、最近 5 条活动列表（可折叠）
5. recentActivities 环形 buffer（最多 5 条，旧的自动移除）

**测试**：`AgentProgressSnapshotTests` — Token 计数逻辑（input 取最新、output 累加）

---

### Feature L-3：Auto-Compact（上下文自动压缩）  `P0`

**问题**：上下文窗口接近上限时没有任何处理，导致 API 报错或截断。

**参考**：`autoCompact.ts`（阈值 = contextWindow - 13k buffer）、`compact.ts`（forked agent 生成摘要）

**设计要点**
```
Token Usage ≥ AutoCompactThreshold
           │
           ▼
  ┌─────────────────────────────────┐
  │  CompactionCoordinator          │
  │  - 检查 consecutiveFailures      │
  │    ≥ 3 → 停止重试（熔断）        │
  │  - 调用 summarizeConversation()  │
  │    (via ClaudeService haiku)     │
  │  - 写入 CompactBoundaryMessage   │
  │  - 重建精简版 messages           │
  └─────────────────────────────────┘
```

**CompactBoundaryMessage**
```swift
struct CompactBoundaryMessage: Identifiable {
    let id: UUID
    let timestamp: Date
    let summaryText: String         // 压缩摘要
    let preservedMessageCount: Int  // 保留的近期消息数
    let droppedTokens: Int
}
```

**工作项**
1. 新建 `CompactionCoordinator.swift` actor
2. `getAutoCompactThreshold(model:) -> Int`：contextWindow - 13k buffer
3. 调用 `ClaudeService.summarize(messages:)` 生成对话摘要（使用 haiku/sonnet-3-5）
4. 生成 CompactBoundaryMessage，替换历史消息为：[boundary + 摘要 + 最近 N 条]
5. consecutiveFailures 计数，≥ 3 次触发熔断（停止压缩，告警用户）
6. 压缩后重置 microCompact 状态（参考 `resetMicrocompactState()`）

**测试**：`CompactionCoordinatorTests` — 阈值计算、熔断逻辑、消息重建验证

---

### Feature L-4：Micro-Compact（工具结果老化清除）  `P1`

**问题**：长任务中大量 FileRead / Bash 结果累积在上下文，占用大量 token 但已无参考价值。

**参考**：`microCompact.ts`：`TIME_BASED_MC_CLEARED_MESSAGE = '[Old tool result content cleared]'`，仅压缩 `COMPACTABLE_TOOLS`（FileRead、Bash、Grep、Glob、WebSearch、FileEdit、FileWrite）

**设计要点**
```
每轮 round 开始前，扫描 messages：
  - 工具类型 ∈ COMPACTABLE_TOOLS
  - 消息年龄 > ageThreshold（默认：距当前 > 10 轮）
  - 消息 tokens > 2000
→ 用占位文本替换内容：
  "[旧工具结果已清除 - 使用 ReadFile 重新读取]"
```

**工作项**
1. 新建 `MicroCompactPass.swift`：定义可压缩工具集、age threshold、大小 threshold
2. `ConversationExecutionRuntimeCoordinator` 在每轮 round 前触发 `MicroCompactPass.run(messages:)`
3. 图片结果特殊处理（token 估算 > 2000 时清除）
4. 保留最近 2 轮的所有工具结果（滑动窗口保护）

**测试**：`MicroCompactPassTests` — age 判断、工具过滤、占位文本格式

---

### Feature L-5：Task Resume（任务中断续接）  `P1`

**问题**：agent 因网络中断、应用退出、token 超限等原因停止后，任务进度全部丢失。

**参考**：`resumeAgent.ts`：从 transcript 重建消息，过滤孤立 ToolCall，重建 contentReplacementState

**设计要点**
```
每轮 round 完成后：
  RuntimeSnapshot 持久化（SwiftData）
    - messages[] (序列化)
    - toolCallResults{}: [toolUseId → result 占位]
    - progressSnapshot
    - policy

Resume 触发（用户点击「续接」或 app 重启检测）：
  1. loadSnapshot(sessionId)
  2. filterOrphanedToolUses(messages)      // 移除未完成的 tool_use
  3. filterWhitespaceOnlyAssistant(msgs)   // 清理空白 assistant 消息
  4. buildResumedMessages → injected into new round
```

**工作项**
1. `RuntimeSnapshot.swift` 增加 `resumeCheckpoint` 字段（上次完整 round 的 messages + policy）
2. `RestoreFilter.swift`：实现 filterOrphanedToolUses / filterWhitespaceOnly 两个过滤器
3. `ConversationExecutionRuntimeCoordinator.resume(from:)` 入口
4. UI：Session 列表显示可续接状态（"⏸ 已暂停，点击续接"）
5. 冲突检测：若 snapshot 的最后消息 timestamp > 应用重启时间 → 显示确认对话框

**测试**：`RuntimeResumeTests` — 孤立 tool_use 过滤、空白消息过滤、resume 后第一轮输入注入

---

### Feature L-6：Tool Use Summary 轻量标签  `P1`

**问题**：每轮 round 内执行了大量工具调用，用户看不到本轮「做了什么」的简短摘要。

**参考**：`toolUseSummaryGenerator.ts`：Haiku 生成 ≤30 字符 git-commit-style 标签，示例："Fixed NPE in UserService"

**设计要点**
```swift
// 每轮 assistant 消息完成后，异步生成摘要
actor ToolUseSummaryService {
    func generateLabel(
        toolCalls: [ToolCall],
        lastAssistantText: String?
    ) async -> String?    // "读取 ContentView.swift"
}
```

**工作项**
1. 新建 `ToolUseSummaryService.swift` actor
2. 调用 `ClaudeService.queryHaiku(prompt:)` 生成标签（异步，不阻塞主流程）
3. 系统提示词仿照 Claude Code：强制 ≤30 字，动词过去式，名词具体
4. `Message` 模型增加 `turnLabel: String?` 字段（SwiftData 可选）
5. ChatView：在每轮 round 的折叠区域顶部显示 turnLabel badge

**测试**：`ToolUseSummaryServiceTests` — 空工具调用返回 nil、label 长度上限验证

---

### Feature L-7：Plan Mode 形式化  `P1`

**问题**：Plan Mode 缺乏独立的 Plan 文件持久化和 ExitPlanMode 审批流，导致复杂任务缺少人工确认节点。

**参考**：`plans.ts`（getPlanSlug、getPlansDirectory）、`EnterPlanModeTool/`、`ExitPlanModeTool/`

**设计要点**
```
AgentTool 调用 enter_plan_mode
    │
    ▼
PlanFile 写入 ~/.agentGui/plans/{slug}.md
    │
    ▼
ConversationExecution 进入 .awaitingApproval 状态
    │
    ▼
User 审批（Approve / Edit / Reject）
    │
    ▼
exit_plan_mode → Resume execution
```

**Plan 文件结构**（Markdown）
```markdown
# 任务计划
> Session: {slug}  Date: {timestamp}

## 目标
...

## 步骤
- [ ] 步骤1
- [ ] 步骤2

## 风险
...
```

**工作项**
1. `PlanManager.swift`：`createPlan(sessionId:) -> PlanFile`，`getPlanPath(slug:) -> URL`，word-slug 生成（随机两词组合）
2. `PlanFile.swift` SwiftData model：id、slug、content、sessionId、createdAt
3. `BuiltInSkillRegistry` 注册 `enter_plan_mode` 和 `exit_plan_mode` 两个内置 skill
4. `ConversationExecutionState` 增加 `.awaitingPlanApproval(planId:)` case
5. UI：`PlanApprovalView`（显示 Plan Markdown、三个按钮：批准 / 编辑后批准 / 拒绝）

**测试**：`PlanManagerTests` + `PlanApprovalFlowTests` — slug 唯一性、状态转换

---

### Feature L-8：Lifecycle Hook Pipeline  `P2`

**问题**：无法在压缩前保存状态、压缩后恢复、工具调用前后注入自定义逻辑。

**参考**：`hooks.ts`：`executePreCompactHooks`、`executePostCompactHooks`、`processSessionStartHooks`

**设计要点**
```swift
protocol AgentLifecycleHook {
    var event: AgentHookEvent { get }
    func execute(context: HookContext) async throws -> HookResult
}

enum AgentHookEvent {
    case sessionStart
    case preCompact
    case postCompact
    case toolWillExecute(toolName: String)
    case toolDidExecute(toolName: String)
    case roundWillStart(turnNumber: Int)
    case roundDidComplete(turnNumber: Int)
}
```

**工作项**
1. `AgentLifecycleHook.swift` protocol + `AgentHookEvent` enum
2. `HookRegistry.swift`：注册/注销 hooks，按 event 分组存储
3. `ConversationExecutionRuntimeCoordinator` 在各生命周期节点调用 `HookRegistry.fire(event:)`
4. 内置 Hook：`ProgressPersistenceHook`（每轮完成后持久化 snapshot，用于 L-5 Resume）
5. 内置 Hook：`CompactNotificationHook`（压缩完成后在 UI 显示通知）
6. 开放 Hook API 供 BuiltInSkill 注册自定义 hooks

**测试**：`HookRegistryTests` — 注册/注销、事件触发顺序、hook 抛错时的隔离

---

### Feature L-9：Context Analysis Dashboard  `P2`

**问题**：用户无法直观看到上下文窗口的组成（哪些工具调用占了多少 token），无法做出手动干预决策。

**参考**：`contextAnalysis.ts`：`analyzeContext(messages)` 返回 toolRequests/toolResults/duplicateFileReads/attachments 的 token 分布

**设计要点**
```
┌──────────────────────────────────────────┐
│  Context Usage (180k / 200k tokens)      │
│  ████████████████████░░░░░  90%          │
│                                          │
│  ToolResults:     85k  ████████████ 47%  │
│  HumanMessages:   30k  ████       17%   │
│  AssistantText:   40k  █████      22%   │
│  Attachments:     25k  ███        14%   │
│                                          │
│  ⚠️ 重复读取: ContentView.swift (x4, 12k) │
│                                          │
│  [立即压缩]  [清除旧工具结果]              │
└──────────────────────────────────────────┘
```

**工作项**
1. `ContextAnalyzer.swift`：replicate `analyzeContext()` 逻辑（工具请求/结果 token 分布、重复读取检测）
2. `ContextUsageModel.swift`：`tokensByCategory: [String: Int]`、`duplicateReads: [String: DuplicateReadInfo]`
3. `ContextDashboardView.swift`：进度条 + 分类 breakdown + 重复文件列表
4. 手动操作按钮：「立即压缩」触发 L-3、「清除旧工具结果」触发 L-4
5. 集成到 `ChatView` 侧边栏（折叠面板）

**测试**：`ContextAnalyzerTests` — token 分类准确性、重复读取检测

---

### Feature L-10：Agent Summarization（周期性进度摘要）  `P2`

**问题**：长时间运行的 agent 在后台时，用户不知道 agent 当前正在做什么（超过显示刷新频率）。

**参考**：`agentSummary.ts`：每 30s fork 一次生成 3-5 词现在进行时摘要（"Reading runAgent.ts"），感知上次摘要避免重复

**设计要点**
```swift
actor AgentSummarizationService {
    let interval: TimeInterval = 30
    var previousSummary: String? = nil
    
    func startPeriodicSummarization(
        agentId: UUID,
        messagesProvider: @escaping () -> [Message]
    ) -> AnyCancellable
}
```

摘要 prompt 要点（仿 Claude Code）：
- 3-5 词，现在进行时（-ing）
- 命名具体文件/函数，非分支/泛化描述
- 若有上次摘要，要求说「不同的事」

**工作项**
1. `AgentSummarizationService.swift` actor，Timer + async task
2. 调用 `ClaudeService.queryHaiku(prompt:systemPrompt:)` fork 摘要（无工具调用）
3. 更新 `AgentProgressSnapshot.currentSummary`（L-2 已定义）
4. UI：会话列表 / 状态栏 pill 显示 currentSummary
5. stop() 清理，保证 agent 完成后不再触发

**测试**：`AgentSummarizationServiceTests` — 停止逻辑、最少消息数量守卫（< 3 条时跳过）

---

## 三、实施顺序与依赖关系

```
L-1 Token Budget ──────────────────────────────────────────────┐
L-2 Progress Tracker ──────────────────────────────────────┐   │
L-3 Auto-Compact ──────────────────────────────────────┐   │   │
L-4 Micro-Compact ──────────────┐                      │   │   │
                                 │                      │   │   │
L-5 Task Resume ◄────────────── L-4, L-2              │   │   │
L-6 Tool Use Summary ◄────────── L-2                  │   │   │
L-7 Plan Mode ◄───────────────── (独立)               │   │   │
L-8 Hook Pipeline ◄──────────── L-3, L-1 ─────────────┘   │   │
L-9 Context Dashboard ◄────────── L-3, L-4, L-2 ──────────┘   │
L-10 Agent Summarization ◄───────── L-2, L-6 ─────────────────┘
```

**推荐迭代节奏**

| Sprint | Features | 目标 |
|---|---|---|
| Sprint 1（2周）| L-1 + L-2 | 基础治理层可用 |
| Sprint 2（2周）| L-3 + L-4 | 上下文压缩可用，长任务不再崩溃 |
| Sprint 3（2周）| L-5 + L-6 | Resume 和进度标签，用户体验提升 |
| Sprint 4（2周）| L-7 + L-8 | Plan Mode 专业化 + Hook 扩展点 |
| Sprint 5（2周）| L-9 + L-10 | 可视化增强，打磨 |

---

## 四、关键设计决策

### 4.1 Compaction 策略：Fork vs. In-Process

Claude Code 选择 **fork agent**（新建对话调用 Claude 生成摘要），优点：
- 主对话的上下文不被摘要请求污染
- 可以使用较小的模型（haiku）来节省成本

agentGui 同样应采用此策略：`CompactionCoordinator` 通过 `ClaudeService` 创建一个独立的单次 query，传入 `[compact prompt + messages slice]`，获得摘要后销毁。

### 4.2 Token 计数：Input 取最新，Output 累加

Claude API 的 `input_tokens` 是**累积值**（包含所有历史 token 的 cache 指标），而 `output_tokens` 是**本轮输出**。

错误的做法：累加所有轮次的 `input_tokens`（会严重虚高）。
正确做法：始终用最新 response 的 `input_tokens` 值作为当前上下文大小估计。

### 4.3 Circuit Breaker：Compaction 连续失败保护

与 Claude Code 一致：连续压缩失败 ≥ 3 次时停止重试，切换为「告警用户，禁止继续 round」状态，避免无效 API 调用风暴（Claude Code 的 BQ 数据：存在每会话高达 3272 次连续失败）。

### 4.4 SwiftData 序列化注意事项

- `Message` 的 `content` 字段可能含 `Data`（图片），序列化时需单独存储至文件系统，SwiftData 只保存 URL 引用
- `CompactBoundaryMessage` 应作为独立 `@Model` 存储，支持按 sessionId 查询
- `AgentProgressSnapshot` 为 transient 数据，不持久化；`RuntimeSnapshot` 持久化（已有）

---

## 五、风险与缓解

| 风险 | 概率 | 缓解方案 |
|---|---|---|
| Compaction 压缩摘要质量差，导致 agent 丢失关键上下文 | 中 | 保留最近 20 条完整消息后再丢弃旧的；允许用户手动调整保留数量 |
| Resume 后工具调用状态与实际文件系统不一致 | 中 | Resume 时注入「请先验证之前修改的文件状态」的系统消息 |
| Plan Mode 审批阻塞导致 agent 超时 | 低 | 设置 Plan Mode 审批超时（默认 10 分钟），超时后自动暂停并通知 |
| Haiku 摘要 API 调用增加成本 | 低 | Tool Use Summary 和 Summarization 均为异步可选，可在设置中关闭 |

---

*本文档基于 Claude Code 源码分析生成，完整参考见 `/Users/feint/Downloads/claude-code-source-code-main/src/`*
