# agentGui 动态 Team Workflow 技术方案调研与设计

日期：2026-03-13

## 1. 目标与结论

你提出的问题是准确的：当前 agentGui 的 workflow 虽然已经从单 agent loop 演进到了多角色协作，但本质上仍然是“运行时能力可复用、流程定义强硬编码”。这会直接限制两个方向：

1. 无法通过和 agent 对话，把一个新的 team/workflow 直接落地成系统可运行的对象。
2. 无法让 workflow 成为用户级配置资产，只能继续依赖内置模板和代码发布。

结论先行：**推荐把 agentGui 的 workflow 演进为“混合式声明架构”**。

这里的“混合式”不是折中说法，而是必要边界：

- **Team / workflow 的角色、提示词、工具授权、工件契约、路由规则、预算、完成条件** 应该外置为 JSON 声明，保存在 `~/.agentgui/`。
- **工具实现、运行时调度器、状态机、持久化记录、护栏、验证器、追踪与 UI 面板** 仍应保留为应用内建能力，不能交给 JSON 或 LLM 自由生成执行代码。

换句话说，正确方向不是“让 agent 动态写 Swift 代码生成 workflow”，而是：

1. agent 通过受控 tool 生成或更新 JSON 定义；
2. app 对 JSON 做 schema 校验、语义校验和安全裁剪；
3. runtime 把 JSON 编译成受限的声明式 workflow；
4. 执行态仍复用现有 `WorkflowRuntime`、`WorkflowAgentRunner`、`runCoreAgentLoop` 和 SwiftData 观测链路。

这是当前主流多代理框架最一致的工程方向：

- OpenAI Agents SDK 把 orchestration 拆成 manager-style orchestration、handoff、guardrails、sessions、tracing，而不是让 LLM 任意定义底层执行器。
- CrewAI 把 agents/tasks/flows 声明化，并强调 state、persist、router、human-in-the-loop。
- Temporal/Prefect 这类 workflow 编排系统则证明：生产可用的长流程必须具备 durable state、retry policy、timeout、observability、resume，而不是一次性 prompt 编排。

对 agentGui 最合适的落点是：**基于现有 WorkflowRuntime 增加一个 Declarative Team Definition Layer**。

---

## 2. 当前实现现状与问题定位

### 2.1 当前 workflow 已经不再是“没有架构”，但定义层仍是硬编码

从现有代码看，workflow runtime 已具备比较完整的运行骨架：

- `WorkflowRuntime` 负责调度循环、预算、stall detection、SwiftData 持久化、business event 发射。
- `WorkflowAgentRunner` 负责执行单个 role activation，并复用 `runCoreAgentLoop`。
- `WorkflowDefinition` 已经抽象出模板接口：`makeInitialContext`、`makeScheduler`、`makeReducer`、`evaluateCompletion`。
- `WorkflowContext` 已经有 mailbox、artifact、budget、policies、workspace snapshot 等共享上下文。

这说明系统并不是从零开始，已经具备“声明层与执行层分离”的雏形。

### 2.2 真正硬编码的位置

当前问题主要集中在“模板发现、模板实例化、模板行为建模”三个层面。

#### 问题 A：workflow 注册是静态数组 + switch

当前 `ClaudeService+ToolBuilder.swift` 里：

- `availableWorkflows` 是静态数组；
- `makeWorkflowDefinition(id:)` 是静态 `switch`；
- 目前只支持 `code_change`。

这意味着任何新 workflow 都必须改 Swift 源码并重新发布应用，无法通过配置扩展。

#### 问题 B：`start_workflow` 只能启动预编译模板

当前 `ClaudeService+WorkflowTool.swift` 的 `executeStartWorkflowTool(...)`：

- 接收 `workflow_id` 和 `task`；
- 通过 `makeWorkflowDefinition(id:)` 找定义；
- 同步运行到结束后返回结果摘要。

因此工具层虽然已经把 workflow 暴露给 agent，但暴露的只是“启动某个内建模板”，不是“创建或管理 team/workflow 定义”。

#### 问题 C：`CodeChangeWorkflow` 把 team 拓扑、角色链路、默认路由写死在代码里

`CodeChangeWorkflow.swift` 里硬编码了：

- `roles = [.planner, .explorer, .coder, .reviewer, .executor]`
- workflow bootstrap 时把初始 task 投递给 planner
- scheduler 的角色优先级
- reducer 对不同 role 的专属路由逻辑
- completion checklist

这类设计适合验证第一条 workflow，但不适合承载“用户通过对话自定义 team”。

#### 问题 D：role 定义虽然抽象出来了，但仍是内置 catalog

`WorkflowRoleDefinition.swift` 现在已经统一了：

- system prompt
- 工具授权
- artifact 读写范围
- 消息订阅范围
- 每次 activation budget

