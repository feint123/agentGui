# agentGui Agent Loop 设计评审与改进建议

日期：2026-03-07

## 1. 评审范围

本次评审主要基于以下实现：

- `agentGui/Services/ClaudeService+AgenticLoop.swift`
- `agentGui/Services/ClaudeService+Subagent.swift`
- `agentGui/Services/ClaudeService+ContextCompression.swift`
- `agentGui/Services/ClaudeService+ToolDispatch.swift`
- `agentGui/Services/BashSession.swift`
- `agentGui/Services/ACPClientService.swift`
- `agentGui/Models/SubagentDefinition.swift`

对照的成熟经验主要来自：

- Anthropic tool use / Claude Code / subagents / permissions 文档
- OpenAI Agents / AgentKit 的工作流、评估与观测思路
- 业界常见 coding agent 模式：plan-execute-review、权限分层、可恢复执行、强观测、子代理隔离上下文

## 2. 当前设计的优点

先说结论：现在这套 agent loop 已经不是“玩具版”，而是一个可工作的第一代实现，尤其是下面几件事是对的。

### 2.1 主循环和子代理循环已经分层

主代理使用 `runAgenticLoop(...)`，子代理使用 `runSubagentLoop(...)`，这让后续做能力收敛、权限差异化、模型路由变得可行。这个分层方向是对的。

### 2.2 工具调用记录和轮次记录已经落盘

`AgentRound` 和 `ToolCall` 已经是持久化实体，UI 也已经能基于这些实体做时间线展示。这意味着你后面要补 observability、失败诊断、回放分析，都有数据结构基础，不需要重做。

### 2.3 已经意识到上下文膨胀问题

`compressIfNeeded(...)` 虽然比较粗糙，但至少已经把“context 不会无限增长”作为一等问题在处理。很多 agent 产品恰恰死在这里。

### 2.4 子代理做了最基本的能力隔离

子代理不能递归 `run_subagent`，也不能 `ask_user_question`。这避免了很大一类失控编排问题。

## 3. 当前设计最值得优先改进的点

下面按优先级排序。前 4 项我认为是 P0/P1，值得优先处理。

### 3.1 主循环缺少明确的停止策略和恢复策略

当前主循环基本是：

1. 发起一次 streaming 请求
2. 如果 `stopReason == "tool_use"`，执行工具并继续
3. 否则结束循环

这有几个问题：

- 没有主循环级 `maxRounds`，理论上可能无限自旋
- 没有区分 `end_turn`、`max_tokens`、`pause_turn`、异常中断这些 stop reason
- 没有“达到轮次上限后的安全收尾策略”
- 没有“继续上一次未完成响应”的 resume 语义

成熟 agent loop 的经验是：**停止条件必须显式建模，而不是把“不是 tool_use”都视为结束。**

建议：

- 给主循环增加 `maxRounds`，默认建议 `12` 或 `16`
- 明确处理 stop reason：
  - `end_turn`: 正常结束
  - `tool_use`: 执行工具后续跑
  - `max_tokens`: 追加一个 continuation turn，请模型只完成当前回答，不重新规划
  - `pause_turn`: 直接把上一轮响应原样续回模型，让模型继续完成服务器侧采样语义
  - `nil / unknown`: 记为异常终止，并给用户可见错误
- 在 `AgentRound` 增加 `stopReason` 字段，便于 UI 与后续分析

这是当前最缺的一块。否则长任务在边界情况下会表现得不稳定，而且你很难诊断。

### 3.2 工具执行缺少严格失败语义

当前 `executeTool(...)` 返回的只是 `ToolExecutionResult(text, mediaContent)`，调用侧无论结果文本是不是 `Error: ...`，都会把 `ToolCall.status` 标成 `.success`。

这会直接带来三个问题：

- UI 时间线会把失败工具显示成成功
- 模型拿不到明确的结构化失败信号，只能从文本猜
- 后续你无法基于工具失败率做评估与路由优化

成熟做法通常是：**工具结果必须区分 success / error / retryable_error / permission_denied / timeout。**

建议：

- 把 `ToolExecutionResult` 扩展为：
  - `status`
  - `text`
  - `mediaContent`
  - `isRetryable`
  - `metadata`（可选）
