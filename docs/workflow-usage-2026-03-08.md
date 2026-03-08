# Workflow Orchestration 使用说明

日期：2026-03-08

## 概述

agentGui 现在支持**多代理 Workflow 编排**。与原有的单次 `run_subagent` 工具调用不同，Workflow 引入了一个完整的运行时层，可以让多个专职代理在共享上下文中协作，支持非线性回路、结构化中间产物和持久化的执行轨迹。

---

## 快速开始：启动一个 CodeChangeWorkflow

在 ChatView 的代码中（或通过主代理调用），使用 `WorkflowRuntime` 启动一个编码工作流：

```swift
// 1. 从环境中取出 WorkflowRuntime
@Environment(WorkflowRuntime.self) var workflowRuntime

// 2. 启动工作流（异步，返回 WorkflowHandle）
let handle = try await workflowRuntime.startWorkflow(
    definition: CodeChangeWorkflow(),
    session: session,
    initialTask: "在 ChatView 的工具栏中添加一个 '导出对话' 按钮，导出为 Markdown 格式",
    modelContext: modelContext
)
```

`startWorkflow` 会阻塞直到工作流以 `completed` / `failed` / `cancelled` 状态结束。如需后台运行，在 `Task { }` 中调用即可。

---

## 架构总览

```
WorkflowRuntime (orchestrator)
│
├── WorkflowDefinition       ← 定义 workflow 类型（角色、路由规则、完成策略）
│     └── CodeChangeWorkflow ← 目前唯一的内置模板
│
├── WorkflowScheduler        ← 决定下一个运行的角色
├── WorkflowReducer          ← 把激活结果归约到共享状态
├── WorkflowAgentRunner      ← 执行单次 agent 激活（调用 runCoreAgentLoop）
│
└── SwiftData Persistence
      ├── WorkflowInstance         ← 一次 workflow 运行的记录
      ├── WorkflowActivationRecord ← 每次 agent 被唤醒的记录
      ├── WorkflowMessageRecord    ← agent 间通信的消息记录
      └── WorkflowArtifactRecord   ← 结构化工件（план、报告、patch 等）
```

---

## CodeChangeWorkflow：执行路径

```
用户任务
   │
   ▼
planner  ──→  制定执行计划 (plan artifact)
   │
   ├── 任务不需要探索 ──→ coder
   │
   └── 任务需要探索 ──→ explorer ──→ 产出 explorationReport ──→ coder
                              ↑
                              └── coder 遇到信息不足时，发 infoRequest

coder ──→ 实施变更 (codePatchSummary artifact)
   │
   ├──→ reviewer ──→ 产出 reviewReport
   │         │
   │         ├── verdict: approved ──→ 检查 executor 结果
   │         │
   │         └── verdict: needs_revision ──→ reviewFeedback ──→ coder（重新实施）
   │
   └──→ executor ──→ 运行验证命令 (testReport artifact)
             │
             ├── status: passed ──→ 检查 reviewer 结果
             │
             └── status: failed ──→ rejection ──→ coder（修复后重试）

✅ 完成条件：reviewReport.verdict == "approved" AND testReport.status == "passed"
```

---

## 角色说明

| 角色 | 名称 | 工具 | 可写工件 | 调用上限 |
|------|------|------|----------|----------|
| `planner` | 规划师 | 文本编辑器（只读） | `plan` | 3 次 |
| `explorer` | 探索者 | 文本编辑器（只读）、网络搜索 | `explorationReport` | 5 次 |
| `coder` | 编写者 | 文本编辑器、bash | `codePatchSummary` | 5 次 |
| `reviewer` | 审查者 | 文本编辑器（只读） | `reviewReport` | 5 次 |
| `executor` | 执行者 | bash | `testReport` | 5 次 |

每个角色在单次激活内最多运行 **16 个内部轮次**（coder），其他角色默认 6–12 轮。

---

## 结构化工件

