# ACP Agent Team 研究报告

日期：2026-03-30

目标：基于 2024-2026 的多 agent 理论、论文与工程实践，为 agentGui 设计一套适合 ACP provider 协作的 team 模式。该模式需要支持创意型任务与并行型任务，并且能够在不复制当前消息气泡 UI 的前提下，提供一套更适合团队协作的交互模型。

---

## 1. 问题定义

用户要的不是“让多个 provider 同时输出文本”，而是让异构 provider 在一个受控系统里形成真正的协作。

如果从第一性原理看，这个问题只有四个基本约束：

1. 多个 agent 只有在共享外部事实时才能稳定合作。
2. 并行只适用于彼此弱耦合的子问题，强耦合决策仍然需要收敛点。
3. 异构 provider 的优势来自差异化能力，而不是把所有人变成同一种 worker。
4. 用户需要看到 ownership、冲突、收敛和阻塞，而不是阅读所有中间对话。

因此，一个好的 ACP team 模式必须同时解决三件事：

1. provider 之间如何协作；
2. provider 之间如何避免互相干扰；
3. 用户如何理解团队正在做什么。

这三个问题里，第三个通常被低估。当前很多系统把“多 agent”做成内部 prompt 技巧，但对用户只暴露一条消息流。这样工程上能跑，产品上却很弱，因为用户看不到谁负责什么，也无法判断系统是否真的在并行工作。

## 2. 仓库现状约束

基于当前仓库的 ACP 与聊天架构，设计必须尊重以下事实：

1. ACP provider 已经是独立执行器，而不是单纯的 prompt persona。
2. external ACP runtime 已经按 provider 和 session 做隔离，具备并行基础。
3. 当前主聊天 UI 是 message-first，适合单代理对话，不适合 team 协作工作台。
4. 仓库中已经有 execution projection、artifact、subagent timeline、slash command、runtime observability 这些可复用资产。
5. 当前 provider 体系天然是异构的，工具空间和会话状态并不完全对齐。

这意味着本次设计不应重新发明一个通用 workflow 引擎，也不应把 team 模式做成“若干 provider 的群聊”。真正合理的路线，是在现有 ACP 执行面之上引入一层轻量 team orchestration 与 team-specific UI。

## 3. 外部研究摘要

### 3.1 Anthropic：从简单可组合模式开始

Anthropic 在 2024-12 发布的 Building effective agents 给出了一个很关键的判断：多数成功系统不是靠复杂框架，而是靠少量可组合模式。其最有价值的几点结论是：

1. 复杂度只在结果显著改善时才值得引入。
2. workflow 与 autonomous agent 要区分，不要混成一团。
3. 对 coding 这类任务，环境反馈和测试结果是关键 ground truth。
4. 透明性应是结构透明，而不是原样暴露全部内部文本。

对本项目的启发非常直接：ACP team 不应从“人人自由聊天”开始，而应从少量清晰的协作原语开始。

### 3.2 OpenAI Agents SDK：handoff 与 manager 不是一回事

OpenAI Agents SDK 在 2025 的文档中把多 agent orchestration 分成两类核心模式：

1. agents as tools，也就是 manager 保持总控；
2. handoffs，也就是把当前控制权交给某个 specialist。

这提供了一个重要判断：team 模式不能只有一种 delegation 语义。创意任务与工程任务需要不同的协作形态。

1. 创意任务更适合 manager 保持总控，同时并行拉多个视角。
2. 深入执行型任务更适合把局部控制权交给最适合的 specialist。

因此，ACP team 模式至少需要同时支持 delegation 和 ownership transfer 两种机制。

### 3.3 AutoGen 与 AutoGen 0.4：事件驱动和模块分层更适合规模化

AutoGen 2024 的核心贡献是把多 agent 视为可配置对话系统。AutoGen 0.4 在 2025 的重构则更值得关注，它强调：

1. layered architecture；
2. event-driven core；
3. 把可视化原型、agent chat、core runtime 与 extensions 分层。

这说明多 agent 系统一旦进入真实产品，就必须把“agent 对话”与“runtime 控制面”拆开。仅靠 prompt 里的角色扮演无法支撑长期演进。

对本项目来说，这进一步支持一个结论：ACP team 不能只是把多个 provider 的输出拼到一条 message 流里，而应有独立的 team runtime 和独立的 team projection。

### 3.4 Magentic-One：通用 orchestrator 加 specialist 的路线是有效的

Magentic-One 2024 的结果说明，一个 lead orchestrator 加若干 specialist agent 的结构，在复杂、多步、开放任务上是有效的。其更重要的结论不是“需要一个强 orchestrator”，而是：

