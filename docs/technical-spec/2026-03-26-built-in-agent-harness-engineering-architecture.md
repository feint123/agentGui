# agentGui built-in agent Harness Engineering 增强设计

日期：2026-03-26

## 1. 文档目标

本文档回答的问题是：

> 如何借鉴 “Harness Engineering / Harness Engineer” 这一新兴工程范式及其相关论文、工程实践，增强 agentGui 当前 built-in agent 的稳定性、持续作业能力、验证能力、恢复能力和自我改进能力？

本文档覆盖：

1. Harness Engineering 的概念澄清：它是什么，不是什么。
2. 相关论文与工程实践的核心思想。
3. 当前 agentGui built-in agent 的已有能力与关键缺口。
4. 一个面向 agentGui 的 built-in harness 增强架构。
5. 分阶段演进建议、风险与验证策略。

非目标：

1. 本文档不直接实现代码。
2. 本文档不讨论 ACP provider 的完整 harness 统一化，只聚焦 built-in agent。
3. 本文档不把“多 agent team”作为 v1 必达范围，但会说明如何为其预留边界。

## 2. 结论先行

结论可以先浓缩成一句话：

> 对 built-in agent，最值得提升的不是单次 prompt 或单个模型，而是围绕 `runCoreAgentLoop` 建立更完整的 harness：会话启动脚手架、环境上下文注入、验证闭环、失败记忆、技能与工件复用、轨迹分析、预算与阶段控制。

更具体地说：

1. **Harness Engineering 更像工程方法论，而不是单一算法**
   它强调把 agent 的能力建立在模型外围的控制系统上：context、tooling、verification、memory、observability、recovery。
2. **当前 built-in agent 已经具备 harness 雏形**
   `runCoreAgentLoop`、hooks、tool coordinator、business observability、verification state、memory bootstrap、subagent 都是现成资产。
3. **当前最大缺口不在“能不能调用工具”，而在“能不能持续可靠地完成复杂任务”**
   具体体现为：启动脚手架不足、验证责任不够强、长期工件不够结构化、失败经验难沉淀、trace 驱动的 harness 改进闭环还没有系统化。
4. **最值得借鉴的外部思想**
   - ReAct：显式推理-行动交替
   - Reflexion：语言化失败反馈与 episodic memory
   - Voyager：技能库与可复用执行工件
   - SWE-agent：专门为 agent 设计的 agent-computer interface
   - Anthropic long-running harness：initializer / progress artifact / feature list / clean handoff
   - LangChain harness iteration：用 trace 分析驱动 harness 升级
5. **对 agentGui 的建议**
   把 built-in agent 从“强 loop”升级为“强 harness”：加入 initializer / session brief、structured progress ledger、verification contract、recovery checklist、skill artifact store、trace analyzer 和阶段化 budget policy。

## 3. 概念澄清：什么是 Harness Engineering

### 3.1 工作定义

“Harness Engineering” 目前更接近一个正在成形的行业工程术语，而不是已经被学界统一定义的正式研究分支。

结合 OpenAI、Anthropic、LangChain、Thoughtworks/Fowler 等工程语境，一个比较稳妥的定义是：

> Harness Engineering 是围绕模型构建执行控制层的工程工作。其目标不是改变模型权重，而是通过上下文管理、工具接口、验证闭环、运行时控制、持久工件、反馈与观测体系，把模型的“原始智能”约束和放大为可持续、可恢复、可验证的 agent 行为。

### 3.2 它不是什么

Harness Engineering 不是：

1. 只写 system prompt。
2. 单纯加几条 rules markdown。
3. 单纯做 tool calling。
4. 单纯加日志。
5. 单纯做 benchmark。

它真正关心的是：**如何让 agent 在复杂环境里长期、稳定、低熵地工作。**

### 3.3 一个可操作的五层视角

结合外部工程总结与本项目现状，harness 可以拆成五层：

1. **Orchestration**
   决定何时调用模型、何时调用工具、何时继续、何时停机、何时重试。
2. **Context Management**
   决定每个阶段该给模型什么上下文，以及如何在多轮/多会话中维持连续性。
3. **Tool / Environment Interface**
   决定 agent 如何安全、可靠、可解释地操作 bash、文件、LSP、subagent 等外部能力。
4. **Verification**
   决定 agent 如何证明“它做对了”，而不是只证明“它觉得自己做对了”。
5. **Operations / Feedback**
   决定如何观测失败模式、回收慢路径、管理预算、分析 trace、迭代 harness。

## 4. 相关理论、论文与工程实践