但这些 role 最终仍来自 `AgentCatalog.shared` 的内置项，并通过别名把 planner/explorer/coder/reviewer/executor 映射到少数 builtin role。

这说明“角色配置对象”已经存在，但“角色来源”仍不是用户级定义。

#### 问题 E：tool execution coordinator 仍有 workflow 特判

`AgentLoopToolExecutionCoordinator` 目前对 `run_subagent`、`start_workflow`、`bash` 有专门分支。说明 agent loop 仍把 workflow 当成特例工具，而不是“统一的 team runtime capability”。

这会在后续扩展时形成更多 `if toolName == ...`，使动态 team 难以融入统一调度面。

### 2.3 当前架构的优点

虽然定义层硬编码，但下面这些基础已经足够支撑动态化改造：

1. 已有 `WorkflowDefinition` 协议和 runtime 分层。
2. 已有 mailbox + artifact + reducer 的多代理模型。
3. 已有 `WorkflowWorkspaceContext`，适合把当前 IDE 状态注入 team run。
4. 已有 `ConfigDirectoryManager`，并且 `~/.agentgui` 已是现有配置根目录。
5. 已有 SwiftData 的 `WorkflowInstance` / `WorkflowActivationRecord` / `WorkflowMessageRecord` / `WorkflowArtifactRecord` 作为运行态记录。

所以最合理的方向不是重写 runtime，而是：**保留执行内核，替换定义来源和编译方式。**

---

## 3. 主流实践调研与可借鉴结论

### 3.1 OpenAI Agents SDK：manager vs handoff 的边界要明确

OpenAI Agents SDK 对多代理 orchestration 的一个关键区分是：

- `Agents as tools`：manager 保持控制权，调用 specialist 完成局部任务；
- `Handoffs`：当前 agent 把控制权转交给另一个 agent，由后者接管后续回合。

这对 agentGui 的启发是：动态 team 不能只有一个“start_workflow”概念，而要在 definition 里显式表达以下两种协作形态：

1. **Manager-style orchestration**
   适合现有 code-change 这类“有统一最终回答、统一 completion gate”的工作流。

2. **Handoff-style orchestration**
   适合 triage、专科问答、专家切换、客服路由等任务。

如果不先把这两种协作形态区分清楚，后续所有 team 都会被强行套进当前 reducer 驱动模型，扩展性会再次塌缩。

### 3.2 Guardrails 必须分层，而不是只做 workflow 入口校验

OpenAI Agents SDK 的实践很明确：

- input guardrail 只校验入口输入；
- output guardrail 只校验最终输出；
- tool guardrail 才是对每次工具调用都有效的治理点。

对 agentGui 来说，这意味着动态 team 不能只在“创建 team definition 时”做校验，还要在执行时至少具备三层护栏：

1. definition-level validation：JSON schema + semantic validation；
2. run-level guardrails：预算、超时、最大并发、可用工具、artifact contract；
3. tool-level guardrails：例如 bash、文件写入、网络请求、子 workflow 调用。

### 3.3 CrewAI：声明式 flow + state + persist 是落地关键

CrewAI 的可借鉴点不在 Python 语法，而在三件事：

1. Flow 是声明式的，有 start/listen/router；
2. state 是显式对象，不是靠 prompt 记忆；
3. persistence 是默认能力，而不是后补日志。

这与 agentGui 当前已有 `WorkflowContext` 高度契合。对本项目的直接启示是：

- team/workflow definition 应该声明 entrypoints、triggers、routes、state contract；
- run state 应继续保存在 SwiftData，而不是也写入 JSON；
- JSON 只管“模板定义”，SwiftData 只管“运行实例”。

### 3.4 Temporal：durable execution 的核心不是“自动重试全部”，而是“只重试易失败的边界”

Temporal 的关键实践非常适合 agent workflow：

- workflow logic 本身要尽量 deterministic；
- 失败重试应主要作用于 activity / boundary，而不是整个 workflow 全量重跑；
- retry policy、timeout、non-retryable error 都应是声明式策略。

这直接映射到 agentGui：

- 不要在 team definition 里允许“整条 workflow 无限自动重试”；
- 应只对 role activation、tool invocation、artifact validation、external fetch 这类边界设重试；
- workflow 顶层失败应优先进入 paused / partial / needs_human_review，而不是简单重新开始。

### 3.5 Prefect / 通用工作流平台：生产可用必须有 observability 和 search attributes

所有主流 orchestration 平台最终都会落到这些能力：

- execution timeline
- structured logs
- tracing
- filtering/searchable metadata
- replay / resume

agentGui 现在已有 workflow sidebar 和 business events，这是很好的基础。动态 team 设计必须保证以下信息天然可追踪：

- team id / version
- workflow id / version
- run id
- role activation id
- route rule id
- artifact id / version
- tool invocation id
- failure category