- tool result 回传模型时，至少显式包含失败标记，而不是纯文本拼接
- `ToolCall.status` 必须真实反映结果
- 为 bash、web fetch、subagent 分别建错误类别：超时、解析失败、权限拒绝、执行失败、未知异常

如果不先把失败语义做准，后面的“自愈”“重试”“review agent”都会是伪能力。

### 3.3 工具参数解析过于脆弱，缺少 strict schema 和输入校验

现在 `PendingToolUse.parsedInput` 是把 `partialJson` 直接 decode 成字典。失败时静默返回空对象。这种做法在 demo 阶段可以，但生产代理里风险比较高：

- 局部 JSON 不完整时会悄悄退化为空输入
- 模型字段名拼错不会被强制暴露
- 工具实现里大量 `guard let` 后返回文本错误，错误链路太晚

成熟经验是：**工具调用要尽量前置校验，最好让模型永远拿到 deterministic 的 schema error。**

建议：

- 采用更严格的 tool schema 约束，能用 strict tool use 就不要靠宽松字典解析
- 在 tool dispatch 前增加统一 validator
- 解析失败时：
  - `ToolCall.status = .failed`
  - 给模型返回结构化错误：缺失字段、类型错误、JSON 未闭合、非法枚举值
- 为关键工具建立 typed input，而不是所有工具都走同一套动态字典

### 3.4 缺少权限层、策略层、执行层的分离

现在的 loop 基本是假设“只要工具在列表里，就都能执行”。这和成熟 coding agent 的差距很明显。

Claude Code 一类成熟系统，一般至少会分三层：

1. 能力层：有哪些工具
2. 权限层：哪些工具/路径/命令在当前上下文允许执行
3. 策略层：当前模式是 `plan`、`acceptEdits`、`default` 还是 `dontAsk`

你当前子代理虽然做了工具级开关，但还没有真正的 permission model。直接结果是：

- 读写边界不清晰
- bash 命令无白名单/黑名单
- 子代理无法切换到纯 plan 模式
- 缺少“预执行检查 hook”这一层

建议：

- 引入 permission mode：
  - `plan`：只读，不允许 bash / edit
  - `default`：敏感操作需要确认
  - `acceptEdits`：自动接受编辑，但仍限制 bash
  - `dontAsk`：无授权即拒绝
- 给 bash / file edit / web fetch 增加策略检查器
- 把“工具定义”和“工具授权”分离，避免 buildTools 既负责暴露能力又暗含授权
- 为子代理增加 per-agent permission mode，而不只是 `enableTextEditor` / `enableBash`

这一点非常值得做，因为它会直接决定 agentGui 后续能不能从“本地玩具”走到“可分享、可团队使用”的产品层级。

## 4. 借鉴成熟 agent loop 后，建议补齐的关键能力

### 4.1 从“单循环”升级为“状态机”

现在的实现是一个 while-loop。成熟系统通常不会把 agent execution 只看成“下一轮再问模型”，而会显式划分状态：

- `planning`
- `awaiting_tool_results`
- `awaiting_user_input`
- `resuming_after_pause`
- `finalizing`
- `failed`
- `cancelled`

建议不要一上来重构得太大，但至少可以先引入 `AgentLoopState`：

- 当前阶段
- 当前轮次
- stop reason
- 是否等待用户
- 是否允许继续
- 最近一次错误

这样能显著降低后续加特性时的分支复杂度。现在主循环和子代理循环已经有明显重复代码，再继续堆功能会越来越难维护。

### 4.2 把“计划”从提示词约束升级成显式工件

成熟 coding agent 很少只靠 system prompt 让模型“自己有计划”。更稳定的做法是让计划成为一个独立工件：

- todo list
- execution plan
- assumptions
- success criteria

你现在有 `update_todo_list`，这是个不错的起点，但还不够：

- 没有强制在复杂任务开头产出计划
- 没有把计划和执行结果做对账
- 没有在任务完成前做 completion checklist

建议：