### 4.1 ReAct：推理与行动交错

`ReAct`（Yao et al., 2022）提出把 reasoning trace 与 external action interleave 到一个统一轨迹中。其关键贡献不是“让模型会思考”，而是：

1. 让模型在行动前后显式更新其推理状态。
2. 让环境反馈成为后续推理的一部分。
3. 减少纯 chain-of-thought 脱离环境漂移的问题。

对 agentGui 的启示：

1. 当前 built-in loop 已经具备 ReAct 形态，但“阶段语义”仍可更显式。
2. `planning -> acting -> verifying -> fixing` 应成为 host 支持的一等阶段，而不是只由 prompt 暗示。
3. 对 stop reason、tool result、verification frontier 的 host-level 结构化建模，是 harness 比 prompt 更重要的部分。

### 4.2 Reflexion：语言化反馈与 episodic memory

`Reflexion`（Shinn et al., 2023）提出语言化 reinforcement：不更新权重，而把环境反馈总结成可复用的文字经验，并在后续尝试中注入。

其关键思想：

1. 失败后不只是 retry，而是生成“为什么失败、下次怎么改”的可消费记忆。
2. 反馈可以来自测试、执行环境、启发式规则或 agent 自评。
3. 经验必须是可回读、可引用、可压缩的。

对 agentGui 的启示：

1. 当前已有 reflection、verification、epistemic inputs、sessionExecutionEvidence，这些可以演进成更明确的 `failure memory`.
2. built-in agent 需要的不只是“结束前反思”，还需要“基于失败类型的结构化 lessons”。
3. 这些 lessons 应按 session / workspace / task pattern 分层存储，而不是只作为一次性文本存在消息里。

### 4.3 Voyager：技能库、自动课程与可复用程序

`Voyager`（Wang et al., 2023）提出三件事同时成立：

1. 自动课程（automatic curriculum）
2. 技能库（ever-growing skill library）
3. 结合环境反馈和自验证的迭代程序改进

它的价值在于说明：对于长程 agent，单次推理不如**持续积累可复用技能与工件**。

对 agentGui 的启示：

1. 当前 built-in agent 的 skill 更像 prompt-time capability，而不是执行后沉淀的 runtime asset。
2. 可以把高价值工件抽出来：
   - session brief
   - project checklist
   - verification recipe
   - recovery script
   - successful subagent template
3. “技能”不一定是新模型能力，也可以是被 host 管理的结构化流程资产。

### 4.4 SWE-agent：面向 agent 的专用接口层

`SWE-agent`（Yang et al., 2024）最值得借鉴的不是“又一个 coding agent”，而是它把 ACI（agent-computer interface）作为核心贡献：

1. 文件导航更可控。
2. 编辑与测试路径更 agent-friendly。
3. 环境操作被约束在更可预测的接口上。

对 agentGui 的启示：

1. built-in agent 的 `bash`、`view`、`lsp`、`subagent`、memory、verification 目前是“功能齐全但接口风格分散”。
2. 未来应逐步收敛成面向 agent 的高层 ACI，而不只是把原始工具暴露给模型。
3. 尤其要增强：
   - structured workspace onboarding
   - deterministic verification command surfaces
   - structured progress & checkpoint surfaces

### 4.5 Anthropic：long-running agent harness

Anthropic 的 `Effective harnesses for long-running agents` 明确指出，仅靠 compaction 不足以让 agent 跨多个 context window 稳定推进。其解决方案的关键词是：

1. initializer agent
2. feature list / tests list
3. progress log
4. init script
5. 每次会话只做增量工作并留下干净 handoff

对 agentGui 的启示非常直接：

1. 当前 built-in agent 在长任务里已经有 hook / memory / verification，但缺少稳定的**session bootstrapping ritual**。
2. 需要在会话开始时自动或半自动建立：
   - 当前项目状态摘要
   - 最近 progress
   - 待验证 frontier
   - 推荐启动命令 / 环境健康检查
3. 需要让 host 主动支持“留交接文档”，而不完全依赖模型自发写总结。

### 4.6 LangChain：trace-driven harness iteration

LangChain 关于 harness engineering 的文章最重要的观点是：

> 分数提升不一定来自换模型，而经常来自 trace analysis、self-verification、context delivery 和 middleware 改进。

它强调：

1. 用 traces 找 failure modes，而不是凭感觉改 prompt。
2. 把 trace analysis 做成可重复工作流。
3. harness 的优化要围绕真实失败模式。

对 agentGui 的启示：