否则用户虽然能“创建 team”，但实际运行不可解释，问题会比硬编码更难查。

---

## 4. 设计原则

### 4.1 不是“让 LLM 定义执行器”，而是“让 LLM 填充声明模板”

动态 team 的正确模型应该是：

- LLM 生成的是 **声明数据**；
- app 内核负责 **解析、校验、编译、执行**；
- 运行时的所有可执行逻辑都来自内建受控 primitive。

因此 JSON 中**不允许**：

- 任意脚本
- 任意 Swift 代码
- 任意 shell route expression
- 动态反射类名
- 未注册 tool id

JSON 中**允许**的只有：

- 角色列表
- 角色能力授权
- prompt / instructions
- artifact schema 引用
- 路由条件 DSL
- 预算和策略
- completion policy

### 4.2 文件系统定义与数据库运行态分离

推荐明确分层：

- `~/.agentgui/teams/...json`：用户定义、版本、启用状态、迁移元数据。
- SwiftData：workflow run、activation、message、artifact、timeline。

不要把运行态回写到 team definition JSON。定义文件应保持“模板资产”语义。

### 4.3 V1 必须采用“受限 DSL”，不能做通用编程语言

最常见失败模式是：为了扩展性，过早把 JSON 做成“通用图灵完备工作流脚本”。这会导致：

- 校验复杂度暴涨；
- 安全面扩大；
- UI 无法可视化；
- 测试组合爆炸；
- 迁移兼容极难做。

所以 V1 应只支持有限 primitive：

- role activation
- artifact publication
- message dispatch
- conditional route
- approval gate
- retry / timeout / pause
- finish / fail

### 4.4 对话创建必须走受控 tool，而不是直接开放文件写入

虽然项目已有文本编辑工具，但不建议让 agent 通过普通文件编辑工具直接写 `~/.agentgui/team.json`。正确方式是增加专门 tool：

- 负责 JSON 正常化
- 自动补 schema version / timestamps
- 执行校验
- 原子写入
- 维护索引
- 返回错误位置和可修复建议

这能显著减少 agent 写坏配置文件的概率。

---

## 5. 推荐总体架构

### 5.1 架构总览

```text
User Chat
  -> Main Agent
    -> Team Definition Tools
      -> Definition Validator
      -> Definition File Store (~/.agentgui)
      -> Team Registry
    -> Start Team Workflow Tool
      -> Declarative Workflow Compiler
      -> WorkflowRuntime
      -> WorkflowAgentRunner
      -> runCoreAgentLoop
      -> SwiftData Run Records
      -> UI Workflow Sidebar
```

### 5.2 新增核心层

建议新增以下组件：

1. `TeamDefinition`
   顶层 JSON 对应的 Swift `Codable` 模型。

2. `TeamDefinitionValidator`
   负责 schema 校验、语义校验、安全校验。

3. `TeamDefinitionFileStore`
   负责 `~/.agentgui/teams` 的目录管理、原子写入、版本索引。

4. `TeamRegistry`
   负责加载可用 team definitions、缓存、热刷新、按 id/version 查询。

5. `DeclarativeWorkflowCompiler`
   把 `TeamDefinition` 编译为 runtime 可执行的 `WorkflowDefinition` 实例。

6. `DeclarativeWorkflowDefinition`
   一个通用实现，替代为每个 team 都写一个 `CodeChangeWorkflow.swift`。

7. `DeclarativeWorkflowScheduler`
   根据 JSON 路由规则做 next-role 选择。

8. `DeclarativeWorkflowReducer`
   根据消息、artifact 和 route rules 更新共享 context。

9. `TeamDefinitionToolService`
   作为主 agent 调用的 tool 后端，负责 create/update/validate/list/delete。

### 5.3 保留不变的层

以下层建议尽量复用：

- `WorkflowRuntime`
- `WorkflowAgentRunner`
- `WorkflowContext`
- `WorkflowMessageRecord` / `WorkflowArtifactRecord` / `WorkflowActivationRecord`
- `runCoreAgentLoop`
- `AgentLoopHookEmitter` / `AgentLoopHookDispatcher`
- 现有 UI 时间线与 artifact 面板

这样改造范围集中在“定义输入层”和“通用编译层”，而不是重写 agent loop。

---

## 6. `~/.agentgui` 目录设计

### 6.1 推荐目录结构

建议在现有 `~/.agentgui/` 下新增一套 team/workflow 目录：

```text
~/.agentgui/
  memory.md
  unified-memory/
  teams/
    index.json
    team-code-review/
      team.json
      versions/
        1.0.0.json
        1.1.0.json
    team-research-writer/
      team.json
      versions/
        1.0.0.json
  schemas/
    team-definition.schema.json
```

### 6.2 文件职责

#### `index.json`

保存轻量索引，便于快速展示和查找：

