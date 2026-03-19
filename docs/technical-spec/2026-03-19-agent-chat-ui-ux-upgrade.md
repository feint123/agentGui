# 2026-03-19 Agent 对话 UI/UX 升级方案

日期：2026-03-19

关联对象：`ChatView`、`ChatView+MessageList`、`MessageBubbleView`、`AgentMessageStepFlowView`、`ThinkingBubbleView`、`ToolCallBubbleView`、`SubagentTimelineView`、`AgentMessageFlowPresentation`、`MessageRowSnapshot`

## 0. 文档结论

当前聊天页最大的问题不是“信息不够”，而是“把运行时执行痕迹直接当成了最终对话 UI”。这会让 agent 看起来像一个实时日志面板，而不是一个会执行、会交付结果、会沉淀产物的产品化助手。

我建议将当前聊天页升级为一个双层界面系统：

1. 运行时使用 `Execution Theater` 展示思考、工具调用、子代理协作与验证进度，但这些内容默认属于短暂态，不直接沉积为主对话正文。
2. 完成后自动折叠为 `Narrative Transcript`，仅保留用户真正关心的结果叙事、关键变更文件、引用链接、测试结论与风险提示。
3. 详细执行轨迹继续存在，但退到二级或三级信息层，作为审计与深查入口，而不是主聊天流默认结构。
4. 思考与工具调用不再以“逐条事件气泡”暴露，而以阶段化、编舞化、带动效的执行状态呈现，强调“系统正在工作”而不是“系统正在刷日志”。

如果只用一句话概括本次升级：

> 把 agent 聊天从“执行日志可视化”升级为“结果叙事 + 运行舞台 + 产物抽屉”的三层体验。

## 1. 问题诊断

结合当前实现与目标体验，现状问题集中在五个方面。

### 1.1 主消息流承载了过多中间态

当前 `AgentMessageStepFlowView` 直接把 `thinking`、`tool`、`subagent`、`result` 作为同级步骤串进主消息体。结果是：

1. 用户每次阅读回复都要穿过一段执行轨迹。
2. 思考、工具、结果都共享同一视觉优先级。
3. 执行中体验像 debug trace，完成后体验仍像 debug trace。

### 1.2 “可见性”被实现成了“原样暴露”

从产品目标看，用户需要知道系统在做事，但不需要阅读每个中间动作。当前 UI 里：

1. `ThinkingBubbleView` 仍是可展开原文块。
2. `ToolCallBubbleView` 仍按单次调用粒度展示。
3. `SubagentTimelineView` 仍按 round 级别暴露内部过程。

这满足了工程可观测性，但没有完成面向终端用户的 UX 抽象。

### 1.3 结果、证据、产物没有被清晰分层

用户最终真正需要的通常只有三类东西：

1. 对话答案本身。
2. 改了哪些文件、引用了哪些文件、跑了哪些验证。
3. 如果失败，失败卡在哪里、下一步建议是什么。

当前这些内容被混在步骤流中，缺少一个稳定的“交付面”。

### 1.4 执行节奏缺少语义编排

现在的动画更多是普通折叠、出现、列表追加。问题不是动画少，而是动画没有承担语义：

1. 用户难以一眼看出当前处于哪个阶段。
2. 用户感知不到子任务之间的接力关系。
3. 完成时没有“收束”动作，导致界面始终像在流动，不像一次交付已经结束。

### 1.5 主聊天记录缺少长期可读性

对话历史应该越看越简洁，而不是越长越像流水账。当前设计会随着轮数增加持续堆积中间细节，降低：

1. 历史回看效率。
2. 结果复盘效率。
3. 多轮任务上下文的可恢复性。

## 2. 外部研究与设计启发

本方案不是主观审美改版，而是基于近两年 agent、HCI 与产品交互信号的归纳。

### 2.1 Anthropic：透明不等于暴露全部内部文本

Anthropic 在《Building effective agents》中强调三点：保持系统简单、显式呈现规划步骤、重视 agent-computer interface。这里真正值得吸收的是：

1. 用户需要感知 agent 的计划与进展。
2. 进展应绑定环境反馈与工具结果，而不是堆叠抽象“思考中”。
3. 透明的重点是结构透明，不是原样输出内部脑内独白。

### 2.2 OpenAI：trace 很重要，但主要是 observability 基础设施

OpenAI 2025 年关于 agents 的产品方向，把 tracing、streaming event、handoff、observability 明确做成平台能力。这给 UI 的启发很明确：

1. 轨迹是必需品。
2. 轨迹不等于主对话内容。
3. 面向用户的界面应消费 trace 的投影，而不是直接渲染 trace 本身。