工件是工作流中各代理之间共享的持久化事实对象。每次更新都会递增版本号。

| 工件类型 | 生产者 | 内容 schema |
|----------|--------|-------------|
| `plan` | planner | `{ goal, steps[], assumptions[], success_criteria[], requires_exploration }` |
| `explorationReport` | explorer | `{ relevant_files[], key_symbols[], findings, open_questions[], risk_areas[] }` |
| `codePatchSummary` | coder | `{ changed_files[], summary, verification_command, needs_more_context, context_questions[] }` |
| `reviewReport` | reviewer | `{ blocking_findings[], warnings[], suggestions[], verdict, summary }` |
| `testReport` | executor | `{ command, status, output_summary, failures[], reproducible }` |

---

## UI：Workflow 面板

当一个会话（Session）关联了至少一个 WorkflowInstance 时，ChatView 工具栏会出现一个 **Workflow 按钮**（`flowchart` 图标）。

点击后右侧展开三标签面板：

- **时间线**：每次 agent 激活的节点，显示角色名、耗时、触发原因和结果摘要
- **消息**：agent 间的所有通信消息，可点击展开 body
- **工件**：按类型分组的结构化工件，显示版本号和状态，可点击展开 JSON 内容

---

## 预算与护栏

`CodeChangeWorkflow` 默认配置：

| 参数 | 默认值 |
|------|--------|
| 总激活轮次上限 | 80 轮 |
| 每角色最大激活次数 | 5 次 |
| 单次激活最大内部轮次 | 16 轮 |
| 停滞超时（无进展） | 180 秒 |
| 同一 review finding 重复阈值 | 2 次 |
| 停滞时升级到人工 | 是 |

超出预算后 workflow 状态变为 `failed`；停滞则变为 `paused`，并向 planner 发一条 `escalation` 消息。

---

## 添加自定义 Workflow

实现 `WorkflowDefinition` 协议即可：

```swift
struct MyCustomWorkflow: WorkflowDefinition {
    let id = "my_custom"
    let displayName = "自定义流程"
    let description = "..."

    func makeInitialContext(task: String, sessionId: String) -> WorkflowContext {
        var ctx = WorkflowContext(
            sessionId: sessionId,
            definitionId: id,
            userTask: task
        )
        ctx.roles = [.explorer, .writer]
        // 向 explorer 投递初始任务
        ctx.deliver(WorkflowMessage(
            workflowId: ctx.workflowId,
            sender: "user",
            recipients: ["explorer"],
            kind: .task,
            subject: "Research task",
            body: task
        ))
        return ctx
    }

    func makeScheduler() -> any WorkflowScheduler { MyScheduler() }
    func makeReducer() -> any WorkflowReducer { MyReducer() }
}
```

然后传入 `workflowRuntime.startWorkflow(definition: MyCustomWorkflow(), ...)` 即可。

---

## 兼容性说明

原有的 `run_subagent` 工具调用**保持不变**，不受本次改动影响。`WorkflowRuntime` 是一个独立的并行路径，只有显式调用 `startWorkflow()` 才会激活。

---

## 相关文件

| 文件 | 说明 |
|------|------|
| `Services/WorkflowDefinition.swift` | 协议层 + 所有 in-memory 值类型 |
| `Services/WorkflowRuntime.swift` | 调度器主体 |
| `Services/WorkflowAgentRunner.swift` | Agent 激活执行封装 |
| `Services/Workflows/CodeChangeWorkflow.swift` | 首个模板 |
| `Models/WorkflowRoleDefinition.swift` | 5 个内置角色定义 |
| `Models/WorkflowInstance.swift` | SwiftData 持久化主体 |
| `Models/WorkflowModels.swift` | 所有枚举与值类型 |
| `Views/WorkflowTimelineView.swift` | 时间线 + 消息视图 |
| `Views/WorkflowArtifactPanel.swift` | 工件面板 + WorkflowSidebar |