```json
{
  "schemaVersion": 1,
  "teams": [
    {
      "teamId": "team-code-review",
      "displayName": "代码审查 Team",
      "activeVersion": "1.1.0",
      "updatedAt": "2026-03-13T10:20:30Z",
      "enabled": true,
      "tags": ["coding", "review"]
    }
  ]
}
```

#### `team.json`

保存当前激活版本的完整定义，便于 runtime 直接读取。

#### `versions/*.json`

保存历史版本，支持回滚、diff、审计和迁移测试。

### 6.3 为什么不用单文件平铺

相比 `~/.agentgui/teams/team-code-review.json` 这种平铺方案，目录式结构有几个优势：

1. 支持版本历史而不污染顶层目录。
2. 未来可加入配套资源，如 prompt snapshot、icon、sample input、migration notes。
3. 更容易做 import/export。

---

## 7. Team Definition JSON 模型

### 7.1 顶层结构

建议 V1 的 `team.json` 结构如下：

```json
{
  "schemaVersion": 1,
  "teamId": "team-code-review",
  "definitionVersion": "1.0.0",
  "displayName": "代码修改审查 Team",
  "description": "用于规划、实现、审查和验证代码修改的多代理工作流。",
  "enabled": true,
  "createdAt": "2026-03-13T10:20:30Z",
  "updatedAt": "2026-03-13T10:20:30Z",
  "createdBy": {
    "source": "agent",
    "model": "claude"
  },
  "metadata": {
    "tags": ["coding", "workflow"],
    "recommendedFor": ["跨文件修改", "需要审查与验证的任务"]
  },
  "runtime": {
    "mode": "manager",
    "entryRole": "planner",
    "allowParallelRoles": false
  },
  "budget": {
    "maxTotalActivations": 80,
    "maxActivationsPerRole": 5,
    "defaultMaxTurnsPerActivation": 16,
    "workflowTimeoutSeconds": 0,
    "stallTimeoutSeconds": 180
  },
  "roles": [],
  "artifacts": [],
  "routes": [],
  "completionPolicy": {},
  "guardrails": {},
  "ui": {}
}
```

### 7.2 Role 结构

```json
{
  "id": "planner",
  "displayName": "规划师",
  "description": "把用户任务拆成可执行计划。",
  "instructions": "你负责生成结构化执行计划。优先判断是否需要额外探索。",
  "capabilities": {
    "enableTextEditor": true,
    "enableBash": false,
    "enableWebSearch": false,
    "enableWebFetch": false,
    "enableStoryMemoryTools": false,
    "toolGrants": ["read_file", "semantic_search"]
  },
  "contracts": {
    "readableArtifacts": ["plan", "explorationReport", "reviewReport", "testReport"],
    "writableArtifacts": ["plan"],
    "subscribesTo": ["task", "reviewFeedback", "rejection", "escalation"],
    "defaultOutputMessageKind": "task",
    "primaryOutputArtifactKind": "plan"
  },
  "budgets": {
    "maxTurnsPerActivation": 8,
    "maxActivations": 3
  }
}
```

### 7.3 Artifact 结构

artifact 需要是显式声明对象，而不是只靠字符串名字：

```json
{
  "kind": "plan",
  "displayName": "执行计划",
  "jsonSchema": {
    "type": "object",
    "required": ["goal", "steps"],
    "properties": {
      "goal": { "type": "string" },
      "steps": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["id", "title"],
          "properties": {
            "id": { "type": "string" },
            "title": { "type": "string" }
          }
        }
      },
      "requiresExploration": { "type": "boolean" }
    }
  },
  "versioning": {
    "strategy": "replace-latest"
  }
}
```

V1 建议 artifact kind 仍限制在内建枚举集合，避免 UI 和持久化模型同步失控。V2 再考虑开放自定义 artifact kind。

### 7.4 Route DSL

推荐采用“受限条件 + 受限动作”的 DSL，不允许任意表达式引擎。

示例：

```json
{
  "id": "planner-needs-exploration",
  "trigger": {
    "type": "artifact_published",
    "artifactKind": "plan",
    "producer": "planner",
    "where": [
      {
        "path": "$.requiresExploration",
        "operator": "equals",
        "value": true
      }
    ]
  },
  "actions": [
    {
      "type": "dispatch_message",
      "to": ["explorer"],
      "kind": "task",
      "subjectTemplate": "根据计划执行探索",
      "bodyTemplate": "用户任务：{{workflow.userTask}}\n计划：{{artifact.contentJson}}"
    }
  ]
}
```

另一个示例：

```json
{
  "id": "executor-failed-back-to-coder",
  "trigger": {
    "type": "artifact_published",
    "artifactKind": "testReport",
    "producer": "executor",
    "where": [
      {
        "path": "$.status",
        "operator": "equals",
        "value": "failed"
      }
    ]
  },
  "actions": [
    {
      "type": "dispatch_message",
      "to": ["coder"],
      "kind": "rejection",
      "subjectTemplate": "修复测试失败",
      "bodyTemplate": "测试失败，请根据报告修复。\n报告：{{artifact.contentJson}}"
    }
  ]
}
```