### 2.3 Google Canvas / Agent Designer：对话不该吞掉工作空间

近年的生成式产品越来越倾向双表面或多表面设计：

1. chat 负责意图与反馈。
2. workspace 负责中间产物与可视化执行。
3. preview / artifact pane 负责结果检查与二次编辑。

这正适合 coding agent，因为代码修改、文件引用、测试验证天然不是一条聊天气泡能承载干净的。

### 2.4 HCI 趋势：从 explainable AI 转向 interactive AI

最新综述普遍不再满足于“解释系统为什么这么做”，而更强调：

1. 用户能否随时理解当前状态。
2. 用户能否在关键节点介入。
3. 用户能否在需要时下钻细节，而不是被迫消费全部细节。

这意味着最佳方案不是全隐藏，也不是全展开，而是 progressive disclosure。

### 2.5 Multi-agent 研究：用户更关心分工与收敛，不关心每条内部对话

关于多代理交互的最新研究反复证明：

1. 用户真正需要的是“谁在负责什么”。
2. 用户需要看到任务接力、冲突和收敛。
3. 用户通常不需要阅读每个 worker 的全部微观过程。

因此，subagent UI 应该从“嵌套时间线”升级为“委派卡 + 状态编排 + 最终贡献摘要”。

### 2.6 经典 HAI 原则仍然成立

虽然《Guidelines for Human-AI Interaction》不是新论文，但其原则在 agent 时代反而更重要：

1. 持续告知系统状态。
2. 在高风险操作前提供合适的控制点。
3. 对失败给出可恢复路径。
4. 对不确定性做语义化表达。

## 3. 设计目标

本轮升级应明确追求以下六个目标。

### 3.1 结果优先

完成后主聊天流应优先展示结果与产物，不再以过程为主。

### 3.2 过程可见但不扰人

执行中让用户感知 agent 正在工作、工作到哪里、是否遇到阻塞；完成后自动退场。

### 3.3 产物可操作

改动文件、引用链接、测试结论、命令摘要、生成物预览都应成为独立可点对象，而不是埋在正文或步骤流里。

### 3.4 子代理协作可感知

用户应看到 delegation、ownership、handoff、merge，而不是一个个嵌套日志窗口。

### 3.5 历史对话可回看

五十轮后仍能快速扫读每一轮交付了什么，而不是重新阅读所有过程细节。

### 3.6 研发侧仍保留审计深度

不牺牲工程可观测性，只改变默认投影层级。

## 4. 新的体验模型

我建议将 agent 对话重构为三个彼此独立但可联动的表面。

### 4.1 第一层：`Narrative Transcript`

这是主聊天流，也是默认长期保存层。

每条 agent 消息完成后只保留四个模块：

1. `Answer Block`：自然语言答案或交付说明。
2. `Artifact Shelf`：改动文件、引用文件、链接、生成物、测试结果。
3. `Execution Digest`：一句到两句的执行摘要，例如“检查 8 个文件，修改 3 个文件，验证 12 个测试全部通过”。
4. `Risk Footer`：仅在失败、待确认、验证不足时显示。

原则是：

1. 最终消息必须像一份交付，而不是回放。
2. 读完一屏就能知道这轮做了什么。

### 4.2 第二层：`Execution Theater`

这是运行时面向用户的可视化执行舞台，可嵌在消息顶部，也可悬浮为消息内的 live panel。

其职责不是讲完整过程，而是展示“正在发生什么”。

建议用阶段而不是工具列表组织：

1. `理解任务`
2. `检查代码`
3. `生成变更`
4. `运行验证`
5. `整理交付`

每个阶段内再映射活动卡片，例如：

1. 正在检查哪些文件。
2. 正在执行哪个终端任务。
3. 哪个 subagent 正在负责哪块工作。
4. 哪个验证步骤已完成。

### 4.3 第三层：`Audit / Deep Trace`

这是深度展开层，用于：

1. 工具调用详情。
2. 原始输出。
3. 子代理完整 round。
4. 失败诊断上下文。

它应该默认隐藏，通过 “查看执行细节” 进入，而不应直接占据主消息体。

## 5. 核心概念方案

本次升级建议采用一个明确的产品概念名：`Cinematic Execution`。

核心不是炫技，而是把执行过程设计成一段有节奏、有层次、有收束的体验。

### 5.1 运行时像舞台，不像终端

当 agent 工作时，界面重点展示：

1. 当前阶段。
2. 正在活跃的任务卡。
3. 新证据到达。
4. 任务切换与交接。

不再默认铺满：