- 把复杂任务标准化为：plan -> execute -> verify -> summarize
- 为主代理补一个轻量 `plan_required_if_complex` 策略
- 增加 `verify` 段：要求模型在结束前明确回答“验证做了什么，未验证什么”
- 后续可以考虑单独引入 `planner` 子代理，而不是把计划能力混在主代理里

### 4.3 上下文压缩要从“整段摘要”升级成“分层记忆”

当前压缩策略是把旧消息整体摘要成一段中文文本，再和最近 6 条消息拼接。这会丢掉很多关键结构：

- 为什么做了这个决策
- 哪些文件已经读过
- 哪些命令已经跑过
- 哪些错误已经发生过
- 哪些假设还未验证

成熟经验通常采用分层记忆：

- Working memory：最近几轮原文
- Task memory：当前任务目标、计划、进度
- Semantic memory：稳定事实、项目约定、路径信息
- Episodic memory：本次任务做过什么、失败过什么

建议：

- 压缩输出不止一段摘要，而是结构化为：
  - 用户目标
  - 已完成动作
  - 未完成动作
  - 关键文件/路径
  - 失败与约束
- 主代理和子代理分别压缩，不共用一条简单摘要
- 给子代理支持自动压缩和 resumable transcript，而不是只返回一个最终字符串
- 将 `memory_write` 从“手工写文件”升级为更明确的 memory policy

### 4.4 子代理从“角色提示词”升级到“真正专业化”

当前子代理更多是 prompt template 级别差异，离成熟编排还有几步：

- 所有子代理默认继承同一个模型
- 没有按场景选模型
- 没有 background 执行
- 没有并行 fan-out / fan-in
- 没有 resume 机制
- 没有子代理级 memory

成熟经验通常是：

- Explore 用更快更便宜的模型
- Coder / Reviewer 用更强模型
- 高输出任务放子代理，减少主上下文污染
- 多个独立研究任务并行跑，主代理只做汇总

建议：

- 在 `SubagentDefinition` 中增加：
  - `modelPolicy`（inherit / fast / strong / explicit）
  - `permissionMode`
  - `backgroundable`
  - `supportsResume`
  - `memoryScope`
- 先落地两个高价值场景：
  - `explorer` 使用快模型，只读，支持并发研究
  - `reviewer` 使用强模型，只读，可在代码修改后自动触发
- 后续再考虑“Plan”子代理，而不是先加很多泛化角色

### 4.5 工具执行需要更像任务运行时，而不是函数调用

当前 tool dispatch 还是比较“RPC 风格”：调用、等结果、拼回文本。成熟 agent runtime 一般会补这些能力：

- timeout
- retry policy
- cancellation
- idempotency key
- structured logs
- permission check
- pre / post hooks

尤其 bash 工具，现在虽然有 session 和 timeout，但仍然缺少：

- 命令级权限策略
- 长任务与短任务的差异化处理
- 背景进程管理
- stdout / stderr 分离语义
- exit code 结构化回传

建议：

- 为 bash 结果增加：`stdout`、`stderr`、`exitCode`、`timedOut`
- 为 tool dispatch 引入统一包装层 `runToolWithPolicy(...)`
- 在统一包装层处理：超时、重试、取消、权限、记录、错误分类
- 为 web 和 bash 工具预留 hooks，方便之后做安全检查和自动验证

### 4.6 缺少“结束前验证”闭环

当前 loop 更像“模型说它做完了，就结束”。成熟 coding agent 一般至少有一个 lightweight verifier：

- 如果改了代码，是否跑过测试 / build / lint
- 如果没跑，是否明确告诉用户没验证
- 如果执行了工具，是否检查结果是否真的成功

建议：

- 在主代理结束前，增加一个 verifier step
- 简化版可以只做策略判断：
  - 编辑过文件且项目可构建 -> 优先建议运行验证
  - 如果没有验证，最终消息里必须显式披露
- 更进一步可以引入独立 reviewer / verifier 子代理

这项能力对“用户是否信任 agent”影响很大。

## 5. 代码层面的具体问题与落点

### 5.1 `ClaudeService+AgenticLoop.swift`

建议重点改这里：