### 7.5 Completion Policy

completion 也应声明化，而不是每个 workflow 都写一个 `evaluateCompletion(...)`。

```json
{
  "mode": "all_of",
  "checks": [
    {
      "id": "has-plan",
      "type": "artifact_exists",
      "artifactKind": "plan",
      "critical": false
    },
    {
      "id": "review-approved",
      "type": "artifact_field_equals",
      "artifactKind": "reviewReport",
      "path": "$.verdict",
      "value": "approved",
      "critical": true
    },
    {
      "id": "tests-passed",
      "type": "artifact_field_equals",
      "artifactKind": "testReport",
      "path": "$.status",
      "value": "passed",
      "critical": true
    }
  ]
}
```

### 7.6 Guardrails

```json
{
  "toolPolicy": {
    "allowedToolIds": ["read_file", "str_replace_based_edit_tool", "bash", "semantic_search"],
    "denyDangerousBashPatterns": true
  },
  "executionPolicy": {
    "pauseOnRepeatedFailure": true,
    "repeatFailureThreshold": 2,
    "pauseOnContractViolation": true
  },
  "humanReview": {
    "requiredForCompletion": false,
    "requiredWhen": ["high_risk_file_change", "destructive_command"]
  }
}
```

---

## 8. Swift 侧数据模型设计

### 8.1 顶层 Codable 模型

建议新增：

```swift
struct TeamDefinition: Codable, Sendable {
    let schemaVersion: Int
    let teamId: String
    let definitionVersion: String
    let displayName: String
    let description: String
    let enabled: Bool
    let createdAt: Date
    let updatedAt: Date
    let createdBy: DefinitionAuthor
    let metadata: TeamMetadata
    let runtime: TeamRuntimeSpec
    let budget: TeamBudgetSpec
    let roles: [TeamRoleSpec]
    let artifacts: [ArtifactSpec]
    let routes: [RouteSpec]
    let completionPolicy: CompletionPolicySpec
    let guardrails: GuardrailSpec
    let ui: TeamUISpec
}
```

### 8.2 编译结果模型

JSON decode 后不要直接交给 runtime。建议增加一个已验证、已编译的中间层：

```swift
struct CompiledTeamDefinition: Sendable {
    let source: TeamDefinition
    let rolesById: [String: WorkflowRoleDefinition]
    let routeGraph: RouteGraph
    let artifactValidators: [WorkflowArtifactKind: ArtifactValidator]
    let completionEvaluator: DeclarativeCompletionEvaluator
}
```

这样能把“数据解析错误”和“执行时逻辑错误”分离。

---

## 9. Definition 校验策略

### 9.1 三层校验

#### 第一层：Schema 校验

检查字段类型、必填字段、枚举值、数组结构。

#### 第二层：语义校验

例如：

- `entryRole` 必须存在于 `roles` 中。
- route 的 `producer`、`artifactKind`、`to` 都必须引用合法对象。
- role 的 `writableArtifacts` 必须在 `artifacts` 中声明。
- completionPolicy 引用的 artifact/path 必须可解析。

#### 第三层：安全校验

例如：

- 不允许未注册 tool id。
- 不允许 role 申请超出当前 app policy 的工具集。
- 不允许 `enableBash = true` 且未声明 bash policy。
- 不允许 `start_workflow` 递归启动自身或无限嵌套 team。

### 9.2 错误返回格式

tool 层不要只返回“validation failed”，应返回结构化错误：

```json
{
  "ok": false,
  "errors": [
    {
      "code": "UNKNOWN_TOOL_ID",
      "path": "$.roles[1].capabilities.toolGrants[2]",
      "message": "tool 'run_terminal_as_root' is not registered"
    }
  ],
  "warnings": [
    {
      "code": "NO_COMPLETION_GUARD",
      "path": "$.completionPolicy",
      "message": "workflow has no critical completion checks"
    }
  ]
}
```

这能让 agent 迭代修正，而不是一次失败后失去上下文。

---

## 10. 动态创建 Team 的 Tool 设计

### 10.1 推荐新增工具

建议至少新增以下 tool：

#### `save_team_definition`

用途：创建或更新 team definition。

输入：

```json
{
  "team_id": "team-code-review",
  "definition_json": "{...}",
  "activate": true,
  "create_version": true
}
```

行为：

- decode JSON
- 校验
- 正常化
- 原子写入 `team.json`
- 可选写入 `versions/x.y.z.json`
- 更新 `index.json`

#### `validate_team_definition`

用途：只做校验，不落盘。

适合 agent 先草拟，再修正。