1. 连续的 thinking 文本。
2. 每个 tool call 的独立卡片。
3. subagent 的逐轮消息。

### 5.2 完成后有明确“收束”动作

当执行完成时，`Execution Theater` 应出现一个显式的 settle transition：

1. 活动阶段条停止流动。
2. 各活动卡折叠为简短摘要。
3. 摘要被并入 `Execution Digest`。
4. `Artifact Shelf` 从底部浮现为最终可交付区域。

这个动作很关键。它会告诉用户：“过程结束了，现在请看结果。”

### 5.3 产物成为主角

在 coding agent 中，真正的价值对象不是“工具调用本身”，而是：

1. 改动文件。
2. 引用文件。
3. 测试结果。
4. 运行命令摘要。
5. 外部链接或资料来源。

所以结果卡片的视觉重心应落到这些对象上。

## 6. 信息架构

建议将单条 agent 消息改为以下结构。

```text
Agent Message
├── Header
│   ├── Agent identity
│   ├── current / final phase
│   └── status chip
├── Execution Theater (runtime first, settles after completion)
│   ├── phase ribbon
│   ├── live task cards
│   ├── subagent constellation
│   └── verification pulse
├── Answer Block
├── Artifact Shelf
│   ├── changed files
│   ├── referenced files
│   ├── links / citations
│   ├── commands summary
│   └── tests / verification summary
├── Execution Digest
└── Expand to Audit Trace
```

信息优先级应固定为：

1. `结果`
2. `产物`
3. `执行摘要`
4. `深度轨迹`

而不是当前的：

1. `执行步骤`
2. `执行步骤`
3. `执行步骤`
4. `结果`

## 7. 动效系统设计

你明确希望用“炫酷动画效果”承接思考和工具调用，但这里必须强调：高级感来自语义动画，而不是动画数量。

### 7.1 阶段带：`Phase Ribbon`

在 agent 消息头部增加一条窄而精致的阶段带。它不是常规 spinner，而是一个会在阶段节点之间流动的 ribbon。

建议状态：

1. `Framing`
2. `Inspecting`
3. `Editing`
4. `Running`
5. `Verifying`
6. `Delivering`
7. `Blocked`

动效原则：

1. 活跃阶段有缓慢流动的高光。
2. 已完成阶段变为低对比实体点。
3. 阻塞阶段使用压抑但克制的脉冲，不要泛红闪烁。

### 7.2 活动卡：`Live Task Cards`

执行中不渲染长日志，而渲染少量高价值活动卡：

1. `Inspecting 6 files`
2. `Editing ContentView.swift`
3. `Running Quality Smoke`
4. `Waiting for approval`

卡片行为：

1. 活跃卡微呼吸。
2. 新卡进入时带有轻微上浮和聚焦。
3. 完成卡在 1 到 2 秒后自动 fold-back 成一行摘要。

### 7.3 证据到达：`Evidence Arrival`

每当文件、diff、测试结果、链接被确认，应采用“对象进入抽屉”的动画：

1. 文件 chip 从活动卡滑入 `Artifact Shelf`。
2. 测试结果从验证卡沉入验证摘要区。
3. 引用链接从搜索卡过渡到引用栏。

这样用户看到的不是日志追加，而是成果逐步被收纳。

### 7.4 子代理编舞：`Subagent Constellation`

不要让 subagent 继续以嵌套 timeline 存在。建议改成一组短时态协作节点：

1. 每个 subagent 是一个 capability node。
2. 激活时沿主任务节点发出一条细连接线。
3. 完成后只留下贡献摘要，例如“完成代码库扫描”“完成测试验证”。

用户看到的是编排，而不是嵌套对话。

### 7.5 完成收束：`Settle Transition`

当消息完成时，整段动态区域进入收束：

1. phase ribbon 停止。
2. live card 折叠。
3. artifact shelf 稳定展开。
4. answer block 获得视觉聚焦。

这是整个体验最关键的一步，它决定产品像“作品”还是像“日志”。

## 8. 组件级重构建议

下面的建议尽量贴合当前实现，不从零推翻。

### 8.1 `AgentMessageStepFlowView` 从步骤列表改为双投影容器

当前它只是把 `result / thinking / tool / subagent` 顺序渲染出来。建议改造成：

1. `LiveProjectionView`：执行中呈现 `Execution Theater`。
2. `SettledProjectionView`：完成后呈现 `Answer Block + Artifact Shelf + Execution Digest`。
3. `AuditProjectionView`：点开后再查看逐步详情。

这意味着 `AgentMessageFlowSnapshot` 不应只保存“步骤序列”，还应提供按场景计算好的投影数据。

