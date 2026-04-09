# Subagent 能力增强设计

**Goal:** 基于对 Claude Code v2.1.88 AgentTool 体系的结构化分析，系统提升 agentGui 内置 built-in agent 的子代理能力，重点提升代理定义灵活性、专用代理质量、并发后台执行、代理记忆持久化、生命周期治理和代理恢复能力。

**Architecture:** 以现有 `AgentCatalog` / `WorkflowRoleDefinition` / `runSubagentLoop` / `AgentLoopRuntime` 为基础，逐层增补能力，不推翻现有架构，不引入外部运行时依赖。

**Tech Stack:** Swift 6, SwiftUI, SwiftData（持久化会话/代理任务记录），SwiftAnthropic，现有 AgentLoopRuntime / ToolExecutionHookPipeline / ConversationExecutionOrchestrator。**子代理记忆层使用纯文件系统（MEMORY.md + 话题 .md 文件），不使用 SwiftData——与现有主代理记忆架构保持一致。**

**参考来源:** `src/tools/AgentTool/` (runAgent.ts, forkSubagent.ts, resumeAgent.ts, agentMemory.ts, agentMemorySnapshot.ts, loadAgentsDir.ts, built-in/*.ts), `src/services/AgentSummary/agentSummary.ts`, `src/tasks/LocalAgentTask/LocalAgentTask.tsx`, `src/utils/hooks.ts`

---

## 1. 现状基线

### 1.1 当前 agentGui 已具备的能力

1. 通过 `.agent.md` frontmatter 文件定义代理，支持 `tools`、`max-turns`、`output-contract` 字段。
2. `AgentCatalog` 注册代理（explore / worker / verifier / plan），`WorkflowRoleDefinition` 管理每个代理的系统提示、工具权限、轮次预算；S-A1 已完成 `allowedNames` 开放。
3. `runSubagentLoop` 嵌套调用 `runCoreAgentLoop`，共用主代理的工具执行基础设施。
4. `AgentLoopRuntime` 携带会话上下文，子代理轮次通过 `AgentRound.subagentToolCall` 关联父调用记录。
5. 工具执行钩子系统（`ToolExecutionHookPipeline`）已经存在。
6. **完整的主代理记忆系统**已上线：`memory_write` 工具、`MemoryBootstrapHook`（系统提示注入）、`MemoryRecallHook`（中段召回）、`RelevantMemoryRecallService`（侧查询）、`MemoryExtractionHook`（会话结束后台提取），所有记忆存储在 `~/.agentgui/memory/`（全局共享）。

### 1.2 与 Claude Code 的差距

和 Claude Code `AgentTool` 体系对比，agentGui 当前有 **7 个层面的系统性差距**：

| 层面 | Claude Code 已有 | agentGui 当前状态 |
|------|----------------|-----------------|
| 代理类型 | 无限制（用户/插件可新增），内置 6 种专用代理 | 固定 3 种，`allowedNames` 硬编码 |
| 模型选择 | 每个代理独立指定（haiku/inherit/opus）| 全部复用父代理模型 |
| 并发执行 | `run_in_background: true` + `background: true` 异步独立 AbortController | 全部同步阻塞父代理 loop |
| 代理记忆 | user/project/local 三级 MEMORY.md 持久化（按代理类型隔离目录） | 主代理有完整记忆系统；子代理尚无按类型隔离的目录，`memory_write` 工具写入全局目录 |
| 生命周期钩子 | SubagentStart/Stop hooks，前后置上下文注入 | 无 |
| Fork 模式 | 继承父上下文并发分叉，共享 prompt cache | 无，所有子代理从 task 重新开始 |
| 代理恢复 | transcript 持久化 + 元数据，断后可 resume | 无，中断即丢失 |

---

## 2. 设计原则

1. **最小侵入原则：** 每个 Feature 都是对现有架构的叠加，不重写已稳定的组件（`runCoreAgentLoop`、`ToolRegistry`、`AgentLoopRuntime`）。
2. **分层解锁原则：** P0（基础能力）→ P1（并发与记忆）→ P2（fork 与恢复）按序落地，每层独立可测。
3. **可测性优先：** 新增组件均以纯 Swift struct/actor 表达核心逻辑，UI-free，单元测试覆盖关键路径。
4. **向后兼容：** 现有 3 代理的 `.agent.md` 格式继续有效，新增字段渐进引入，旧文件不需修改。

---

## 3. Feature 清单

### Layer A — 代理定义体系开放扩展

当前最大的结构性瓶颈：`allowedNames` 白名单和 `allowedOutputContracts` 白名单把系统锁死在 3 个代理上，无法承载更丰富的子代理专业化设计。

---

#### S-A1 · 开放代理定义体系

**优先级:** P0  
**来源:** `loadAgentsDir.ts` → `BaseAgentDefinition`、`BuiltInAgentDefinition`

**做什么:** 移除 `AgentDefinitionLoader` 中的 `allowedNames` 和 `allowedOutputContracts` 白名单限制，并扩展 `AgentDefinitionDocument` 和 `WorkflowRoleDefinition` 支持新字段，同时保持对现有 3 个代理文件的向后兼容。

**新增 frontmatter 字段（全部可选）：**

```yaml
model-preference: haiku       # haiku | inherit | opus | sonnet（default: inherit）
effort: low | medium | high   # thinking budget（default: medium）
background: false              # 是否总以后台方式运行
omit-main-context: false       # true = 不注入 CLAUDE.md 等主代理上下文（节省 token）
initial-prompt: "..."          # 子代理第一轮 user 消息前额外注入的文本
critical-reminder: "..."       # 每轮 user 消息前重新注入的短提醒（≤200 字）
color: blue                    # UI 标注颜色（optional）
disallowed-tools: [bash_write] # 从代理可用工具中排除的工具
```

**修改文件:** `agentGui/Services/AgentDefinitionLoader.swift`，`agentGui/Models/AgentDefinitionDocument.swift`，`agentGui/Models/WorkflowRoleDefinition.swift`

**验收标准:**
- 新增字段解析后正确反映在 `WorkflowRoleDefinition` 上。
- 名称不在旧白名单中的 `.agent.md` 文件可以正常加载。
- 旧的 explore/worker/verifier 文件不加新字段时行为不变。

**依赖:** 无

---

#### S-A2 · 单次执行代理标记（One-Shot Agent）

**优先级:** P0  
**来源:** `constants.ts` → `ONE_SHOT_BUILTIN_AGENT_TYPES`（`Explore`、`Plan`），`prompt.ts` trailer 优化

**做什么:** 在 `WorkflowRoleDefinition` 新增 `isOneShot: Bool` 字段。标记为 `true` 的代理执行完直接返回报告，不在结果尾部追加 `agentId / usage / SendMessage` 信息（节省约 135 字符 × 执行次数的 token）。对当前 explore 代理默认设置此标记。

**修改文件:** `agentGui/Models/WorkflowRoleDefinition.swift`，`agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`（在 `runSubagentLoop` 返回时根据标记决定是否附加 trailer）

**验收标准:**
- explore 子代理结果不含 `agentId` trailer，但 worker 结果正常附加。
- 单元测试验证 one-shot 和非 one-shot 两种代理的输出格式差异。

**依赖:** S-A1

---

#### S-A3 · 子代理模型选择

**优先级:** P0  
**来源:** `runAgent.ts` → `getAgentModel(agentDefinition.model, toolUseContext.options.mainLoopModel, model, permissionMode)`，`exploreAgent.ts` → `model: 'haiku'`

**做什么:** 在 `runSubagentLoop` 中实现 `model-preference` 解析，按以下优先级选择子代理使用的模型：

```
run_subagent 调用时传入的 override model
  → 代理定义的 model-preference（haiku / inherit / opus / sonnet）
    → 父代理当前使用的模型（inherit 语义）
```

对 explore 代理的 `.agent.md` 文件新增 `model-preference: haiku`，减少探索类调用的 API 成本。

**修改文件:** `agentGui/Models/WorkflowRoleDefinition.swift`（新增 `modelPreference`），`agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`（`runSubagentLoop` 选模型逻辑）

**新增类型:**

```swift
enum SubagentModelPreference: String, Codable {
    case inherit   // 使用父代理的模型
    case haiku     // claude-haiku 系列（快速、低成本，适合探索）
    case sonnet    // claude-sonnet 系列（均衡）
    case opus      // claude-opus 系列（高能力，适合验证/执行）
}
```

**验收标准:**
- explore 子代理使用 haiku 模型，API 请求中 model 字段正确。
- verifier 使用 inherit 继承父代理模型。
- `model-preference: haiku` 的代理可以在测试中被单独以 `override` 覆盖。

**依赖:** S-A1

---

#### S-A4 · 上下文裁剪（omit-main-context）

**优先级:** P1  
**来源:** `loadAgentsDir.ts` → `omitClaudeMd: true`（Explore/Plan 代理），`runAgent.ts` → `shouldOmitClaudeMd` 计算逻辑

**做什么:** 当 `WorkflowRoleDefinition.omitMainContext == true` 时，在构建子代理系统提示时跳过以下注入：CLAUDE.md 层级内容、git status 摘要、实时 workspace 状态描述。这三类内容对只读探索型代理是无效 token，占约 5–15% 的输入 token。

**修改文件:** `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`（构建 `makeEphemeralSystemPrompt` 时判断 `omitMainContext`），`agentGui/Resources/Agents/explore.agent.md`（新增 `omit-main-context: true`）

**验收标准:**
- 开启 `omit-main-context` 的代理系统提示不含 CLAUDE.md 内容，单元测试可验证。
- 关闭时行为与当前完全相同。

**依赖:** S-A1

---

#### S-A5 · CriticalSystemReminder（每轮核心提醒）

**优先级:** P1  
**来源:** `loadAgentsDir.ts` → `criticalSystemReminder_EXPERIMENTAL`，在 `AgentTool.tsx` 的每个 user-turn 前注入

**做什么:** 为 `WorkflowRoleDefinition` 新增 `criticalReminder: String?` 字段。当此字段非空时，在子代理每个 API turn 的 user message 前额外注入一条系统提醒文本片段（`≤200` 字符）。主要用于强制执行"只能探索不能写文件"这类反复被模型忘记的约束。

对 verifier 代理注入：`CRITICAL: This is verification-only. You CANNOT edit, write, or create files IN THE PROJECT. You MUST end with VERDICT: PASS, VERDICT: FAIL, or VERDICT: PARTIAL.`

**修改文件:** `agentGui/Models/WorkflowRoleDefinition.swift`，`agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`（`runSubagentLoop` 中在每轮 user message 前注入）

**验收标准:**
- 包含 `criticalReminder` 的代理每轮 API 调用前注入该文本。
- 注入失败时不影响正常执行（非致命）。

**依赖:** S-A1

---

### Layer B — 专用内置代理扩展

当前 3 个代理能力已基本完备（explore/worker/verifier），但缺少 **Plan 代理**（设计方案专用，只读）和 **General-Purpose 代理**（灵活后备）。

---

#### S-B1 · Plan 内置代理

**优先级:** P1  
**来源:** `built-in/planAgent.ts`

**做什么:** 新增 `plan.agent.md`，定义架构设计专用代理：只读探索代码库、生成分步骤实施方案，绝不修改文件。继承父代理模型（full capability）。

**关键系统提示约束：**
- `=== CRITICAL: READ-ONLY MODE ===` 禁止一切文件写入操作。
- 要求在输出末尾列出 `### Critical Files for Implementation`。
- 提供多个架构视角供主代理选择。

**新增文件:** `agentGui/Resources/Agents/plan.agent.md`

```yaml
---
name: plan
display-name: 架构规划者
description: 只读探索代码库，生成分步骤实施方案。不修改任何文件。
argument-hint: Describe the requirements and architectural constraints to consider.
tools: [read_only_editor, bash_readonly]
max-turns: 50
user-invocable: false
subagent-invocable: true
output-contract: plan_report
model-preference: inherit
omit-main-context: true
---
```

> **与 built-in-agent 设计文档对齐：** `2026-04-01-built-in-agent-claude-code-analysis-design.md` 中的 **F-D1~D5** 定义了 Plan Mode 状态机（`EnterPlanModeTool` / `ExitPlanModeTool` / `PlanArtifact`）。S-B1 plan 子代理与 Plan Mode 的协作关系如下：
> 
> - 主代理进入 plan mode 后，可选择将只读探索工作委托给 plan 子代理（`run_subagent agent_name: plan task: "..."`），主代理自居 plan mode 中等待 plan_report 而无需亲自探索。
> - plan 子代理返回的 `plan_report`（Markdown 正文）可直接作为 `ExitPlanModeTool` 的 `planText` 入参，主代理随后调用 ExitPlanModeTool 提交审批。
> - 主代理也可不借助子代理，自行在 plan mode 内完成探索生成方案，两种路径均建立在同一 `PlanArtifact` 持久化模型上。
> - 两者不存在写入冲突：plan 子代理不直接操作 `PlanArtifact`，它仅返回文本；`PlanArtifact` 登记由 ExitPlanModeTool 处理。

**验收标准:**
- plan 代理无法调用文件写入工具（工具 schema 中不出现 `bash_write`、`file_write`）。
- 主代理接收 `plan_report` 后在执行时间线中显示方案摘要。

**依赖:** S-A1，S-A3，S-A4

---

#### S-B2 · General-Purpose 后备代理

**优先级:** P1  
**来源:** `built-in/generalPurposeAgent.ts` → 默认候选代理，当 `subagent_type` 未指定时使用

**做什么:** 新增 `general.agent.md`，作为 `run_subagent` 不指定 `agent_name` 时的后备代理（当前系统会返回错误）。继承父代理的全部工具权限和模型。

**修改文件:** `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`（当 `agentName` 为 nil 或 empty 时 fallback 到 general）；`agentGui/Resources/Agents/general.agent.md`

**验收标准:**
- `run_subagent` 调用时不提供 `agent_name` 会使用 general 代理而非返回错误。
- general 代理工具与父代理相同。

**依赖:** S-A1

---

### Layer C — 子代理后台并发执行

当前所有子代理运行时**阻塞父代理 loop**，长任务（如 verifier 跑完整测试套件）会让主 session 完全挂起，用户无法继续交互。

---

#### S-C1 · SubagentTaskRecord SwiftData 模型

**优先级:** P1  
**来源:** `LocalAgentTask.tsx` → `LocalAgentTaskState`

**做什么:** 新增 `SubagentTaskRecord` SwiftData `@Model`，作为后台子代理的持久化任务记录。

```swift
@Model final class SubagentTaskRecord {
    var id: UUID
    var sessionID: UUID
    var parentToolCallID: UUID          // 关联的 ToolCall 记录
    var agentName: String               // e.g. "verifier"
    var description: String             // 5-10 字任务描述
    var task: String                    // 原始 task 入参
    var status: SubagentTaskStatus      // pending / running / completed / failed / cancelled
    var modelID: String?
    var startedAt: Date
    var completedAt: Date?
    var result: String?                 // 最终输出文本
    var errorMessage: String?
    var toolUseCount: Int               // 累计工具调用次数
    var tokenCount: Int                 // 累计 token 消耗
    var lastActivity: String?           // 最近一条工具活动描述
    var progressSummary: String?        // 30s 摘要（S-C4）
    var transcriptPath: String?         // JSONL transcript 文件路径（S-F1）

    enum SubagentTaskStatus: String, Codable {
        case pending, running, completed, failed, cancelled
    }
}
```

**新增文件:** `agentGui/Models/SubagentTaskRecord.swift`

**依赖:** 无

---

#### S-C2 · 子代理异步后台执行器

**优先级:** P1  
**来源:** `AgentTool.tsx` 中 `isAsync: true` 路径，`runAsyncAgentLifecycle`，独立 `AbortController`

**做什么:** 新增 `SubagentBackgroundExecutor`，允许 `runSubagentLoop` 以非阻塞方式启动后台子代理 Task。

关键设计：
1. 每个后台子代理获得独立的 `Task<Void, Never>`，有独立 `AbortController`。
2. 父代理立即收到结果占位符：`{"status":"async_launched","agent_id":"xxx","description":"...","poll_after":30}`。
3. 父代理可选择不等待结果，或通过 `poll_subagent` 工具查询状态。
4. 后台子代理完成时，结果写入 `SubagentTaskRecord`，并在父 session 的 conversation 中注入完成通知消息。

```swift
actor SubagentBackgroundExecutor {
    func launch(
        agentName: String,
        task: String,
        toolCallRecord: ToolCall,
        runtime: AgentLoopRuntime
    ) async throws -> SubagentLaunchResult

    func cancel(agentID: UUID) async

    func status(agentID: UUID) -> SubagentTaskStatus?
}

struct SubagentLaunchResult {
    let agentID: UUID
    let taskRecord: SubagentTaskRecord
    let isAsync: Bool   // true = 后台启动，false = 同步完成
}
```

**新增文件:** `agentGui/Services/SubagentGovernance/SubagentBackgroundExecutor.swift`

**接入点:** `AgentLoopToolExecutionCoordinator` 处理 `run_subagent` 时，根据代理定义的 `background: true` 或调用参数 `run_in_background: true` 分支到 `SubagentBackgroundExecutor.launch`。

**验收标准:**
- 后台子代理启动后父代理立即继续执行下一步，不阻塞。
- 子代理完成后，父 session 消息列表中出现完成通知。
- 可以通过 `poll_subagent` 工具查询后台代理当前状态。

**依赖:** S-C1，S-A1

---

#### S-C3 · 子代理进度追踪

**优先级:** P1  
**来源:** `LocalAgentTask.tsx` → `ProgressTracker`、`AgentProgress`、`updateProgressFromMessage`

**做什么:** 在 `AgentLoopRuntime` 中为子代理执行阶段维护实时进度追踪，每个 API 轮次更新以下指标：

```swift
struct SubagentProgress {
    var toolUseCount: Int
    var tokenCount: Int                      // latestInputTokens + cumulativeOutputTokens
    var recentActivities: [ToolActivity]     // 最近 5 个工具调用描述
    var lastActivity: ToolActivity?          // 最新工具活动
    var progressSummary: String?             // 外部摘要（由 S-C4 填充）
}

struct ToolActivity {
    var toolName: String
    var activityDescription: String?   // 工具自描述，e.g. "Reading Services/ClaudeService.swift"
    var isRead: Bool
    var isSearch: Bool
}
```

进度更新写入 `SubagentTaskRecord` 的 `toolUseCount`、`tokenCount`、`lastActivity` 字段。

**修改文件:** `agentGui/Services/AgentLoopRoundExecutor.swift`（在每轮 API 响应消费后更新 progress），`agentGui/Models/SubagentTaskRecord.swift`（添加进度字段）

**验收标准:**
- 子代理执行中，UI 可读取当前 `toolUseCount` 和 `lastActivity`。
- 进度更新不阻塞子代理 loop（非同步 await）。

**依赖:** S-C1

---

#### S-C4 · 子代理进度摘要服务（重设计）

**优先级:** P1  
**来源:** `services/AgentSummary/agentSummary.ts`（已在上一个设计文档中与 F-B6 对应，本次重设计以对接 S-C2 后台架构）

> **与 built-in-agent 设计文档对齐：** `2026-04-01-built-in-agent-claude-code-analysis-design.md` 中的 **F-B6** 定义了同一组件，但放置在 `ContextGovernance/`。**将 S-C4 作为该组件的唯一规范实现，**文件路径为 `Services/SubagentGovernance/SubagentProgressSummarizer.swift`（不是 ContextGovernance/），F-B6 改为交叉引用。优先级以本条目 P1 为准。

**做什么:** 当后台子代理运行超过 30 秒时，以 30 秒间隔 fork 一个摘要请求，生成 3-5 词现在进行时标签（"Reading ClaudeService.swift"），写入 `SubagentTaskRecord.progressSummary`。

关键实现细节（直接来自 Claude Code）：

1. 使用与子代理相同的 `CacheSafeParams`（system + tools + model），但 `canUseTool` 始终返回 `deny`，确保摘要请求命中父代理 prompt cache，不增加 cache miss 成本。
2. 每 30s 从 transcript 读取当前消息状态，过滤不完整 tool call。
3. 避免重复：`buildSummaryPrompt` 传入 `previousSummary`，要求生成不同的描述。

**提示词（完整复用 Claude Code 设计）：**

> "Describe your most recent action in 3-5 words using present tense (-ing). Name the file or function, not the branch.  
> Good: 'Reading runAgent.ts', 'Fixing null check in validate.ts', 'Running auth module tests'  
> Bad (past tense): 'Analyzed the branch diff'  
> Bad (too vague): 'Investigating the issue'"

**新增文件:** `agentGui/Services/SubagentGovernance/SubagentProgressSummarizer.swift`

**接入点:** `SubagentBackgroundExecutor.launch` 启动后，同时启动摘要计时器。

**验收标准:**
- 运行 30s 以上的后台子代理在 UI 任务条中出现进度短语。
- 摘要每 30 秒更新，不与上一条重复。
- 摘要 API 调用失败时沉默降级，不影响主 loop。

**依赖:** S-C1，S-C2，F-C1（批次完成事件、cache-safe 请求模式）

---

#### S-C5 · PollSubagentTool（后台代理查询工具）

**优先级:** P1  
**来源:** `AgentTool.tsx` → `outputFile` + 父代理可读取任务输出文件

**做什么:** 新增内置工具 `poll_subagent`，主代理可用于主动查询已启动的后台子代理的当前状态。

**工具 schema：**

```swift
struct PollSubagentInput: Codable {
    var agentID: String   // SubagentLaunchResult.agentID
}

struct PollSubagentOutput: Codable {
    var status: String        // pending / running / completed / failed / cancelled
    var progressSummary: String?
    var toolUseCount: Int
    var tokenCount: Int
    var result: String?       // 状态为 completed 时的最终输出
    var errorMessage: String? // 状态为 failed 时的错误信息
}
```

**新增文件:** `agentGui/Services/BuiltInTools/PollSubagentTool.swift`

**依赖:** S-C1，S-C2

---

### Layer D — 代理记忆系统

Claude Code 的 agent memory 让专用代理在多次调用中积累项目知识（哪些文件不该读、已知禁区、常见模式等），从而随着使用次数增加而变得更聪明。

> **现状修订（2026-04-03）：** agentGui 已经拥有完整的**主代理**记忆系统，包括 `memory_write` 工具、`MemoryBootstrapHook`、`MemoryRecallHook`、`RelevantMemoryRecallService` 以及基于文件系统的 MEMORY.md + 话题文件架构（`~/.agentgui/memory/`）。Layer D 的目标是**将这套已验证的主代理记忆基础设施扩展到子代理维度**，而非另起炉灶。核心差异：主代理使用全局目录；子代理需要按代理类型隔离的独立目录，且记忆随子代理名称跨会话积累。

---

#### D-0 · 架构对齐说明

**现有 agentGui 记忆基础设施（不重建，直接复用）：**

| 组件 | 路径 | 职责 |
|------|------|------|
| `memory_write` 工具 | `ClaudeService+ToolDispatch.swift` | 写入话题 .md 文件 + 重建 MEMORY.md 索引 |
| `AgentLoopMemoryBootstrapComposer` | `Services/Memory/` | 读取 MEMORY.md → 格式化系统提示注入段 |
| `MemoryBootstrapHook` | `Services/AgentLoopHooks/` | 在 `.prepareRun` 阶段将记忆追加到系统提示 |
| `MemoryIndexFileSystem` | `Services/Memory/` | 200行/25KB 截断 + MEMORY.md 重建 |
| `ConfigDirectoryManager.memoryDir` | `Utilities/` | `~/.agentgui/memory/`（全局主代理目录） |

**Claude Code 对应实现（`agentMemory.ts` + `loadAgentsDir.ts`）：**
- 每个代理类型拥有独立目录，scope 决定位置：
  - `user` → `~/.claude/agent-memory/<agentType>/`
  - `project` → `<cwd>/.claude/agent-memory/<agentType>/`
  - `local` → `<cwd>/.claude/agent-memory-local/<agentType>/`
- 代理定义的 `memory: user|project|local` 字段控制记忆 scope。
- 启用记忆时，Write/Edit/Read 工具**自动追加**到代理工具集（不依赖工具名白名单）。
- 记忆通过 `loadAgentMemoryPrompt()` 注入到 `getSystemPrompt` 返回值（系统提示尾部）。
- **没有独立的 `agent_memory_read` 工具**——代理使用标准文件读取工具直接读取 `.md` 文件。
- **没有 SwiftData 模型**——纯文件系统，MEMORY.md 作索引，独立 topic `.md` 文件存实体。

---

#### S-D1 · `AgentMemoryScope` 及目录路径解析

**优先级:** P2  
**来源:** `agentMemory.ts` → `AgentMemoryScope`、`getAgentMemoryDir()`、`sanitizeAgentTypeForPath()`

**做什么:** 新增 `AgentMemoryScope` 枚举（三值，对齐 Claude Code；与现有 6 值 `MemoryScope` 并立，各司其职），以及 `AgentMemoryPathResolver` 路径解析器。

> **注意：** 现有的 `MemoryScope`（user/workspace/project/session/thread/workflowRun）是主代理记忆系统的领域模型，描述记忆条目在哪个会话上下文中产生。`AgentMemoryScope` 是子代理记忆的存储策略，描述记忆文件持久化到哪个目录层级。两者不合并，避免概念污染。

```swift
/// 子代理记忆的存储策略 scope（对齐 Claude Code AgentMemoryScope）。
/// 不使用现有 MemoryScope——后者描述记忆产生的会话上下文，语义不同。
enum AgentMemoryScope: String, Codable, Sendable {
    /// 跨工作区持久化：~/.agentgui/agent-memory/<agentType>/
    case user
    /// 项目级共享（可纳入 git）：<workspace>/.agentgui/agent-memory/<agentType>/
    case project
    /// 本机专用（不纳入 git）：<workspace>/.agentgui/agent-memory-local/<agentType>/
    case local
}

/// 给定代理类型名和 scope，返回记忆目录 URL。
/// 代理类型名经过路径安全处理（`:` → `-`，禁止 `..`）。
struct AgentMemoryPathResolver: Sendable {
    let workspaceRoot: URL?   // nil = 当前工作目录

    /// 返回代理记忆目录 URL（不保证已存在，调用方负责创建）。
    func memoryDir(agentType: String, scope: AgentMemoryScope) -> URL

    /// 返回 MEMORY.md 索引文件 URL。
    func memoryIndexURL(agentType: String, scope: AgentMemoryScope) -> URL

    /// 对代理类型名进行路径安全处理（对齐 sanitizeAgentTypeForPath）。
    static func sanitize(_ agentType: String) -> String
}
```

**安全约束：** 代理类型名中含 `/`、`..` 的立即拒绝（路径遍历防护，对齐 Claude Code `sanitizePath`）。

**新增文件:** `agentGui/Models/AgentMemoryScope.swift`，`agentGui/Services/SubagentGovernance/AgentMemoryPathResolver.swift`

**依赖:** 无

---

#### S-D2 · `AgentDefinitionDocument` 和 `WorkflowRoleDefinition` 扩展

**优先级:** P2  
**来源:** `loadAgentsDir.ts` → `BaseAgentDefinition.memory?: AgentMemoryScope`，frontmatter `memory: user|project|local`

**做什么:** 在代理定义层增加记忆 scope 字段，让 `.agent.md` 文件可声明记忆策略。

**修改文件:**

1. `agentGui/Services/AgentDefinitionLoader.swift`：
   - 将 `"memory"` 加入 `optionalFields` 白名单。
   - 解析 `memory: user|project|local` → `AgentMemoryScope`（枚举 rawValue 解析，非法值忽略并警告）。

2. `agentGui/Models/AgentDefinitionDocument.swift`：新增字段：
   ```swift
   let memoryScope: AgentMemoryScope?   // frontmatter: memory (default: nil)
   ```

3. `agentGui/Models/WorkflowRoleDefinition.swift`：新增字段：
   ```swift
   let memoryScope: AgentMemoryScope?   // nil = 不启用持久记忆
   ```

4. `agentGui/Resources/Agents/explore.agent.md`：新增 `memory: project`

5. `agentGui/Services/AgentRuntimeDefinition.swift`（或 equivalent 转换层）：从 `AgentDefinitionDocument.memoryScope` 映射到 `WorkflowRoleDefinition.memoryScope`。

**工具自动注入（对齐 Claude Code `isAutoMemoryEnabled` 分支）：**
当 `memoryScope != nil` 时，`runSubagentLoop` 在构建子代理工具集时**自动追加** `memory_write` 工具（如果工具集中尚无此工具）。这样不需要在每个代理的 `tools` 字段手动声明记忆工具。

**验收标准:**
- `explore.agent.md` 新增 `memory: project` 后，解析出 `memoryScope == .project`。
- `memory` 字段缺失的现有代理文件 `memoryScope == nil`，行为不变。
- `memory: invalid_value` 被忽略（不抛错），`memoryScope == nil`。

**依赖:** S-D1

---

#### S-D3 · 子代理记忆引导注入

**优先级:** P2  
**来源:** `loadAgentsDir.ts` → `getSystemPrompt()` 闭包中调用 `loadAgentMemoryPrompt(agentType, memory)`；`agentMemory.ts` → `loadAgentMemoryPrompt()` → `buildMemoryPrompt()`

**做什么:** 在 `runSubagentLoop` 启动子代理时，若 `WorkflowRoleDefinition.memoryScope != nil`，复用现有的 `AgentLoopMemoryBootstrapComposer` 向子代理系统提示追加记忆节。

**策略：** 不新建 `AgentMemoryInjector`——直接在 `runSubagentLoop` 内用已有 `AgentLoopMemoryBootstrapComposer` 指向**子代理专属目录**（由 `AgentMemoryPathResolver` 计算）：

```swift
// ClaudeService+Subagent.swift — runSubagentLoop 内
if let scope = definition.memoryScope {
    let resolver = AgentMemoryPathResolver(workspaceRoot: runtime.workspaceRoot)
    let agentMemDir = resolver.memoryDir(agentType: definition.name, scope: scope)
    let composer = AgentLoopMemoryBootstrapComposer(memoryDir: agentMemDir)
    let composition = composer.compose()
    if let section = composition.systemPromptSection {
        // 追加到子代理系统提示（在 criticalReminder 之前）
        systemPrompt += "\n\n" + section
        // 确保目录存在（fire-and-forget）
        try? FileManager.default.createDirectory(at: agentMemDir,
                                                  withIntermediateDirectories: true)
    }
}
```

**注入格式（对齐现有 `AgentLoopMemoryBootstrapComposer.buildSection`）：**
```markdown
## Your Memory

The following are your persistent memories from past sessions.

<memory>
[MEMORY.md content — max 200 lines / 25 KB]
</memory>

This directory already exists — write to it directly with the memory_write tool.
```

**验收标准:**
- explore 代理系统提示中出现 `## Your Memory` 块（当 `~/.agentgui/agent-memory/explore/MEMORY.md` 非空时）。
- 记忆为空时不注入占位段（对齐现有 `AgentLoopMemoryBootstrapComposer` 行为）。
- 主代理全局记忆不受影响（路径不同）。

**依赖:** S-D1，S-D2

---

#### S-D4 · 子代理 `memory_write` 目录作用域隔离

**优先级:** P2  
**来源:** `loadAgentsDir.ts` → 工具集自动追加 Write/Edit/Read；Claude Code 中代理知道自己的 `memoryDir` 路径并直接写

**做什么:** 现有 `memory_write` 工具将记忆写入全局 `~/.agentgui/memory/`，但子代理需要写入代理类型专属目录。实现目录隔离的最小修改方案：

1. 在 `ClaudeService+ToolDispatch.swift` 的 `executeFileMemoryWrite` 中，将 `memoryDir` 从注入上下文（`AgentLoopRuntime` 或执行器上下文）读取，而不是始终使用 `ConfigDirectoryManager.shared.memoryDir`。
2. 在 `runSubagentLoop` 中，若 `definition.memoryScope != nil`，将子代理专属记忆目录注入到执行器上下文中，`memory_write` 工具执行时读取该目录。
3. 若执行器上下文未携带子代理记忆目录（即主代理或无 memoryScope 的子代理），fallback 到全局 `ConfigDirectoryManager.shared.memoryDir`，保留向后兼容性。

**敏感信息防护（对齐 Claude Code `secretScanner` 思路）：** `executeFileMemoryWrite` 在写入前检查 `content` 是否包含明显凭证模式（正则：`(sk-ant-|Bearer |api[_-]?key\s*[:=]|password\s*[:=]|token\s*[:=])` 等），匹配时拒绝写入并返回错误提示。

**无需新增工具文件**——仅修改现有 `ClaudeService+ToolDispatch.swift` 和子代理启动逻辑。

**验收标准:**
- explore 子代理调用 `memory_write` 时，文件写入 `~/.agentgui/agent-memory/explore/`。
- 主代理调用 `memory_write` 仍写入 `~/.agentgui/memory/`。
- 含 `sk-ant-` 前缀的内容被拒绝写入。

**依赖:** S-D1，S-D2，S-D3

---

#### S-D5 · 代理记忆快照系统（Agent Memory Snapshot）

**优先级:** P2  
**来源:** `agentMemorySnapshot.ts` → `checkAgentMemorySnapshot()`、`initializeFromSnapshot()`、`replaceFromSnapshot()`；`loadAgentsDir.ts` → `initializeAgentMemorySnapshots()`

**做什么:** 新增快照机制，允许项目仓库为 `user` scope 代理提供**启动记忆种子**（starter pack），让新用户在首次运行时就能受益于团队积累的代理记忆。

**快照目录结构：**
```
<workspace>/
  .agentgui/
    agent-memory-snapshots/
      <agentType>/
        snapshot.json          # { "updatedAt": "2026-04-01T..." }
        <topic>.md             # 种子记忆文件（可纳入 git）
```

**工作流程：**

1. **启动时检查**（`AgentCatalog.shared` 初始化或子代理首次激活时）：  
   - 读取 `<workspace>/.agentgui/agent-memory-snapshots/<agentType>/snapshot.json`。  
   - 若本地目录 `~/.agentgui/agent-memory/<agentType>/` 尚无 `.md` 文件 → `action: initialize`：将快照 `.md` 文件复制到本地目录，写入 `.snapshot-synced.json`。  
   - 若快照时间戳比 `.snapshot-synced.json` 更新 → `action: prompt-update`：将 `pendingSnapshotUpdate` 标记写入 `WorkflowRoleDefinition`（在 UI 或下次激活时提示用户是否更新）。  
   - 若版本一致 → `action: none`。

2. **仅对 `user` scope 代理执行快照检查**（`project`/`local` scope 已在工作区本地，无需快照初始化）。

```swift
struct AgentMemorySnapshotCoordinator: Sendable {
    let workspaceRoot: URL
    let resolver: AgentMemoryPathResolver

    enum SnapshotAction {
        case none
        case initialize(snapshotTimestamp: String)
        case promptUpdate(snapshotTimestamp: String)
    }

    func checkSnapshot(agentType: String) async -> SnapshotAction
    func initializeFromSnapshot(agentType: String, snapshotTimestamp: String) async throws
    func replaceFromSnapshot(agentType: String, snapshotTimestamp: String) async throws
}
```

**新增文件:** `agentGui/Services/SubagentGovernance/AgentMemorySnapshotCoordinator.swift`

**验收标准:**
- 项目包含 `explore` 快照文件且本地无记忆时，首次启动后 `~/.agentgui/agent-memory/explore/` 中出现种子文件。
- 快照更新后本地已有记忆时，不自动覆盖，仅记录 `pendingSnapshotUpdate` 标记。
- 快照目录不存在时静默跳过。

**依赖:** S-D1，S-D2

---

### Layer E — 代理生命周期钩子

子代理启动和停止时的钩子点缺失，导致无法进行子代理级别的上下文注入、审计、前置条件检查。

---

#### S-E1 · SubagentLifecycleHook 协议

**优先级:** P1  
**来源:** `utils/hooks.ts` → `executeSubagentStartHooks`、`SubagentStartHookInput`、`SubagentStopHookInput`

**做什么:** 新增 `SubagentLifecycleHook` 协议，允许第三方代码在子代理启动前/停止后注入行为：

```swift
protocol SubagentLifecycleHook: Sendable {
    var hookID: String { get }

    func onSubagentStart(
        agentType: String,
        agentID: UUID,
        task: String,
        context: SubagentHookContext
    ) async -> SubagentStartDecision

    func onSubagentStop(
        agentType: String,
        agentID: UUID,
        result: SubagentResult,
        context: SubagentHookContext
    ) async -> Void
}

enum SubagentStartDecision {
    case allow
    case block(reason: String)
    case prependContext(String)    // 在第一轮 user message 前注入附加上下文
}
```

**新增文件:** `agentGui/Services/SubagentGovernance/SubagentLifecycleHook.swift`

**接入点:** `ClaudeService+Subagent.swift` → `runSubagentLoop` 入口前执行 `onSubagentStart`，退出后执行 `onSubagentStop`。

**验收标准:**
- `block()` 决策时子代理不执行，父代理收到明确错误消息。
- `prependContext()` 注入的文本出现在子代理第一轮 API 调用的 user message 中。

**依赖:** 无

---

#### S-E2 · 内置 SubagentStart 钩子集

**优先级:** P1  
**来源:** `utils/hooks.ts` → `executeSubagentStartHooks`（允许用户注入额外上下文）

**做什么:** 内置两个 `SubagentLifecycleHook` 实现：

1. **MemoryInjectHook**：在 `onSubagentStart` 时检查代理 `memoryScope`，加载记忆并作为 `prependContext` 注入。与 S-D3 是互补路径：S-D3 在构建系统提示时静态注入（适合 bootstrap），MemoryInjectHook 在每次子代理激活时动态注入（适合需要最新记忆的场景）。两者均可独立使用，不互斥。  
2. **SubagentAuditHook**：在 `onSubagentStart` / `onSubagentStop` 时向 `ExecutionProjectionStore` 写入审计记录（代理名称、任务描述、开始/结束时间、tool count、token 消耗）。

**新增文件:** `agentGui/Services/SubagentGovernance/Hooks/MemoryInjectHook.swift`，`agentGui/Services/SubagentGovernance/Hooks/SubagentAuditHook.swift`

**依赖:** S-E1，S-D3

---

### Layer F — Fork 子代理（并行上下文分叉）

这是 Claude Code 中提升并行效率最有价值的设计：主代理在发出多个只读任务时，可以 fork 自身来共享 prompt cache，多个 fork 子代理并发执行，总耗时等于最慢那个。

---

#### S-F1 · ForkSubagentDefinition

**优先级:** P2  
**来源:** `forkSubagent.ts` → `FORK_AGENT`、`isForkSubagentEnabled()`

**做什么:** 新增 `ForkSubagentDefinition`，表示继承父上下文的特殊代理类型：

```swift
struct ForkSubagentDefinition {
    static let agentType = "fork"

    // Fork 代理特性：
    // - tools: 继承父代理完整工具集（useExactTools = true）
    // - permissionMode: bubble（权限提示冒泡到父代理）
    // - 无独立 system prompt：使用父代理的已渲染 system prompt（byte-identical，命中 cache）
    // - 禁止再 fork（防止递归）
}
```

**新增文件:** `agentGui/Services/SubagentGovernance/ForkSubagentDefinition.swift`

**依赖:** S-A1，S-C2

---

#### S-F2 · ForkMessageBuilder

**优先级:** P2  
**来源:** `forkSubagent.ts` → `buildForkedMessages()`，prompt cache 共享策略

**做什么:** 实现 fork 模式下的消息构建逻辑，确保所有 fork 子代理产生 **byte-identical 的 API request prefix**，最大化 prompt cache 命中率。

关键策略：
1. 所有 fork 子代理共享父代理 **完整对话历史 + 完整 assistant 消息**（含所有 `tool_use` blocks）。
2. 每个 fork 子代理的 user message = 所有 `tool_use` 的占位 `tool_result`（统一使用固定占位文本 `"Fork started — processing in background"`）+ 各自的 directive 文本块。
3. 占位文本一致保证所有 fork 命中同一缓存，每个子代理只有末尾的 directive 不同。

```swift
struct ForkMessageBuilder {
    /// 为单个 fork 子代理构建消息，生成 [...history, assistant(all_tool_uses), user(placeholders..., directive)]
    func buildForkedMessages(
        directive: String,
        parentHistory: [APIMessage],
        assistantMessage: APIAssistantMessage
    ) -> [APIMessage]

    /// Guard：检测消息历史中是否已含 fork boilerplate，阻止嵌套 fork
    func isInForkChild(messages: [APIMessage]) -> Bool
}
```

**Fork 子代理强制提示词注入（`buildChildMessage`）：**

> "STOP. READ THIS FIRST. You are a forked worker process. You are NOT the main agent. RULES: Do NOT spawn sub-agents; execute directly. Do NOT converse, ask questions, or suggest next steps. If you modify files, commit changes before reporting. Your response MUST begin with 'Scope:'. No preamble."

**新增文件:** `agentGui/Services/SubagentGovernance/ForkMessageBuilder.swift`

**依赖:** S-F1

---

#### S-F3 · Fork 并发调度器

**优先级:** P2  
**来源:** `AgentTool.tsx` → 主代理在一轮内发出多个 Agent tool calls，各自以 `isAsync: true` 并发执行

**做什么:** 当主代理在同一轮内发出多个 `run_subagent` tool call 且全部为 fork 模式时，`ToolConcurrencyBatchPlanner`（F-C1）将它们收入同一并发批次，同时启动。

由于所有 fork 子代理共享相同的 cache-safe prefix，这批并发 API 请求将命中同一 prompt cache，不会叠加 cache miss 成本。

**修改文件:** `agentGui/Services/ToolGovernance/ToolConcurrencyBatchPlanner.swift`（**此文件由 `2026-04-01-built-in-agent-claude-code-analysis-design.md` F-C1 定义**）（在判断 batch 时，fork 类型子代理标记为 `isConcurrencySafe = true`）

**验收标准:**
- 同一轮发出 3 个 fork 子代理，它们并发执行，总耗时约等于最慢的单个子代理耗时。
- prompt cache hit 率在日志中可验证。

**依赖:** S-F1，S-F2，F-C1（已有）

---

### Layer G — 子代理恢复系统

当子代理在长任务中被中断（app 崩溃、用户强制关闭、网络断开），以往的执行进度完全丢失。恢复系统允许子代理从中断点续行。

---

#### S-G1 · SubagentTranscriptStore

**优先级:** P2  
**来源:** `utils/sessionStorage.ts` → `recordSidechainTranscript`、`getAgentTranscript`，每个 subagent 有独立的 `.jsonlines` 文件

**做什么:** 在子代理执行过程中，将每一条 API 消息追加写入磁盘上的 transcript 文件（支持流式写入，不需要全量结束后才写），位置为：

```
~/Library/Application Support/agentGui/subagent-transcripts/<session_id>/<agent_id>.jsonlines
```

格式：每行一条 JSON 编码的 `Message`，可以高效 append。

```swift
actor SubagentTranscriptStore {
    func recordMessage(_ message: Message, agentID: UUID) async throws
    func loadTranscript(agentID: UUID) async throws -> SubagentTranscript?
    func deleteTranscript(agentID: UUID) async throws
}

struct SubagentTranscript {
    let agentID: UUID
    let messages: [Message]
    let contentReplacements: [ContentReplacement]  // payload store 替换记录
}
```

**新增文件:** `agentGui/Services/SubagentGovernance/SubagentTranscriptStore.swift`

**接入点:** `runSubagentLoop` 中每次收到 API 响应后调用 `recordMessage`。

**验收标准:**
- 运行中的子代理即使未完成，transcript 文件已部分写入。
- transcript 可被读取、反序列化后还原消息列表。

**依赖:** S-C1

---

#### S-G2 · SubagentMetadataStore

**优先级:** P2  
**来源:** `utils/sessionStorage.ts` → `writeAgentMetadata`、`readAgentMetadata`（包含 agentType、description、worktreePath）

**做什么:** 在子代理启动时写入元数据 JSON 文件，内容包含恢复所需的关键信息：

```swift
struct SubagentMetadata: Codable {
    var agentID: UUID
    var agentType: String             // 代理类型名称，用于恢复时选择 definition
    var description: String           // 原始任务短描述
    var task: String                  // 原始 task 入参
    var modelID: String?
    var worktreePath: String?         // worktree 隔离路径（S-H2）
    var startedAt: Date
    var parentSessionID: UUID
    var parentToolCallID: UUID
}
```

**新增文件:** `agentGui/Services/SubagentGovernance/SubagentMetadataStore.swift`

**依赖:** S-C1

---

#### S-G3 · SubagentResumeCoordinator

**优先级:** P2  
**来源:** `resumeAgent.ts` → `resumeAgentBackground()`

**做什么:** 从 transcript + metadata 重建并续行中断的子代理。

恢复流程：

1. 从 `SubagentMetadataStore` 加载元数据（agentType、description、worktreePath）。
2. 从 `SubagentTranscriptStore` 加载消息历史，过滤三类脏消息：`filterUnresolvedToolUses` + `filterOrphanedThinkingOnlyMessages` + `filterWhitespaceOnlyAssistantMessages`。
3. 重建 `ContentReplacementState`（payload store 替换映射）。
4. 校验 worktreePath 是否还存在（若不存在 fallback 到主 workspace）。
5. 以恢复的消息历史 + 追加的续行 prompt 重新启动 `runSubagentLoop`。

```swift
struct SubagentResumeCoordinator {
    func canResume(agentID: UUID) async -> Bool
    func resume(
        agentID: UUID,
        additionalPrompt: String,
        runtime: AgentLoopRuntime
    ) async throws -> SubagentResumeHandle
}
```

**新增文件:** `agentGui/Services/SubagentGovernance/SubagentResumeCoordinator.swift`

**接入点:** `ConversationExecutionRuntimeCoordinator` 在恢复 session 时，检测有无 `status == .running` 的 `SubagentTaskRecord`，提供用户续行选项。

**验收标准:**
- 中断的子代理可从上次进度续行，不从头重新执行。
- 恢复时消息历史中无悬空的 `tool_use` 块（invariant 检查通过）。
- worktree 不存在时降级到主目录，不崩溃。

**依赖:** S-G1，S-G2，S-C2

---

### Layer H — Worktree 隔离

对于涉及文件修改的 worker 子代理，在独立 git worktree 中运行可以防止实验性修改污染主工作区。

---

#### S-H1 · WorktreeManager

**优先级:** P2  
**来源:** `utils/worktree.ts` → `createAgentWorktree`、`removeAgentWorktree`、`hasWorktreeChanges`

**做什么:** 封装 git worktree 的创建、轮询和清理操作：

```swift
actor WorktreeManager {
    /// 在 <workspace>/.agentgui/worktrees/<slug>/ 创建独立分支 worktree
    func create(slug: String, basePath: URL) async throws -> URL

    /// 检测 worktree 是否有未提交的改动
    func hasUncommittedChanges(at path: URL) async throws -> Bool

    /// 合并 worktree 改动到主分支（或产生 diff 供用户决策）
    func mergeChanges(from worktreePath: URL, to mainPath: URL) async throws -> MergeResult

    /// 删除 worktree 目录并注销 git worktree 记录
    func remove(at path: URL) async throws
}
```

**安全约束：** worktree slug 必须满足 `/^[a-zA-Z0-9._-]+$/`，禁止 `..` 或路径遍历。

**新增文件:** `agentGui/Services/SubagentGovernance/WorktreeManager.swift`

**依赖:** 无（需要 git 命令行，调用前检查可用性）

---

#### S-H2 · WorktreeIsolatedSubagent

**优先级:** P2  
**来源:** `AgentTool.tsx` → `isolation: 'worktree'` 路径，`runWithCwdOverride` 包裹 agent

**做什么:** 在 `WorkflowRoleDefinition` 中新增 `isolationMode: SubagentIsolationMode?`：

```swift
enum SubagentIsolationMode: String, Codable {
    case worktree   // 在独立 git worktree 中执行
}
```

当 `isolationMode == .worktree` 时，`runSubagentLoop` 在执行前：
1. 调用 `WorktreeManager.create(slug: "\(agentType)-\(agentID)")` 创建 worktree。
2. 将 `AgentLoopRuntime` 的工作目录设置为 worktree 路径。
3. 执行完后检测是否有未提交改动，在父代理结果中报告 worktree branch 名称。
4. worktree 路径写入 `SubagentMetadata`，供恢复时使用（S-G3）。

**修改文件:** `agentGui/Models/WorkflowRoleDefinition.swift`，`agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`

**验收标准:**
- `isolation: worktree` 的子代理修改的文件不影响主 workspace。
- 子代理完成后，父代理结果包含 worktree branch 信息。
- 恢复时 worktree 仍然存在则使用原路径，否则 fallback。

**依赖:** S-H1，S-G2

---

### Layer I — UI 展示增强

---

#### S-I1 · SubagentProgressPanel

**优先级:** P1  
**来源:** `tasks/LocalAgentTask` → coordinator 模式下的 task panel

**做什么:** 在 session 详情视图中新增"子代理"面板，显示当前 session 所有活跃和已完成子代理的状态：

- **运行中：** 代理名称 + 颜色标记 + 进度短语（S-C4）+ toolUseCount + elapsed。
- **已完成：** 代理名称 + 执行时间 + token 消耗 + 最终 verdict（PASS/FAIL/PARTIAL，如是 verifier）。
- **可续行：** S-G3 检测到可恢复的中断子代理时，显示"续行"按钮。

**新增文件:** `agentGui/Views/SubagentProgressPanel.swift`

**接入点:** `SessionDetailView` 中当 session 有 `SubagentTaskRecord` 时显示此面板。

**验收标准:**
- 后台子代理运行时面板动态更新（不阻塞主 session 交互）。
- 单击完成的子代理可展开查看详细输出。

**依赖:** S-C1，S-C3，S-C4

---

#### S-I2 · Verifier Verdict 展示组件

**优先级:** P1  
**来源:** `verificationAgent.ts` → `VERDICT: PASS` / `VERDICT: FAIL` / `VERDICT: PARTIAL` 结构化输出

**做什么:** 识别 verifier 子代理输出的 `VERDICT: PASS/FAIL/PARTIAL` 标记，在消息时间线中以可视化组件展示（绿色 PASS / 红色 FAIL / 黄色 PARTIAL），并在失败时突出显示失败原因。

**新增文件:** `agentGui/Views/Components/VerifierVerdictView.swift`

**接入点:** 消息渲染层，检测 `Message.content` 末尾是否含 `VERDICT:` 行。

**验收标准:**
- PASS 显示绿色标记，FAIL 显示红色标记，PARTIAL 显示黄色标记。
- 点击可展开查看完整验证报告。

**依赖:** S-C1

---

## 4. 优先级汇总

| Feature | 名称 | 优先级 | 依赖 |
|---------|------|--------|------|
| S-A1 | 开放代理定义体系 | P0 | — |
| S-A2 | One-Shot 代理标记 | P0 | S-A1 |
| S-A3 | 子代理模型选择 | P0 | S-A1 |
| S-A4 | 上下文裁剪（omitMainContext）| P1 | S-A1 |
| S-A5 | CriticalSystemReminder | P1 | S-A1 |
| S-B1 | Plan 内置代理 | P1 | S-A1/A3/A4 |
| S-B2 | General-Purpose 后备代理 | P1 | S-A1 |
| S-C1 | SubagentTaskRecord 模型 | P1 | — |
| S-C2 | 子代理异步后台执行器 | P1 | S-C1，S-A1 |
| S-C3 | 子代理进度追踪 | P1 | S-C1 |
| S-C4 | 子代理进度摘要服务 | P1 | S-C1/C2 |
| S-C5 | PollSubagentTool | P1 | S-C1/C2 |
| S-E1 | SubagentLifecycleHook 协议 | P1 | — |
| S-E2 | 内置 SubagentStart 钩子集 | P1 | S-E1，S-D3 |
| S-I1 | SubagentProgressPanel | P1 | S-C1/C3/C4 |
| S-I2 | Verifier Verdict 展示组件 | P1 | S-C1 |
| S-D1 | AgentMemoryScope + PathResolver | P2 | — |
| S-D2 | 代理定义 memory 字段扩展 | P2 | S-D1 |
| S-D3 | 子代理记忆引导注入 | P2 | S-D1/D2 |
| S-D4 | memory_write 目录作用域隔离 | P2 | S-D1/D2/D3 |
| S-D5 | 代理记忆快照系统 | P2 | S-D1/D2 |
| S-F1 | ForkSubagentDefinition | P2 | S-A1，S-C2 |
| S-F2 | ForkMessageBuilder | P2 | S-F1 |
| S-F3 | Fork 并发调度器 | P2 | S-F1/F2，F-C1 |
| S-G1 | SubagentTranscriptStore | P2 | S-C1 |
| S-G2 | SubagentMetadataStore | P2 | S-C1 |
| S-G3 | SubagentResumeCoordinator | P2 | S-G1/G2，S-C2 |
| S-H1 | WorktreeManager | P2 | — |
| S-H2 | WorktreeIsolatedSubagent | P2 | S-H1，S-G2 |

---

## 5. 新增文件目录结构

```text
agentGui/
  Models/
    SubagentTaskRecord.swift                   ← S-C1
    AgentMemoryScope.swift                     ← S-D1（无 SwiftData Model，纯枚举+路径解析）
  Services/
    SubagentGovernance/
      SubagentBackgroundExecutor.swift         ← S-C2
      SubagentProgressSummarizer.swift         ← S-C4
      SubagentLifecycleHook.swift              ← S-E1
      AgentMemoryPathResolver.swift            ← S-D1
      AgentMemorySnapshotCoordinator.swift     ← S-D5
      ForkSubagentDefinition.swift             ← S-F1
      ForkMessageBuilder.swift                 ← S-F2
      SubagentTranscriptStore.swift            ← S-G1
      SubagentMetadataStore.swift              ← S-G2
      SubagentResumeCoordinator.swift          ← S-G3
      WorktreeManager.swift                    ← S-H1
      Hooks/
        MemoryInjectHook.swift                 ← S-E2
        SubagentAuditHook.swift                ← S-E2
    BuiltInTools/
      PollSubagentTool.swift                   ← S-C5
                                               （S-D4 无独立文件：修改 ClaudeService+ToolDispatch.swift）
  Resources/
    Agents/
      plan.agent.md                            ← S-B1
      general.agent.md                         ← S-B2
      explore.agent.md（修改）                  ← S-D2 新增 memory: project
  Views/
    SubagentProgressPanel.swift                ← S-I1
    Components/
      VerifierVerdictView.swift                ← S-I2

# 注：S-D3 无独立文件，修改 ClaudeService+Subagent.swift（runSubagentLoop）
# 注：AgentMemoryEntry.swift（SwiftData Model）已从设计中移除，改为纯文件系统方案
```

---

## 6. 最终判断

Claude Code 的子代理体系对 agentGui 最有价值的不是"更多工具"，而是三个核心设计思路：

1. **代理类型的开放性决定了系统的演进上限。** P0 层（S-A1/A2/A3）只需改 3 个文件，就能把 agentGui 从"固定 3 代理"解锁为"可扩展专用代理生态"，叠加 S-B1（Plan 代理）后，主代理的复杂任务成功率可以直接提升。

2. **后台并发执行是子代理系统从"工具"升级为"协作者"的关键门槛。** P1 层（S-C1~C5）让 verifier 这类长耗时代理不再阻塞主 loop，用户可以在 verifier 跑测试的同时继续和主代理交互；而 Fork 并行模式（S-F1~F3）则让探索类任务的吞吐量呈倍数提升。

3. **子代理记忆的价值在于按类型隔离，而不是再造轮子。** agentGui 已有完整的主代理记忆系统（`memory_write` / `MemoryBootstrapHook` / `MemoryRecallHook`）。P2 层（S-D1~D5）不需要新建 SwiftData 模型或独立 `agent_memory_read` 工具——只需三步：① 在 `.agent.md` 添加 `memory:` 字段；② 将 `AgentLoopMemoryBootstrapComposer` 指向代理类型专属目录；③ 让 `memory_write` 写到同一目录。explore 代理在第二次调用时就能读到上次积累的"这个项目里 `ClaudeService.swift` 不能直接修改"这类项目知识。快照系统（S-D5）进一步让团队能向团队成员共享精心整理过的初始记忆。

落地顺序：**P0（3 个 Feature，纯 loader 层修改）→ P1（14 个 Feature，并发 + 生命周期 + UI）→ P2（12 个 Feature，记忆 + fork + 恢复 + worktree）**。