1. orchestrator 负责计划、追踪、re-plan；
2. specialist 负责局部行动；
3. 错误恢复要靠显式 re-planning，而不是假设一次 plan 永远正确；
4. 模块化设计允许 agent 随任务替换。

这与 ACP provider 场景高度匹配。不同 provider 可以天然扮演不同 specialist，而 team 层只需要一个轻量 conductor 去分派与收敛。

### 3.5 Tool-Space Interference：异构 agent 协作最大的风险是互相干扰

Microsoft Research 在 2025-09 的 Tool-space interference in the MCP era 给出了对本项目最重要的现实警告。

它的核心结论是：

1. 工具数量增多会显著降低效果。
2. 参数结构过深会降低调用质量。
3. 名称冲突、语义重叠、上下文过长、错误语义不清都会破坏协作。
4. 横向整合越多，越容易出现“每个工具都合理，但系统整体变差”的情况。

对 ACP team 的设计含义非常明确：

1. 不要让每个 provider 在 team 模式下暴露完整工具空间。
2. 必须先做 capability slicing，而不是裸暴露所有能力。
3. provider 间协作不应通过“共享整个上下文”完成，而应通过小而结构化的 artifact 完成。
4. team 模式必须有名字空间和 artifact 引用，而不是自由文本转述。

### 3.6 CrewAI：自治 team 与事件流控制需要分层共存

CrewAI 的工程经验虽然偏框架产品，但其 Crews 与 Flows 的分层有一个很务实的价值：

1. Crews 代表自治协作；
2. Flows 代表事件驱动的精确控制。

这与前面几个研究信号一致。多 agent 不是“要么全自动、要么全脚本”，而是需要自治和控制并存。对 ACP team 来说，这意味着：

1. provider 内部保留自主性；
2. team runtime 对路由、预算、状态流转保留控制权。

### 3.7 Agent Lightning：执行与学习解耦是长期正确方向

Agent Lightning 2025-12 的价值不在于本期要上 RL，而在于它强调：

1. 把 agent 执行轨迹标准化为 state-action-transition；
2. 执行层和训练层解耦；
3. 多 agent 系统也应统一采集 spans 与 reward data。

对本项目的设计启发是：team 模式从第一天就应把 run 过程结构化，而不是等以后再补 observability。否则既无法评估 team 是否真的比单 agent 更好，也无法持续优化路由策略。

### 3.8 AgentRx：多 agent 失败要定位第一处不可恢复错误

AgentRx 2026-03 的一个关键判断是：长轨迹、多 agent、概率型系统里，最有价值的不是事后看到一堆错，而是定位 first critical failure step。

这对 ACP team 很重要，因为 team 系统最容易出现“错误在 A，爆炸在 B，表现到用户面前在 C”的情况。

因此，team 模式的诊断必须具备：

1. step 级事件记录；
2. artifact 级引用链；
3. 可追溯的 handoff 关系；
4. blocker 与 invalidation 的显式标记。

## 4. 研究结论汇总

综合以上理论、论文与工程实践，可以得到六条对本项目最重要的设计原则。

### 4.1 不要把多 provider 协作建模成自由群聊

自由群聊的问题是：

1. 共享上下文过大；
2. ownership 不清晰；
3. 结果难以验证；
4. 很快退化成高成本低信噪比的文本循环。

正确做法是让 provider 交换结构化工件，而不是交换长篇对话。

### 4.2 协作的基本单元应该是 task claim，而不是轮次消息

真正能驱动并行的是“谁认领了哪个子任务”，而不是“谁又说了一句话”。

因此 team runtime 的核心对象应是 task card、claim、artifact、review，而不是 message。

### 4.3 创意并行和执行并行是两种不同机制

创意任务需要：

1. 多视角发散；
2. 低耦合输出；
3. 集中收敛。

执行任务需要：

1. 明确 ownership；
2. 最小交叉写入；
3. 验证后合并。

同一个系统必须同时支持这两种并行，而不能只做一种“parallel”。

### 4.4 Team runtime 必须比单 agent 更节制，而不是更放任

越是多 agent，越需要硬约束：

1. capability slicing；
2. token 和工具预算；
3. 结构化 handoff；
4. merge gate；
5. 失败回退。

否则系统只会把单 agent 的错误放大。

### 4.5 UI 应展示工作结构，不应展示全部内部文本

用户最需要知道的是：

1. 目标是什么；
2. 谁在做什么；
3. 哪些工作并行；
4. 哪些结论已收敛；
5. 哪些地方卡住了；
6. 最终产物是什么。

这天然指向 board/workbench，而不是 message list。

### 4.6 最值得创新的点不是“再加更多 agent”，而是“让异构 provider 在有限协议下形成有效分工”