### 8.2 `ThinkingBubbleView` 改为短暂态执行信号

不要再把 thinking 默认看作一段会长期留在消息中的正文。它更适合变成：

1. 运行时的 `Reasoning Signal`。
2. 阶段卡内的一行摘要。
3. 可选展开的审计内容。

换言之，thinking 应是 runtime affordance，不是 transcript block。

### 8.3 `ToolCallBubbleView` 改为“活动卡 + 详情抽屉”

建议按工具类型做两层投影：

1. 一级层只显示语义摘要，例如“搜索 4 个匹配文件”“执行 Quality Smoke”。
2. 二级层才显示输入、输出、终端内容和状态细节。

这也更符合仓库里既有方向：不同工具类型应有操作特定 UI，但不必全部直出在主消息体。

### 8.4 `SubagentTimelineView` 改为贡献卡片

建议把 round 级时间线下沉到 audit 层，主消息内只展示：

1. 子代理名称。
2. 负责任务。
3. 当前状态。
4. 最终贡献。

例如：

1. `代码库扫描器`：已完成，识别 12 个相关文件。
2. `验证器`：已完成，Smoke 通过。

### 8.5 `MessageRowSnapshot` / `AgentMessageFlowSnapshot` 扩展为三类投影数据

建议新增：

1. `ExecutionProjection`
2. `TranscriptProjection`
3. `ArtifactProjection`

而不是把所有信息都压进一个 `steps` 数组再由视图层猜测如何展示。

## 9. 数据模型建议

如果要让 UI 稳定落地，建议在展示模型层引入新的语义对象。

### 9.1 阶段模型

```text
ExecutionPhase
- framing
- inspecting
- editing
- running
- verifying
- delivering
- blocked
```

### 9.2 活动卡模型

```text
LiveTaskCardPresentation
- id
- phase
- title
- subtitle
- icon
- status
- progressStyle
- relatedArtifacts
- relatedToolCallIDs
```

### 9.3 产物抽屉模型

```text
ArtifactShelfPresentation
- changedFiles
- referencedFiles
- citations
- generatedAssets
- testSummaries
- commandSummaries
```

### 9.4 收束摘要模型

```text
ExecutionDigestPresentation
- headline
- inspectedFileCount
- editedFileCount
- commandCount
- verificationSummary
- subagentContributionSummary
- outstandingRisk
```

### 9.5 细节展开策略

```text
DisclosurePolicy
- runtimeVisible
- settleCollapsed
- auditExpandable
- developerModePinnedOpen
```

## 10. 关键交互规则

### 10.1 默认不展示长 thinking 原文

只显示简明推理摘要，例如：

1. `正在比较两个实现路径`
2. `正在定位配置来源`
3. `正在等待测试结果决定下一步`

### 10.2 默认不展示逐条工具输出

只展示工具语义结果，例如：

1. `已检查 6 个 Swift 文件`
2. `已更新 3 个视图组件`
3. `已运行 Quality Smoke，全部通过`

### 10.3 默认展示文件与引用对象

最终交付应总是突出：

1. 修改过的文件。
2. 参考过的文件或网页。
3. 验证命令与结果。

### 10.4 默认显示阻塞与用户授权边界

像以下状态必须在主层可见：

1. 等待用户批准。
2. 验证失败。
3. 子代理冲突未收敛。
4. 结果存在未验证假设。

### 10.5 多轮历史默认保留收束态

旧消息一律以 settled 形态展示，不再回到 live trace 展开态。

## 11. 视觉语言建议

### 11.1 气质方向

目标不是聊天软件，也不是终端模拟器，而是“精密工作台”。

建议关键词：

1. `calm`
2. `confident`
3. `instrumented`
4. `premium`
5. `editor-native`

### 11.2 颜色语义

避免大面积警告色与彩虹色区分工具。建议：

1. 中性石墨色作为底。
2. 单一品牌高亮用于活跃阶段。
3. 绿色只给 verified outcome。
4. 琥珀色只给 attention / approval / risk。

### 11.3 图标语义

每类动作给稳定图标：

1. `inspect`：文档 / 放大镜。
2. `edit`：笔 / diff。
3. `run`：终端 / play。
4. `verify`：check / shield。
5. `delegate`：network / nodes。

### 11.4 密度控制

一条 agent 消息在完成态下，首屏只应该出现：

1. 一段答案。
2. 一排产物。
3. 一段摘要。

不要让用户首屏看到 8 个步骤卡。

## 12. 与现有仓库方向的关系

这个方案并不是推翻已有设计方向，而是对其做用户层抽象。

### 12.1 保留执行顺序语义