#### `list_team_definitions`

用途：列出现有 team、版本、启用状态、标签。

#### `delete_team_definition`

用途：删除或禁用 team definition。

V1 建议默认做 soft delete，即 `enabled=false`。

#### `start_team_workflow`

用途：按 team id 启动一个声明式 workflow。

这相当于未来替代或并行于当前 `start_workflow`。

### 10.2 为什么不建议一个万能 tool

可以设计成 `manage_team_definition(action: ...)`，但不推荐 V1 这么做。原因：

1. schema 更复杂，模型更容易填错。
2. 日志与审计不清晰。
3. 每个 action 的输入约束不同，拆开更适合 LLM。

---

## 11. Runtime 编译与执行设计

### 11.1 编译流程

```text
load JSON
  -> decode TeamDefinition
  -> TeamDefinitionValidator
  -> normalize / fill defaults
  -> compile roles
  -> compile routes
  -> compile completion policy
  -> produce DeclarativeWorkflowDefinition
  -> WorkflowRuntime.startWorkflow(...)
```

### 11.2 `DeclarativeWorkflowDefinition`

建议实现一个通用的 `WorkflowDefinition`：

```swift
struct DeclarativeWorkflowDefinition: WorkflowDefinition {
    let compiled: CompiledTeamDefinition

    var id: String { compiled.source.teamId }
    var displayName: String { compiled.source.displayName }
    var description: String { compiled.source.description }

    func makeInitialContext(task: String, sessionId: String) -> WorkflowContext
    func makeScheduler() -> any WorkflowScheduler
    func makeReducer() -> any WorkflowReducer
    func evaluateCompletion(in context: WorkflowContext) -> CompletionEvaluation
}
```

这样现有 `WorkflowRuntime` 几乎无需知道定义来自代码还是来自 JSON。

### 11.3 Scheduler 设计

V1 推荐仍维持“单 active role、消息驱动调度”的模型，而不是一开始上 DAG 并发引擎。

原因：

1. 当前 `WorkflowRuntime` 已是单角色串行调度。
2. UI 时间线、SwiftData 记录和 artifact 更新语义已围绕这个模型建立。
3. 串行模型对 LLM agent 更稳定、更容易调试。

因此 JSON 的 `allowParallelRoles` 在 V1 最多做保留字段，不建议真正启用并行执行。

### 11.4 Reducer 设计

当前 `CodeChangeReducer` 是 role-specific imperative code。动态化后建议变为“事件触发 + action 列表”：

- 输入事件：message published、artifact published、activation failed、stall detected、completion evaluated。
- action primitive：dispatch_message、block_role、pause_workflow、mark_failed、emit_status、request_human_review。

通过受限 action 集，就能把大部分 workflow 行为声明出来，而不必为每个 team 写 reducer 代码。

### 11.5 与现有 artifact/message 模型的兼容

动态 team 最重要的原则之一是：**不要新发明第二套通信模型。**

继续复用：

- `WorkflowMessageKind`
- `WorkflowArtifactKind`
- `WorkflowContext.deliver(...)`
- `WorkflowActivationRecord`

这样现有 UI 和 observability 基础设施都可以继续工作。

---

## 12. 与当前代码结构的映射改造建议

### 12.1 `ClaudeService+ToolBuilder.swift`

当前：

- `availableWorkflows` 静态数组
- `makeWorkflowDefinition(id:)` 静态 switch

建议改为：

- `BuiltinWorkflowRegistry`：保留内建 workflow
- `TeamRegistry`：读取 `~/.agentgui/teams`
- `WorkflowCatalogService`：统一合并 builtin + user-defined catalog

这样 `start_workflow` 或新的 `start_team_workflow` 就不再依赖硬编码 switch。

### 12.2 `ClaudeService+WorkflowTool.swift`

建议拆分为两层：

1. `executeStartWorkflowTool(...)`
   兼容旧内建 workflow 启动。

2. `executeStartTeamWorkflowTool(...)`
   读取 team registry，加载声明式定义后启动。

V2 再考虑把二者合并到统一 catalog。

### 12.3 `WorkflowRoleDefinition.swift`

建议保留这个类型作为 runtime role 的统一结构，但角色来源改为两类：

- builtin role：来自 `AgentCatalog`
- dynamic role：来自 `TeamRoleSpec.compile()`

### 12.4 `CodeChangeWorkflow.swift`

不建议立刻删除。更合理做法是：

- 保留为 builtin baseline；
- 同时把它迁移出一份等价 JSON，作为 declarative compiler 的 golden sample；
- 用这份 sample 验证“声明式 runtime 能否等价表达当前 code_change”。

如果这一步做不到，说明 DSL 设计还不够。

### 12.5 `ConfigDirectoryManager.swift`

建议扩展路径助手：