- 给主循环加入 `maxRounds`
- 处理 `pause_turn` / `max_tokens` / unknown stop reason
- 抽出统一的 round event 聚合逻辑，避免主代理和子代理重复
- 工具结果改为结构化 success/failure
- 把 `assistantObjects` / `toolResultObjects` 的构建从 loop body 里抽出来

这里最适合抽出两个对象：

- `LoopTurnCollector`：负责聚合 streaming 事件
- `LoopContinuationPolicy`：负责根据 stop reason 决定下一步

### 5.2 `ClaudeService+Subagent.swift`

建议重点改这里：

- 不要简单复制主循环逻辑，尽量复用统一 runtime
- 给子代理补 model policy 和 permission mode
- 为子代理增加 resume / compact / background 的扩展点
- 子代理返回结果不应只有纯文本，最好包含：摘要、关键发现、是否成功、是否需人工介入

### 5.3 `ClaudeService+ContextCompression.swift`

建议重点改这里：

- 摘要格式结构化
- 压缩阈值和最近消息条数配置化
- 区分主代理与子代理的压缩策略
- 为压缩前后记录 token、轮次、触发原因，便于调优

### 5.4 `ClaudeService+ToolDispatch.swift`

建议重点改这里：

- 把工具错误从字符串提升为类型化结果
- 增加统一 policy wrapper
- 给 `ask_user_question` 增加超时或取消后状态标签
- `memory_write` 也要明确 success/failure，不要只靠字符串

### 5.5 `BashSession.swift`

建议重点改这里：

- 保留 `exit code`
- 分离 stdout / stderr
- 支持后台命令
- 支持更细粒度 timeout 配置
- 对超长输出提供截断说明，而不是只保留尾部

## 6. 推荐的演进路线

### Phase 1：先把 runtime 稳定性补齐

目标：让 loop 更可控、更可诊断。

建议本阶段完成：

- 主循环 `maxRounds`
- stop reason 完整处理
- `ToolExecutionResult` 结构化
- `ToolCall.status` 准确化
- bash 返回 `exitCode`
- `AgentRound` 记录 `stopReason`

这是最值得先做的一期。

### Phase 2：补权限和计划能力

目标：让 agent 从“能跑”变成“可控地跑”。

建议本阶段完成：

- permission mode
- 复杂任务默认先计划
- plan / execute / verify 结束闭环
- 子代理 permission mode
- pre-tool policy hooks

### Phase 3：补上下文和子代理成熟能力

目标：让长任务和复杂任务变得可靠。

建议本阶段完成：

- 结构化压缩
- 子代理 resume
- 子代理 background 执行
- 并行 research fan-out / fan-in
- 子代理 model routing

### Phase 4：补评估和自动优化

目标：让系统进入可持续优化阶段。

建议本阶段完成：

- trace / round / tool metrics
- 失败类型统计
- 常见任务基准集
- verifier / reviewer 自动化
- prompt / routing / tool schema A/B 对比

## 7. 我最推荐的三项立即行动

如果只做三件事，我建议按这个顺序：

1. **补 stop reason + maxRounds + tool failure 语义**
   这是稳定性的底座，不做这一步，后面所有高级能力都会建立在不可靠的执行流上。

2. **把工具执行升级为统一 runtime wrapper**
   让 timeout、权限、错误分类、记录逻辑集中处理，避免每个工具各写一套。

3. **把上下文压缩改成结构化 task memory**
   这会显著提升长任务表现，也会让子代理和主代理的协作更稳。

## 8. 总结

当前 agentGui 的 agent loop 已经有了一个可运行的基本骨架，但它更像“单线程 while-loop + tool dispatch”，还没有完全进化成成熟 agent runtime。

和先进实现相比，最主要的差距不是“工具不够多”，而是下面四件事还不够强：

- 停止/恢复状态机
- 权限与策略分层
- 结构化失败语义
- 分层上下文管理

只要优先把这四块补起来，这套架构就能从“可演示”明显提升到“可长期演进”。

如果后续要继续落地，我建议下一份文档直接写成实施方案，题目可以是：

`docs/agent-loop-runtime-refactor-plan.md`

内容聚焦：runtime 状态机、tool result 类型、permission mode、structured compression 四个改造包。