当前业界大量实现的创新点都集中在 agent prompt 和框架 API 上，但 ACP provider 场景更独特，因为这里的 agent 不是同质角色，而是真实异构执行器。

因此，本项目真正有价值的创新方向是：

1. 用统一 team protocol 驯化异构 provider；
2. 用 typed artifacts 替代 provider 之间的大段自由文本；
3. 用工作台 UI 让用户看到 team 的结构化进展。

## 5. 推荐设计方向

基于上述研究，我建议本项目采用一种简单但有辨识度的 team 模式：

### Brief-Claim-Commit

这个模式由四个阶段组成：

1. Brief
   conductor 生成统一任务 brief、约束、验收标准、可用 workspace 上下文。
2. Claim
   各 provider 不直接开工，而是先提交 claim：我适合做什么、需要什么、风险是什么、预计产出什么。
3. Work
   runtime 根据 claim 分配 workstream，允许并行执行，但每个 workstream 只有一个 owner。
4. Commit
   provider 不把结果直接塞进主对话，而是提交 artifact，由 reviewer 或 conductor 做 merge 与收敛。

这个模式的优点在于：

1. 简单，只有少量原语；
2. 可兼容创意任务和工程任务；
3. 可以天然适配异构 provider；
4. 非常适合做可视化 UI。

## 6. 为什么这套模式适合 ACP provider

ACP provider 与普通 prompt-persona agent 最大的不同是，它们各自有独立的 runtime、独立的工具视图、独立的行为风格和外部能力。也正因为如此，ACP provider 不适合做“完全共享上下文的圆桌辩论”。

Brief-Claim-Commit 的优势在于：

1. 它把协作前置到 claim 阶段，减少盲目并行。
2. 它把 provider 的差异表达成 capability fit，而不是 prompt 风格差异。
3. 它把真正共享的信息限制为 brief、artifact 和 review，而不是全量内部思考。
4. 它允许 user 在 commit 之前插入确认，而不会打断每个微步骤。

这比传统 manager-worker 更适合异构 provider，也比自由多 agent chat 更节制。

## 7. 对 UI 的直接结论

研究和架构结论共同指向一个明确答案：ACP team 不能复用当前 message 气泡界面。

最佳交互模型应满足：

1. team 是一个持续工作空间，而不是一条消息。
2. 工作对象是 mission、task cards、artifacts、reviews，而不是 message bubbles。
3. 用户默认看到的是 team board，而不是内部聊天记录。
4. 详细 trace 作为 inspector 或 audit panel 下钻，而不是主视图。

换句话说，最适合的 UI 不是 chat transcript，而是 team workbench。

## 8. 最终建议

如果压缩成一句话，本次设计最正确的方向是：

不要把 ACP team 做成“多个人同时说话”，而要把它做成“多个异构执行器围绕同一任务板协作”。

更具体地说：

1. 架构上采用 Brief-Claim-Commit。
2. 协议上采用 typed task cards 和 typed artifacts。
3. 执行上采用受控并行和显式 merge gate。
4. UI 上采用 team workbench，而不是 message UI。
5. 演进上先支持少量 provider team，再逐步加入评分、学习与调试闭环。

## 9. 参考材料

1. Anthropic, Building effective agents, 2024-12
   https://www.anthropic.com/engineering/building-effective-agents
2. OpenAI Agents SDK, Agent orchestration, 2025
   https://openai.github.io/openai-agents-python/multi_agent/
3. AutoGen: Enabling Next-Gen LLM Applications via Multi-Agent Conversation, COLM 2024
   https://www.microsoft.com/en-us/research/publication/autogen-enabling-next-gen-llm-applications-via-multi-agent-conversation-framework/
4. AutoGen 0.4 dev docs, 2025
   https://microsoft.github.io/autogen/dev/
5. Magentic-One: A Generalist Multi-Agent System for Solving Complex Tasks, 2024-11
   https://www.microsoft.com/en-us/research/publication/magentic-one-a-generalist-multi-agent-system-for-solving-complex-tasks/
6. Microsoft Research, Tool-space interference in the MCP era, 2025-09
   https://www.microsoft.com/en-us/research/blog/tool-space-interference-in-the-mcp-era-designing-for-agent-compatibility-at-scale/
7. CrewAI repository and docs, 2025-2026
   https://github.com/crewAIInc/crewAI
8. Microsoft Research, Agent Lightning, 2025-12
   https://www.microsoft.com/en-us/research/blog/agent-lightning-adding-reinforcement-learning-to-ai-agents-without-code-rewrites/
9. Microsoft Research, AgentRx, 2026-03
   https://www.microsoft.com/en-us/research/blog/systematic-debugging-for-ai-agents-introducing-the-agentrx-framework/