```swift
var teamsDirectoryURL: URL
func teamDirectoryURL(teamId: String) -> URL
func activeTeamDefinitionURL(teamId: String) -> URL
func teamVersionFileURL(teamId: String, version: String) -> URL
var teamIndexFileURL: URL
```

### 12.6 `WorkflowRuntime.swift`

尽量不重写主体，只需要补：

- run metadata 中记录 `teamId` / `definitionVersion`
- 暂停/恢复时能重新装载 definition snapshot
- 事件里带 route rule id / compiled definition id

---

## 13. 版本化与迁移策略

### 13.1 双版本字段

JSON 顶层建议同时保留：

- `schemaVersion`：定义文件结构版本
- `definitionVersion`：用户业务定义版本

二者职责不同：

- `schemaVersion` 用于 app 升级时迁移解析器；
- `definitionVersion` 用于用户修改 team 的历史版本管理。

### 13.2 激活版本与运行快照分离

一个很重要的实践是：workflow run 开始时，应把当前 definition snapshot 写入 run metadata，而不是只记录 `teamId`。

否则 team 定义被用户更新后，历史 run 无法正确回放和解释。

推荐在 `WorkflowInstance` 增加字段：

- `definitionSourceType: builtin | user_json`
- `definitionId`
- `definitionVersion`
- `definitionSnapshotJson`

V1 即便不做完整 replay，也应该做 snapshot 留档。

### 13.3 向后兼容

迁移顺序建议：

1. 保留现有 builtin workflow 入口。
2. 新增 team registry 和 declarative compiler。
3. 让 `code_change` 同时有 builtin 和 JSON sample。
4. 当 JSON 版本稳定后，再考虑把 builtin `code_change` 改为从内置 bundled JSON 加载。

---

## 14. 安全与治理设计

### 14.1 绝不能把 tool 权限完全交给 team JSON

team 定义可以申请工具，但最终授权必须是“声明请求 + host 审批裁剪”。

例如：

- team JSON 申请 `bash`
- host 根据全局设置 `settings.enableBashTool` 决定是否真正授予
- 如果用户全局关闭 bash，则编译期直接报错或降级

### 14.2 bash 和文件写入需要额外治理

对于动态 team，最容易失控的是：

- 任意 bash
- 任意文件修改
- 无限子 workflow / 子 agent 嵌套

建议 V1 策略：

1. 动态 team 默认不允许申请高风险 tool，除非用户显式开启。
2. `start_team_workflow` 不允许递归调用自身。
3. 对 bash 工具调用复用现有 audit / observation hook，并在 workflow run 级别计数。
4. 对 destructive shell pattern 额外做 rule-based 拦截。

### 14.3 对话式创建时的人机确认

对于高风险 team 建议引入确认机制：

- agent 先生成草案 JSON
- tool 返回 summary
- UI 弹出 review sheet 或 ask-user question
- 用户确认后才真正落盘并启用

这比让 agent 直接写入并立即激活更稳妥。

---

## 15. UI / 交互设计建议

### 15.1 对话创建流程

推荐交互如下：

1. 用户说：“帮我创建一个 code review team，包含 planner/coder/reviewer/tester。”
2. 主 agent 分析需求。
3. 主 agent 调用 `validate_team_definition` 草拟 JSON。
4. 若有错误，自动修正后再次校验。
5. 调用 `save_team_definition`。
6. UI 显示创建成功卡片：team 名称、版本、角色数、工具权限、启用状态。
7. 用户随后可说：“用刚才那个 team 执行这个任务。”
8. 主 agent 调用 `start_team_workflow`。

### 15.2 Team 管理面板

建议未来增加一个 Settings 或 Sidebar 面板：

- team 列表
- 当前激活版本
- 角色预览
- 工具权限预览
- JSON 原文查看
- 导入/导出
- 回滚版本

### 15.3 运行时展示

workflow sidebar 应补充两类信息：

- Definition metadata：team id、definition version、source=user_json。
- Route trace：本次为什么从 A 跳到 B，对应哪条 route rule。

没有 route trace，动态 workflow 出问题时几乎无法解释。

---

## 16. 测试策略

### 16.1 单元测试

必须新增以下测试组：

1. `TeamDefinitionDecodingTests`
   验证 JSON decode 和默认值填充。

2. `TeamDefinitionValidatorTests`
   验证 schema、语义、权限校验。

3. `TeamDefinitionFileStoreTests`
   验证目录创建、原子写入、版本文件、索引更新。

4. `DeclarativeWorkflowCompilerTests`
   验证 JSON 到 runtime role / route / completion evaluator 的编译正确性。

5. `DeclarativeWorkflowSchedulerTests`
   验证 route rule 和 mailbox 优先级。

6. `DeclarativeWorkflowReducerTests`
   验证 message/artifact 触发路由。

### 16.2 Characterization Tests