1. 当前已有 `BusinessObservability`、Hook pipeline、ExecutionEvidence，这些非常适合做 trace analysis 基础。
2. 缺的不是日志，而是**面向 harness 改进的 trace reducer / failure taxonomy / experiment loop**。
3. built-in agent 应能回答：
   - 它为什么失败最多？
   - 失败前常见轨迹是什么？
   - 哪些工具组合最容易导致 doom loop？
   - 哪些 verification guard 真正提升成功率？

## 5. 当前 built-in agent 现状评估

### 5.1 已有能力

当前 built-in agent 已经不算“裸模型调用”，而是有一套相当成熟的 harness 雏形：

1. **统一执行内核**
   `runCoreAgentLoop -> AgentLoopRunner -> AgentLoopRoundExecutor`
2. **hook 体系**
   built-in hooks 已覆盖 observability、memory bootstrap、tool audit、stream projection、failure classification 等。
3. **工具协调器**
   `AgentLoopToolExecutionCoordinatorBuilder` 管理工具执行、审批、bash 观察、subagent。
4. **结构化观测**
   已有 business observability、performance monitor、tool call、round 持久化。
5. **验证相关资产**
   已有 verifier loop、verification state、completion verification、execution evidence。
6. **记忆与上下文资产**
   有 unified memory bootstrap、epistemic inputs、session-scoped execution evidence。

结论：

> agentGui 当前 built-in agent 的问题不是“没有 harness”，而是“harness 还不够完整、还不够 productized、还没形成稳定的长期作业协议”。

### 5.2 关键缺口

对照前述研究，当前主要缺口是：

#### A. 缺少显式的 session initializer / brief 机制

目前 loop 会启动，但缺少统一的“开工仪式”：

1. 当前项目状态摘要
2. 最近进展摘要
3. 当前验证 frontier
4. 推荐启动检查
5. 当前预算与目标阶段

#### B. 缺少结构化 progress artifact

当前 progress 更分散在 message、tool call、memory 和观测日志中，不够适合作为下一个上下文窗口的 handoff artifact。

#### C. 验证闭环还不够前置、显式、刚性

虽然已有 verifier / verification state，但还可以更 harness-first：

1. 让“完成”必须绑定可验证证据。
2. 让 verification recipe 成为任务级资产。
3. 让 pre-completion checklist 更具结构性。

#### D. 缺少可复用 skill / recipe library

当前 skill 更偏 prompt capability，而不是从成功执行中提炼出的、host 可管理的 recipe。

#### E. trace analysis 还未转化为 harness 改进闭环

现在有观测，但缺：

1. failure taxonomy
2. trace summarization
3. harness experiment comparison
4. prompt / hook / verification policy 的 A/B 调优支持

#### F. 当前 built-in loop 仍偏“单次 run 成败”，不是“长期任务持续推进”

这会导致复杂任务里：

1. 容易一口气做太多。
2. 容易在局部成功后过早收工。
3. 容易留下不干净工作区。
4. 不易把失败经验转化为下一轮优势。

## 6. 设计目标

### 6.1 必达目标

1. 让 built-in agent 更适合长任务、多阶段任务和复杂软件工程任务。
2. 让验证、恢复、总结和 handoff 从“模型自觉”升级为“host 支持的强协议”。
3. 让现有 loop / hook / observability / verification / memory 资产尽量复用。
4. 让 harness 改进本身可被观测、可被评估。

### 6.2 非目标

1. 不要求马上升级为完整多 agent team。
2. 不要求一次性重写 `runCoreAgentLoop`。
3. 不要求在 v1 就做自动 prompt optimization 平台。

## 7. 推荐架构：从 Agent Loop 升级到 Agent Harness

### 7.1 总体思路

推荐在现有 built-in loop 外围显式增加六个 harness 子层：

1. `SessionInitializer`
2. `ProgressLedger`
3. `VerificationContract`
4. `FailureMemoryStore`
5. `SkillRecipeStore`
6. `TraceAnalysisWorkbench`

关系可概括为：

`SessionInitializer -> runCoreAgentLoop -> ProgressLedger / VerificationContract / FailureMemoryStore -> TraceAnalysisWorkbench -> harness tuning`

### 7.2 SessionInitializer：把“开工仪式”产品化

职责：

1. 在 session 启动或新任务开始前收集：
   - workspace 基本信息
   - 最近消息与执行摘要
   - 最近验证状态
   - 未解决阻塞项
2. 产出一个结构化 `Session Brief`
3. 注入到 built-in agent 的初始上下文中

推荐输出结构：