既有方向强调 execution-order-first。这个判断仍然成立，但执行顺序应主要体现在 `Execution Theater` 中，而不是长期霸占主 transcript。

### 12.2 保留 thinking / tool / subagent 的可见性

它们仍然可见，只是：

1. 从正文层退到运行层。
2. 从默认展开退到自动折叠。
3. 从原始事件退到语义摘要。

### 12.3 保留工具特定 UI

工具仍应按 read、edit、execute、search 等类别有不同投影，但优先在 live card 与 artifact shelf 中表达，而非统一渲染成结构相似的 bubble。

## 13. 分阶段落地方案

### Phase 1：投影层重构

目标：先把信息层级理顺，不急于做全部动效。

1. 为 `AgentMessageFlowPresentation` 增加 `live`、`transcript`、`artifact` 三类 projection。
2. 把 `AgentMessageStepFlowView` 改为双层结构。
3. 新增 `ExecutionDigest` 与 `ArtifactShelf`。
4. 完成态默认折叠 thinking、tool、subagent。

### Phase 2：运行舞台与语义动画

目标：把执行中体验从“列表追加”升级为“阶段编舞”。

1. 增加 `Phase Ribbon`。
2. 增加 `Live Task Cards`。
3. 增加 `Evidence Arrival` 动画。
4. 增加 `Settle Transition`。

### Phase 3：Subagent 可视化升级

目标：把嵌套 timeline 改造成能力协作图。

1. 增加 `Subagent Constellation`。
2. 主层仅保留贡献摘要。
3. 细节 timeline 下沉到 audit panel。

### Phase 4：评估与个性化视图

目标：让不同用户看到合适的信息密度。

1. 增加 `Compact / Standard / Developer` 三种 disclosure preset。
2. 验证默认模式下的理解成本与满意度。
3. 为高频开发者保留“固定展开 audit”的能力。

## 14. 成功指标

本方案不能只看审美反馈，必须有量化指标。

### 14.1 体验指标

1. 用户理解当前状态的时间下降。
2. 单条 agent 消息的首屏阅读时间下降。
3. 历史消息回看效率提升。

### 14.2 结果感知指标

1. 文件产物点击率上升。
2. 引用链接点击率上升。
3. 测试结果被理解的正确率上升。

### 14.3 干扰度指标

1. 用户主动展开深度轨迹的比例低于当前默认暴露比例。
2. 用户对“消息像日志”的主观反馈显著下降。

### 14.4 可信度指标

1. 用户能清楚判断是否已经修改文件。
2. 用户能清楚判断是否已经验证。
3. 用户能清楚判断是否还在等待自己决策。

## 15. 风险与边界

### 15.1 不能把 agent 做成黑箱

折叠不等于隐藏责任。审计入口必须清晰可达。

### 15.2 不能只做视觉包装

如果底层仍是事件列表，只在外面套一层卡片，最终仍会退化成“换皮日志”。必须先升级 projection model。

### 15.3 动画必须服务状态理解

任何纯装饰性动画都应该被拒绝。动效只有在帮助用户判断阶段、进度、切换、完成时才有价值。

### 15.4 失败态比成功态更重要

真正考验这个方案的不是顺利完成，而是：

1. 测试失败。
2. 工具卡住。
3. 子代理分歧。
4. 等待授权。

这些状态必须比当前更清楚，而不是被美化掉。

## 16. 最终建议

如果只选一个最重要的产品判断，我的建议是：

> 主聊天流只保留结果叙事与产物，执行过程改为运行时舞台化展示，完成后自动收束。

对 agentGui 而言，这不是一次纯视觉升级，而是一次“消息投影模型重构”。

一旦完成这件事，你的聊天页会从：

1. `像工程师看日志`

变成：

1. `像用户看一个会思考、会执行、会交付的专业助手`

## 17. 参考研究与产品信号

1. Anthropic, `Building effective agents`, 2024-12。
2. OpenAI, `New tools for building agents`, 2025-03。
3. Google 系列 workspace / canvas / agent designer 产品方向，2025。
4. `From Explainable to Interactive AI` 相关综述，2024。
5. `AI Assistance for UX: A Literature Review Through Human-Centered AI`，2024。
6. `From Conversation to Orchestration: HCI Challenges and Opportunities in Interactive Multi-Agentic Systems`，2025。
7. `Guidelines for Human-AI Interaction`, CHI 2019。

这些材料共同指向同一结论：

1. agent 必须对状态透明。
2. 透明应优先呈现结构化进展与环境证据。
3. 最终 transcript 应服务长期可读性，而不是保留全部短暂执行痕迹。