应拿当前 `CodeChangeWorkflow` 做对照测试：

- 使用 builtin `CodeChangeWorkflow` 运行样例上下文；
- 使用等价 JSON 编译出的 declarative workflow 再跑一遍；
- 断言关键状态转移、artifact 产物、route 行为一致。

这是整个方案最关键的信心来源。

### 16.3 集成测试

需要覆盖：

1. 主 agent 通过 tool 创建 team definition。
2. team definition 被写入 `~/.agentgui/teams`。
3. registry 热加载后可见。
4. `start_team_workflow` 能正常启动。
5. run metadata 正确记录 team/version。

### 16.4 异常测试

重点测试：

- 非法 JSON
- 未知 tool id
- route 死循环
- completion policy 永不满足
- role 无法产出 primary artifact
- disabled team 被启动
- definition 更新后旧 run snapshot 保持不变

---

## 17. 实施路线图

### Phase 1：Definition 存储与校验

目标：先让 team definition 能创建、校验、保存，但还不执行。

交付：

- `TeamDefinition` Codable 模型
- `TeamDefinitionValidator`
- `TeamDefinitionFileStore`
- `TeamRegistry`
- `validate_team_definition` / `save_team_definition` / `list_team_definitions`

### Phase 2：Declarative Workflow Compiler

目标：让 JSON team 能编译为 `WorkflowDefinition`。

交付：

- `DeclarativeWorkflowDefinition`
- `DeclarativeWorkflowScheduler`
- `DeclarativeWorkflowReducer`
- `DeclarativeCompletionEvaluator`
- `start_team_workflow`

### Phase 3：内建 `code_change` 对齐

目标：用 JSON 等价表达现有 code change 流程。

交付：

- 一份官方内置 JSON sample
- characterization tests
- route trace UI

### Phase 4：治理与高级能力

目标：把系统推向可长期使用。

交付：

- approval gate
- human-in-the-loop
- version rollback
- import/export
- definition snapshot viewer
- risk-based permission confirmation

---

## 18. 推荐的 V1 范围

为了控制复杂度，我建议 V1 明确限制为：

1. 单 workflow 单 active role，不做并行执行。
2. artifact kind 仅允许使用内建枚举。
3. route DSL 仅支持内建 trigger/action primitive。
4. role 工具集只能从现有 registry 中申请。
5. 通过专用 tool 创建 team definition，不开放任意文件写入。
6. 运行态仍由 SwiftData 持久化，不做 definition JSON 上的 run-state 回写。

这是最小但完整的一版，已经足够实现“通过和 agent 对话，动态创建 team 并执行 workflow”。

---

## 19. 不推荐的方案

### 19.1 不推荐：让 agent 直接生成 Swift 文件并编译成 workflow

问题：

- 安全面太大
- 热更新复杂
- 测试和签名难做
- macOS app 内动态代码加载不可控

### 19.2 不推荐：只把 prompts 外置，流程逻辑仍写死

这只能改善角色 prompt 的可配性，解决不了 workflow 拓扑和路由扩展性问题。

### 19.3 不推荐：用自由文本描述 workflow，再让 agent 每次自己“理解后执行”

这本质上还是 prompt 编排，不可预测、不可验证、不可观测。

### 19.4 不推荐：直接做通用 DAG/脚本引擎

对当前项目阶段来说过重，且会削弱现有 workflow UI/trace 的可解释性。

---

## 20. 最终建议

综合当前代码基础和主流实践，我的明确建议是：

### 20.1 架构方向

采用 **“受限 JSON 声明 + 内建运行时编译执行”** 的混合架构。

### 20.2 存储方向

把 team/workflow 模板定义放在：

```text
~/.agentgui/teams/<team-id>/team.json
~/.agentgui/teams/<team-id>/versions/<definition-version>.json
```

运行态记录继续保存在 SwiftData。

### 20.3 交互方向

通过专用 tool 让主 agent：

1. 生成 team definition 草案；
2. 校验并修正；
3. 原子写入 `~/.agentgui`；
4. 再按 team id 启动 workflow。

### 20.4 工程策略

优先把现有 `CodeChangeWorkflow` 转译为一份等价 JSON sample，作为整个 declarative runtime 的验证基线。

如果这一步成功，说明 agentGui 的 workflow 体系已经从“硬编码模板”升级为“用户可编排的 team runtime”。如果这一步做不通，说明 DSL 还不够表达当前真实需求，应先补 DSL，不要急着开放给用户。

---

## 21. 一句话总结

你要的不是“再加几个 workflow 模板”，而是把 agentGui 从“内置 workflow 应用”升级为“可通过对话生成和管理 team 定义的 workflow 平台”。最稳妥的实现方式，就是让 agent 通过 tool 生成并维护 `~/.agentgui` 下的 JSON 定义，再由现有 runtime 负责编译和执行。