```swift
struct SessionBrief: Codable, Sendable {
    let sessionID: String
    let taskSummary: String
    let recentProgress: [String]
    let currentFrontier: [String]
    let verificationObligations: [String]
    let recommendedStartupChecks: [String]
    let knownRisks: [String]
}
```

价值：

1. 借鉴 Anthropic initializer 思想。
2. 降低 agent 每次重新“摸环境”的成本。
3. 给后续多 context window 或后台恢复提供稳定入口。

### 7.3 ProgressLedger：把进度变成工件，而不是散落文本

职责：

1. 记录每轮 agent 的“已做 / 未做 / 下一步 / 验证状态”。
2. 在关键节点自动生成 compact summary。
3. 为下轮上下文、UI 展示、恢复逻辑提供事实源。

推荐不是单一 markdown，而是结构化记录 + 可读摘要双轨：

```swift
struct HarnessProgressEntry: Codable, Sendable {
    let timestamp: Date
    let phase: String
    let completedWork: [String]
    let pendingWork: [String]
    let verificationStatus: String
    let nextSuggestedAction: String?
}
```

这相当于把 Anthropic 的 progress file 思路和本项目 execution projection 融合。

### 7.4 VerificationContract：把“完成”改成带证据的完成

职责：

1. 为任务维护 verification frontier。
2. 把 `verify_completion`、verifier subagent、bash/LSP/test results 收敛成统一证据层。
3. 在 completion gate 前执行 deterministic checklist。

核心原则：

1. **自报完成不是证据**
2. **测试输出、构建结果、端到端检查、工件一致性才是证据**
3. **host 保留 completion authority**

推荐增加：

```swift
struct VerificationRecipe: Codable, Sendable {
    let taskType: String
    let requiredChecks: [String]
    let recommendedChecks: [String]
    let blockingConditions: [String]
}
```

价值：

1. 借鉴 Reflexion 和 LangChain 的 self-verify loop。
2. 把 verifier 从“额外工具”升级为“host 支持的契约层”。

### 7.5 FailureMemoryStore：把失败总结沉淀为可复用经验

职责：

1. 对失败事件分类：例如环境误判、验证遗漏、doom loop、错误修复无效、工具使用错误。
2. 为每类失败生成结构化 lesson。
3. 在后续相似任务启动时回注这些 lesson。

推荐结构：

```swift
struct FailureLesson: Codable, Sendable {
    let category: String
    let triggerPattern: [String]
    let failedStrategy: String
    let betterStrategy: String
    let evidence: [String]
}
```

这就是把 Reflexion 的 episodic memory 本地化、工程化。

### 7.6 SkillRecipeStore：把成功模式抽成 recipe

不是把一切都抽成 agent skill，而是沉淀高价值 recipe：

1. 常见工程任务的 startup checklist
2. 常见故障的 verifier recipe
3. 某类仓库的 codebase onboarding pattern
4. 成功的 subagent invocation template
5. 可复用的 testing sequence

这更接近 Voyager 的 skill library，但不一定表现为可执行代码，也可以是 host-managed structured recipe。

### 7.7 TraceAnalysisWorkbench：让 harness 能自我迭代

职责：

1. 基于 business events、tool calls、verification outcome 做 trace 聚合。
2. 自动识别 failure clusters。
3. 对 prompt、hook、verification policy 形成改进建议。

最初不需要复杂 UI，先做：

1. trace summary reducer
2. failure taxonomy
3. regression dashboard data source

这对应 LangChain 的 trace analyzer 思路。

## 8. 推荐的 built-in harness 分阶段演进

### Phase 1：启动脚手架与进度工件化

目标：

1. 引入 `SessionBrief`
2. 引入 `ProgressLedger`
3. 在新 run 启动时自动注入“当前状态简报”

优先级最高，因为它直接改善长任务连续性。

### Phase 2：验证契约前移

目标：

1. 引入 `VerificationRecipe`
2. completion gate 绑定证据要求
3. pre-completion checklist 更结构化

这一步会直接提升“看起来完成”与“真的完成”的区分能力。

### Phase 3：失败记忆与 recipe 沉淀

目标：

1. failure taxonomy
2. `FailureLesson`
3. `SkillRecipeStore`

这一步开始让 built-in agent 不再每次从零学习。

### Phase 4：trace-driven harness tuning

目标：

1. failure cluster dashboard
2. harness experiment 记录
3. 针对 prompt / hook / verifier policy 的对比评估

这一步不是直接增强单次任务，而是增强整个 built-in 系统的演进效率。

## 9. 对当前代码的具体映射建议

### 9.1 以现有 `runCoreAgentLoop` 为执行内核，不重写

当前建议不是推翻 loop，而是把它视作 harness 的 execution kernel。

### 9.2 在 hook 层承接大部分新增能力

最适合落地的扩展点：

1. `didStartRun`：注入 `SessionBrief`
2. `didFinishRound`：写 `ProgressLedger`
3. `beforeCompletion`：执行 `VerificationContract`
4. `didFailRun`：写入 `FailureLesson`

### 9.3 复用现有 observability 资产

已有 `BusinessObservabilityHook` 和 typed events，非常适合：

1. 构造 trace reducer
2. 标注 doom loop / verify miss / tool misuse
3. 做 harness experiment telemetry

### 9.4 复用现有 verification 资产

建议在现有 verifier / verification state 基础上增强，而不是另起炉灶。

### 9.5 逐步减少全局状态依赖

如果 built-in agent 要真正 harness 化，`currentSession`、`pendingUserQuestion`、全局 streaming 状态继续存在会削弱长期作业和多任务能力，因此应继续按 session-scoped 方向演进。

## 10. 风险与权衡

### 10.1 风险：harness 过重，反而拖慢简单任务

应对：

1. 所有新层都要支持按任务类型启用。
2. 简单问答与重型工程任务使用不同 harness profile。

### 10.2 风险：工件太多，context 反而更乱

应对：

1. 结构化存储，按需摘要注入。
2. 不把所有 artifact 原样塞回 prompt。

### 10.3 风险：verification 太强，导致 agent 迟迟无法结束

应对：

1. 明确 blocking / recommended 两级验证。
2. 让 host 区分 hard gate 与 soft reminder。

### 10.4 风险：trace 分析变成新噪音源

应对：

1. 先做 failure taxonomy，再做自动建议。
2. 只聚焦高频失败簇，不追求全量解释。

## 11. 验证策略

设计落地后，至少应验证：

1. 长任务跨多轮后，agent 能借助 `SessionBrief` 快速恢复状态。
2. 没有足够证据时，agent 不能轻易通过 completion gate。
3. 失败后生成的 `FailureLesson` 能在下一次相似任务中被引用。
4. `ProgressLedger` 能稳定生成对下一轮有帮助的 handoff。
5. trace analysis 能识别至少 2~3 类高频 failure pattern。

建议测试层次：

1. 单元测试：`SessionBrief`、`VerificationRecipe`、`FailureLesson` reducer
2. loop 集成测试：completion gate、progress ledger 写入、恢复行为
3. harness 集成测试：失败 -> 记忆 -> 下一轮引用
4. 质量测试：比较启用/禁用 harness profile 的成功率与平均回合数

## 12. 最终建议

对 agentGui built-in agent，Harness Engineering 最值得借鉴的不是一个具体论文里的某个 tricks，而是一种系统观：

1. **让 agent 在开始前先被“上好鞍”**
   用 initializer / session brief 把环境准备好。
2. **让 agent 在执行中始终被“牵住缰绳”**
   用阶段控制、预算、verification contract 限制漂移。
3. **让 agent 在失败后留下“可继承经验”**
   用 failure memory 和 skill recipe 把一次失败变成长期资产。
4. **让 harness 自己进入可改进闭环**
   用 trace analysis 而不是直觉改 prompt。

一句话总结：

> 下一阶段的 built-in agent 增强，应该从“优化 loop”转向“工程化 harness”——把 `runCoreAgentLoop` 从执行引擎，升级为可持续 agent 系统中的核心内核。

## 13. 参考资料

### 论文

1. Yao et al., **ReAct: Synergizing Reasoning and Acting in Language Models**, 2022. `arXiv:2210.03629`
2. Shinn et al., **Reflexion: Language Agents with Verbal Reinforcement Learning**, 2023. `arXiv:2303.11366`
3. Wang et al., **Voyager: An Open-Ended Embodied Agent with Large Language Models**, 2023. `arXiv:2305.16291`
4. Yang et al., **SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering**, 2024. `arXiv:2405.15793`
5. Masterman et al., **The Landscape of Emerging AI Agent Architectures for Reasoning, Planning, and Tool Calling**, 2024. `arXiv:2404.11584`

### 官方/工程文章

1. Anthropic, **Effective harnesses for long-running agents**, 2025
2. LangChain, **Improving Deep Agents with harness engineering**, 2026
3. OpenAI, **Harness engineering: leveraging Codex in an agent-first world**, 2026
4. Martin Fowler, **Harness Engineering**, 2026 commentary
