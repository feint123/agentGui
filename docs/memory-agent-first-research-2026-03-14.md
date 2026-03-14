# agentGui 记忆系统重构研究：从 Memory Control Plane 到 Agent-First Cognitive Substrate

日期：2026-03-14

## 1. 结论先行

当前 agentGui 的 memory 已经不是简单的历史消息压缩，而是一套具备 admission、retrieval、evidence、lifecycle、distillation 和 observability 的 memory control plane。这一版设计解决了传统工程里“怎么把记忆存起来、筛出来、展示出来”的问题，但它仍然主要服务于软件系统的可治理性，而不是 agent 的认知连续性。

如果从 agent-first 视角重新定义 memory，核心问题不应再是：

1. 哪些记录要写入 store。
2. 哪些记录要进 prompt。
3. 哪些记录该转 hot/warm/cold。

而应改成：

1. agent 当前到底在维护哪些未闭合的信念与任务前沿。
2. 哪些过往经验会真正改变下一步动作选择，而不是只增加背景信息。
3. 哪些失败反例、验证缺口、工具约束必须在推理时被优先激活。
4. memory 如何从“静态资料库”升级为“推理过程的动态底盘”。

因此，这份方案的核心判断是：

`memory 不是 agent 的附属存储层，而是 agent 在长时程任务中维持身份、策略、信念、反例和停止条件的认知基底。`

基于这个判断，本文不建议继续把 memory 只沿着分层存储、向量检索、生命周期治理这条路径做厚，而是建议把它重构为一套新的运行时架构：

`RMS = Reasoning Memory Substrate`

它不是对 MemGPT、RAG、episodic/semantic/procedural 三分法的简单复刻，而是围绕一个更强的原则展开：

`只保留那些会改变未来决策的记忆，只检索那些能缩小当前认知前沿的记忆，只让已验证或显式带风险标记的记忆进入高影响推理。`

## 2. 对当前系统的重新诊断

结合仓库现有文档与实现，当前 memory 系统的优点已经很明确：

1. 有统一的 `MemoryRecord` 结构，支持 evidence anchors、verification status、admission explanation、lifecycle tier。
2. 有 `MemoryRuntimeCoordinator` 负责 retrieval planning、budgeting、prompt assembly。
3. 有 `MemoryGovernanceService` 和后台任务体系，避免所有候选记忆直接写入长期存储。
4. 有 experience distillation、procedure induction、working-set rebalance 等能力，已经明显超出“聊天摘要”的范畴。

但如果目标是支撑真正的 agent-first runtime，当前设计仍有四个根部限制。

### 2.1 它更像可治理的数据平面，而不是可演化的认知状态

当前对象中心仍然是 `record`，不是 `belief`、`open question`、`counterexample`、`repair intention`。这意味着系统擅长保存“发生过什么”，却不擅长维护“还没搞清楚什么”。

对 agent 来说，长期任务最关键的通常不是历史事实总量，而是当前 unresolved frontier：

1. 哪个假设仍未验证。
2. 哪条恢复路径已经失败。
3. 哪个工具链约束最可能阻塞完成。
4. 哪个 claim 一旦被证伪会推翻整体结论。

传统 record-centric memory 很难天然表达这些内容。

### 2.2 它优化的是检索命中率，不是决策改变量

当前 memory runtime 的默认目标更接近：

1. 找到相关记录。
2. 控制 token 成本。
3. 让 evidence 和 explanation 可见。

但 agent 实际需要优化的是另一件事：

`这条记忆会不会改变我下一步最优动作？`

一条高相似度记忆，如果不会改变行动策略，就只是在占用上下文预算。相反，一条低语义相似但能触发“不要重复跑这个错误命令”“这类失败先看 scheme 分享状态”“这个任务先核对 reviewer rejection 再改代码”的反例记忆，决策价值反而更高。

### 2.3 它有证据锚点，但还没有“反证优先”的记忆组织方式

现有设计已经重视 evidence anchors，这是正确方向。但对 agent 来说，支持性证据并不总是最有价值。很多时候，更关键的是：

1. 哪些旧经验已经失效。
2. 哪些 procedure 只在特定前提下成立。
3. 哪些成功路径在当前上下文反而危险。
4. 哪些 claim 曾经被真实工具结果推翻。

也就是说，memory 里最稀缺的资产之一不是“我知道什么”，而是“我知道哪些常见路径现在不该走”。当前系统尚未把 negative memory 设为一等对象。

### 2.4 它已经在做 distillation，但还没有做 counterfactual distillation

经验蒸馏如果只是把成功步骤和恢复路径总结成文本，本质上仍然偏知识库化。真正对 agent 有长期价值的不是“又多了一条经验”，而是：

1. 这条经验在什么条件下会改变策略。
2. 如果没有这条经验，agent 会犯什么错误。
3. 它影响的是选工具、排优先级、定义完成条件，还是停止条件。

如果这些内容没有被显式编码，distillation 很容易持续堆积“听起来有用”的摘要，但对推理控制没有足够直接的帮助。

## 3. 相关研究真正提供了什么启发

下面只保留对 agentGui 下一代 memory 架构最有工程价值的研究线索，不做综述式堆砌。

### 3.1 Generative Agents：reflection 不是日志归档，而是把经验重新写回未来行为

Park 等人在 2023 年的 Generative Agents 中提出 observation、planning、reflection 三件套。它最重要的启发不是“加一个 reflection 模块”，而是：memory 不能只存事件，还要生成更高层的可复用解释，这些解释会直接影响未来计划。

对本项目的启发是：

1. 原始工具轨迹不应该直接等价于长期记忆。
2. reflection 的产物必须带行为后果，而不是只是摘要。
3. 记忆写回应与后续 planning 强耦合，而不是后处理附属流程。

### 3.2 MemGPT：分层记忆是必要的，但 paging 不是终点

MemGPT 把记忆系统类比为操作系统的多层内存管理，这对 context window 受限的模型非常有启发：不同速度、不同容量、不同可信度的记忆层必须由 runtime 主动调度。

但这条路径的局限也很明显：它解决了“怎么搬运上下文”，却没有完全回答“为什么这个上下文此刻值得被搬运”。

对本项目来说，MemGPT 给出的正确方向是分层与调度，不足之处是缺少 decision impact 语义。因此我们不应停在 memory tiering，而要继续往 decision-conditioned retrieval 走。

### 3.3 Reflexion 与 ExpeL：经验学习的关键不在存下失败，而在把失败变成下一轮的策略偏置

Reflexion 通过 verbal reinforcement learning 把失败反馈写成可复用文本；ExpeL 则更进一步，强调从任务族中抽取能迁移的经验，并在推理期回忆这些经验来改变决策。

这两条工作共同说明：

1. 不改模型权重，也能让 agent 从经验中持续变强。
2. 经验记忆的核心对象不是事实，而是策略偏置。
3. memory 需要区分“一次失败发生了”和“从失败中学到了什么”。

这为 agentGui 提供了非常直接的方向：把 memory 从事实库升级为 policy-shaping substrate。

### 3.4 Voyager：真正的长期能力沉淀不是对话摘要，而是可调用技能与适用条件

Voyager 的 skill library 证明，长期学习最有价值的沉淀形式之一，是带适用条件的可执行技能，而不是单纯回忆旧轨迹。它还强调 environment feedback、execution errors 和 self-verification 共同驱动 skill refinement。

对本项目的关键启发是：

1. 程序性记忆必须带前置条件和失败信号。
2. 技能或 procedure 不应只存内容，还要存 applicability fingerprint。
3. 经验的终极价值是改变执行效率和成功率，而不是提升记录完整性。

### 3.5 CRITIC 与 ReAct：memory 必须服务于“边行动边校验”的认知回路

ReAct 说明 reasoning 和 acting 应交织进行；CRITIC 说明高质量纠错依赖外部工具反馈，而不是纯自评。

这对 memory 的真正要求是：

1. memory 不能只是 prompt 背景，它必须参与 probe action 的选择。
2. memory 应记录哪些工具反馈曾推翻过哪些假设。
3. retrieval 目标不只是补全知识，还要优先找出会触发校验动作的反例。

### 3.6 2024-2025 的 process supervision 与 inference-time scaling 趋势：算力预算应围绕不确定性分配

近两年关于 process supervision、step-level verification、test-time compute 和 inference-time scaling 的研究趋势逐渐清晰：更强的系统不是一视同仁地多想，而是在高不确定、高影响的分支上花更多推理预算。

这给 memory 带来的新要求是：

1. memory retrieval 也必须是 budget-aware 的。
2. 不同记忆对象应根据当前 frontier 风险被分配不同的激活权重。
3. 高风险未决问题应触发更深的 memory probe，而不是统一 top-k 相似度检索。

## 4. 新方案：RMS 不是存储系统，而是推理基底

### 4.1 定义

`RMS = Reasoning Memory Substrate`

RMS 的定义不是“更强的 memory runtime”，而是：

`一套面向 agent 决策的持续认知基底，用来维护未决前沿、调度高价值记忆、注入反例约束、蒸馏策略偏置，并对停止条件给出支持。`

它有三个原则：

1. memory 的价值取决于它是否改变未来决策，而不是它是否能被检索到。
2. memory 的可信度取决于它是否被证据支持、反证修正或显式标记风险，而不是它是否写入得足够早。
3. memory 的调度对象不是用户问题文本，而是 agent 当前的 epistemic frontier。

### 4.2 这套方案与现有理论的区别

它不是 MemGPT 的再实现，因为我们不把“分层搬运上下文”当成终点。

它不是普通 RAG，因为我们的检索目标不是语义相关性，而是决策改变量。

它不是单纯的 episodic/semantic/procedural 三分法，因为我们把 negative memory、verification debt 和 frontier memory 作为独立对象。

它也不是简单的 reflection memory，因为我们要求每条高价值记忆都回答一个额外问题：

`如果没有这条记忆，agent 的下一步会如何不同？`

## 5. RMS 的核心对象

### 5.1 Frontier Memory

这不是长期记忆，而是运行时一等状态。它表示当前任务里尚未闭合的认知前沿。

每条 frontier 至少包含：

1. `frontierId`
2. `goal`
3. `openClaim`
4. `uncertaintyType`
5. `impactLevel`
6. `suggestedProbe`
7. `stopCondition`

它解决的问题不是“记住过去”，而是“明确现在还缺什么”。

### 5.2 Counterexample Memory

这是新方案里最重要的新增对象。它不是失败日志，而是结构化反例资产。

每条 counterexample 至少包括：

1. 被推翻的假设或 procedure。
2. 推翻它的观测或工具结果。
3. 适用上下文指纹。
4. 推荐替代动作。
5. 失效条件。

传统系统容易累积支持性知识，但 agent 真正省时间的往往是：不要重复犯已经被证据推翻的错误。

### 5.3 Tactic Kernel

Tactic Kernel 不是“操作步骤摘要”，而是可重放的策略片段。

它至少携带：

1. 适用前提。
2. 首选动作序列。
3. 常见失败信号。
4. 验证路径。
5. 退出条件。

相比普通 procedure memory，kernel 更强调在推理期可被快速激活，并与当前 frontier 绑定。

### 5.4 Constraint Memory

这是 user preference、repo invariant、tool affordance、policy rule 的统一容器。它直接决定某些动作是否可行，而不是作为背景知识存在。

例如：

1. 某类任务先跑 targeted test 再改实现。
2. 某工具需要只读上下文。
3. 某 repo 的记忆写入必须带 evidence anchor。
4. 某用户偏好要少注释、少改动、先读上下文。

### 5.5 Verification Debt Ledger

这也是 RMS 与传统 memory 的关键差异。不是所有未验证记忆都应该立刻丢弃，因为有些启发式经验在推理中仍然有价值。但它们不能伪装成高可信知识。

因此需要单独维护一套 verification debt：

1. 哪些记忆正在影响决策但证据不足。
2. 哪些记忆长期未被重新确认。
3. 哪些高影响 kernel 需要优先复验。

这让系统第一次能显式回答：

`当前 agent 依赖了哪些尚未充分被证明的长期经验。`

## 6. RMS 的关键创新：决策改变量驱动的读写机制

### 6.1 新的写入准则：不是“有用”，而是“会改变未来动作”

建议把记忆准入从传统的 relevance/confidence/scoring，升级为四道门：

1. `Decision Delta Test`
2. `Transfer Test`
3. `Evidence Test`
4. `Decay Test`

只有通过至少前三项的候选，才有资格进入高影响记忆层。

#### Decision Delta Test

判断这条候选记忆是否会改变未来某类任务中的下一步动作或停止条件。如果不会改变，它不应进入高成本长期记忆。

#### Transfer Test

判断它是否只适用于一次性局部上下文，还是能迁移到任务族。不能迁移的内容更适合停留在 episode 层，而不是 policy 层。

#### Evidence Test

判断它是否有真实工具、文件、review、运行时产物支持。证据不足的内容可以进入 heuristic tier，但不能冒充 verified kernel。

#### Decay Test

判断它随环境变动失效的速度。衰减快的内容不应沉淀为高优先级长期策略。

### 6.1.1 这些对象如何从 agent 对话与执行轨迹中提取

上面的对象如果只停留在 schema 层，RMS 仍然无法落地。真正需要补清楚的是：`frontier`、`counterexample`、`constraint`、`verificationDebt`、`tacticKernel` 不是人工标注后再写回系统，而是要从 agent 每轮已经可见的消息与执行产物里持续抽取。

建议把抽取过程做成一条明确流水线：

```text
Conversation / Tool Events -> Atomic Epistemic Events -> Frontier Builder -> Memory Object Extractors -> Evidence / Debt Scoring -> Admission
```

其中输入源至少包括：

1. 用户消息：目标、约束、补充上下文、显式偏好、停止条件。
2. agent 消息：当前假设、候选动作、完成判断、请求补充信息、失败解释。
3. 工具结果：文件读取、grep、测试、编译、review、verifier、diff、shell 输出。
4. 环境状态：当前 workspace、已知 repo 规则、feature flags、tool affordance。

第一步不是直接生成长期记忆，而是先把对话和执行流标准化成 `Atomic Epistemic Event`。建议最少抽取六类原子事件：

1. `goalDeclared`：用户或系统明确给出目标。
2. `claimRaised`：agent 或用户提出可被验证的判断。
3. `actionProposed`：agent 提出下一步动作或恢复路径。
4. `observationReceived`：工具、文件、测试、review 返回新证据。
5. `constraintDeclared`：出现 user preference、repo invariant、tool restriction、policy boundary。
6. `claimResolved`：某个 claim 被验证、被证伪、或因信息不足转入 debt。

这里不应采用关键词匹配或传统启发式分类作为主抽取路径。那样做的问题是，它只能识别预先枚举过的表面模式，无法可靠捕捉 agent 在真实任务里不断变化的隐含目标、失败语义和策略后果。

更合理的做法是：`把完整的会话片段、工具结果和当前任务上下文组织成 extraction prompt，让大模型直接判断并提取结构化的 epistemic objects。`

也就是说，RMS 的抽取器本质上应该是一个专门的语义判定器，而不是关键词规则机。它接收的不是一句话，而是一小段有边界的任务上下文：

1. 当前轮及前后相邻轮的 user / agent 消息。
2. 本轮新增的工具结果、review、测试、diff、stderr。
3. 当前已存在的 `EpistemicState` 摘要。
4. 已激活的重要 constraints、counterexamples、verification debt。

然后通过专门 prompt 要求模型完成四件事：

1. 抽取 claim、action、constraint、observation、resolution 等原子 epistemic events。
2. 判断哪些未闭合 claim 应升级为 frontier。
3. 判断哪些证伪事件足以形成 counterexample。
4. 判断哪些内容只是局部噪音，不应写入长期层。

这里的关键不是让模型“自由总结”，而是让模型在严格输出 schema 下做语义裁决。也就是说，prompt 里必须明确要求：

1. 每个对象都要给出 source refs。
2. 每个对象都要说明 evidence level。
3. 每个对象都要说明为什么它会改变下一步动作，或者为什么不会。
4. 不允许输出原始 chain-of-thought，只允许输出结构化 residue。

关键词和规则最多只能作为辅助机制存在：

1. 做窗口裁剪，减少不相关消息进入 prompt。
2. 做低成本预警，例如测试失败后触发 extraction。
3. 做审计，对比模型输出与原始事件是否明显漏抽。

它们不应决定对象语义本身。

在 `Atomic Epistemic Event` 之上，再做对象级抽取。

#### Frontier Memory 的提取

`frontier` 的来源不是“当前话题”，而是仍未闭合且会影响后续动作的 claim。可按下面规则构造：

1. 先聚合所有尚未 `resolved` 的 `claimRaised`。
2. 若 claim 关联到 blocker、失败恢复、关键文件定位、验证缺口、完成标准判断，则提升 `impactLevel`。
3. 若两个以上候选动作依赖同一个未决 claim，则生成 `frontier`。
4. 若已有证据足以闭合，则不生成 frontier，只写回 resolution。

也就是说，frontier 的判定标准不是“提到过”，而是：`它现在仍然阻止系统确定下一步最优动作。`

#### Counterexample Memory 的提取

`counterexample` 的来源不是任意失败，而是“某个旧假设、旧套路、旧恢复路径被证据推翻”。建议至少满足以下条件之一才生成：

1. agent 明确提出某条修复路径，随后被测试、编译、review 或运行结果证伪。
2. 某个已存在的 procedure 在当前上下文重复失败。
3. 某条高频 heuristic 被实际工具结果否定，且否定会改变未来动作选择。

抽取时要保留四个字段：

1. 被推翻的假设或 procedure。
2. 推翻它的证据锚点。
3. 上下文指纹，例如任务类型、文件类型、工具链、错误模式。
4. 替代动作或禁止动作。

没有替代动作的失败日志，不应直接升级成 counterexample，它最多只是 episode 事实。

#### Constraint Memory 的提取

`constraint` 应优先从稳定、可复用、跨轮生效的信息里抽取，而不是从一次性指令里滥存。建议来源分四类：

1. 用户显式偏好，例如少改动、先读上下文、默认少注释。
2. repo invariant，例如先跑 targeted test、不得破坏现有公共 API。
3. tool affordance，例如某工具只读、某命令成本高、某 reviewer 需要补证据。
4. policy boundary，例如不能输出敏感内容、不能执行破坏性命令。

约束提取需要做持久性判断：

1. 只在当前任务有效的，进入 session/task scope。
2. 跨任务稳定有效的，才能进入 project/user scope。
3. 与现有约束冲突的，不覆盖旧值，而是进入 conflict review 或 verification debt。

#### Verification Debt 的提取

`verificationDebt` 不是“没验证过的所有内容”，而是“正在影响决策但证据还不够的内容”。建议在以下场景自动生成：

1. 某条 claim 已经影响候选动作排序，但没有直接工具证据。
2. 某条 tactic kernel 来自少量样本，尚未跨场景复验。
3. 某条 constraint 只出现过一次，仍可能是局部偶发现象。

这让系统能区分：一个判断虽然暂时可用，但它现在仍欠验证，不能和 verified memory 等权。

#### Tactic Kernel 的提取

`tacticKernel` 不应直接从单轮 agent 自述里生成，否则会把大量临时策略误写成长期技能。更稳妥的准入条件是：

1. 至少出现一次完整成功闭环，并且关键步骤有 evidence anchors。
2. 或者在两个以上相似 episode 中复现成功。
3. 且它明确改变了工具顺序、验证顺序、停止条件或恢复路径。

因此 kernel 更接近“带适用条件的已验证策略片段”，而不是“agent 曾经说过的一段做法”。

### 6.1.2 一条最小可落地的抽取算法

为了避免重新退回老式软件式抽取，第一阶段也应该是 `prompt-first`，只是把 prompt 设计得足够收敛、足够可审计。一个最小可落地版本可以是：

1. 每轮结束时收集消息、工具结果、review、测试、diff，并转成统一 `EpistemicInputEnvelope`。
2. 用一个 `Epistemic Event Extraction Prompt` 让模型输出结构化 `Atomic Epistemic Event` 列表，并附上 source refs、confidence、evidence level。
3. 用一个 `Frontier Synthesis Prompt` 基于 event 列表和当前 `EpistemicState`，判断哪些 open claims 真正阻塞下一步动作选择。
4. 用一个 `Counterexample Extraction Prompt` 判断哪些失败不是普通 episode，而是足以推翻旧假设或旧 procedure 的反例。
5. 用一个 `Constraint / Debt Extraction Prompt` 判断哪些偏好、规则、工具限制应沉淀为 constraint，哪些应保留为 verification debt。
6. 让 admission 层基于模型输出再执行 `Decision Delta Test`、`Transfer Test`、`Evidence Test`，决定是否进入长期层。

如果需要控制成本，不应回退到关键词匹配，而应采用更小的 prompt、分阶段 prompt、或只对高影响轮次触发 extraction。也就是说，成本优化应发生在 `prompt orchestration` 层，而不是把语义判断重新降格成规则匹配。

更进一步，建议把抽取 prompt 设计成显式的 host contract，例如要求模型输出：

1. `objects[]`：抽取出的 frontier / counterexample / constraint / debt / kernel candidates。
2. `rejected[]`：看起来重要但被判定不该写入的对象，以及拒绝理由。
3. `missingEvidence[]`：当前还缺哪些证据，导致某些对象只能保留在 debt。
4. `decisionImpactNote`：如果这些对象被激活，下一步动作会如何变化。

这里最关键的约束是：`RMS 提取的是 reasoning residue，而不是原始 chain-of-thought。`

也就是说，系统保存的是 claim、evidence、contradiction、constraint、action consequence，而不是模型的原始隐式推理展开文本。

### 6.2 新的检索准则：不是 semantic top-k，而是 decision impact ranking

RMS 建议把检索排序目标改成一个新的估计量：

$$
DI(m \mid s) = P(a_m^* \neq a_\varnothing^* \mid s) \times \Delta U \times C \times F - Cost
$$

其中：

1. $P(a_m^* \neq a_\varnothing^* \mid s)$ 表示引入记忆 $m$ 后，当前状态 $s$ 下最优下一步动作发生变化的概率。
2. $\Delta U$ 表示动作改变后对成功率、修复速度、验证质量的边际提升。
3. $C$ 表示当前记忆的可信度。
4. $F$ 表示新鲜度与适用性匹配程度。
5. $Cost$ 表示读取、展开、注入 prompt 的预算成本。

这个公式的意义不是追求精确数学估计，而是让 memory planner 的优化目标从“最相关”变成“最能改变决策”。

### 6.3 新的压缩准则：counterfactual distillation

RMS 不建议只做 summary-based distillation，而建议引入 counterfactual distillation：

1. 从 episode 中抽取关键转折点。
2. 判断如果删除这段经验，agent 哪一步最可能重犯错误。
3. 只把会改变未来策略的部分压缩成 kernel 或 counterexample。

这样得到的记忆更短，但对推理更有力。

## 7. RMS 的运行时回路

建议将当前 memory runtime 从“prepare context before turn”升级成下面这条持续回路：

```text
Observe -> Frontierize -> Retrieve -> Simulate -> Act -> Verify -> Distill -> Invalidate
```

含义如下：

1. `Observe`
   收集本轮消息、工具结果、review、测试、diff、失败触发器。

2. `Frontierize`
   把当前任务转成 open claims、blocking risks、verification debt、candidate next actions。

3. `Retrieve`
   按 decision impact 检索 tactic kernels、counterexamples、constraints 和 relevant episodes。

4. `Simulate`
   在小预算 test-time compute 下，让 host 对 2 到 4 个候选动作做轻量对比，并评估是否需要更多证据。

5. `Act`
   执行最优动作，可能是读文件、改代码、跑测试、调 reviewer、调 verifier、停止或请求补充信息。

6. `Verify`
   把结果映射回 claims、evidence、contradictions 和 debt 变化。

7. `Distill`
   抽取 kernel、counterexample、constraint update 或 decay signal。

8. `Invalidate`
   将已过期、被反证、环境变动失效的旧记忆降权、替换或打上 debt 标记。

其中最关键的一步是 `Frontierize`。没有它，memory retrieval 就会继续退化成“用户问了什么，我就去找相似记录”。

## 8. 对 agentGui 的具体落地建议

### 8.1 保留现有 control plane，但把它降级为 substrate 的一部分

现有 `MemoryRuntimeCoordinator`、`MemoryGovernanceService`、`MemoryBackgroundScheduler` 不应废弃。它们已经提供了很强的可治理性基础。

但在新架构里，它们的定位应变化：

1. `MemoryRuntimeCoordinator` 不再只是检索和拼 prompt，而要生成 `EpistemicState`。
2. `MemoryGovernanceService` 不再只做 admission route，而要执行 decision-delta aware admission。
3. `MemoryBackgroundScheduler` 不再只做 consolidation，而要承担 kernel distillation 和 invalidation jobs。

### 8.2 新增 `EpistemicState`，让 memory 真正进入 agent loop 主链

建议增加新的运行时对象：

```json
{
  "frontiers": [],
  "activeConstraints": [],
  "candidateActions": [],
  "verificationDebt": [],
  "activatedMemories": [],
  "counterexamples": [],
  "residualRisk": 0.0,
  "expectedValueOfMoreReasoning": 0.0
}
```

这个对象不是给 UI 展示的附属快照，而是 host loop 每轮都应读写的一等状态。

### 8.3 重新定义 `MemoryRecord` 的高价值子类型

建议在现有 record 基础上，逐步引入以下高价值类型：

1. `frontier`
2. `counterexample`
3. `tacticKernel`
4. `constraint`
5. `verificationDebt`
6. `episodeDelta`

它们不一定需要独立持久化模型，但必须在 runtime 语义上区分，否则 retrieval policy 无法有针对性地调度。

### 8.4 新增 `MemoryInfluenceTrace`

这是产品与调试层非常关键的新对象。每轮 memory 注入后，系统应记录：

1. 哪些记忆被激活。
2. 它们改变了哪个候选动作排名。
3. 哪条 counterexample 阻止了哪种错误路径。
4. 最终哪个 memory 对完成结论真正产生影响。

没有这层可观测性，系统无法验证“memory 是在帮助推理，还是只是在增加上下文长度”。

### 8.5 把 negative memory 做成显式资产

建议在现有 distillation 流程上优先新增两类输出：

1. `anti-pattern`
2. `invalidated-procedure`

前者记录常见错误路径，后者记录曾经有效、现在失效的套路。它们的优先级应高于普通经验摘要，因为它们最能直接减少重复犯错。

### 8.6 旧概念如何退场，避免项目里堆积无效代码

如果只新增 `EpistemicState`、`frontier`、`counterexample` 等对象，但不定义旧概念的退场路径，项目会很快出现两套平行语义：一套是 record-centric memory control plane，另一套是 frontier-centric reasoning substrate。两套都保留会带来三类问题：

1. 同一信息被两套模型重复表达，出现双写和漂移。
2. UI、设置项、日志、测试继续暴露已经没有产品意义的旧概念。
3. 运行时为了兼容旧结构不断做桥接，最终把迁移成本永久化。

因此需要显式把现有代码分成四类：保留、收敛、替换、删除。

#### 应保留但要降级为 substrate 的概念

这类对象仍有工程价值，但不应再承载核心语义：

1. `MemoryRuntimeCoordinator`
2. `MemoryGovernanceService`
3. `MemoryBackgroundScheduler`
4. `UnifiedMemoryFileStoreAdapter`
5. `MemoryEvidenceAnchor` / `MemoryEvidenceResolver`

它们继续存在，但职责要收窄为：调度、存储、证据解析、后台作业编排，而不再定义“记忆是什么”。

#### 应收敛或改名的概念

这类对象不是完全错误，而是会与 RMS 的新语义重叠。建议优先做语义收敛：

1. `MemoryRetrievalPlanner` 收敛为 decision-impact planner，而不是 layer/top-k planner。
2. `MemoryRetrievalIntentClassifier` 收敛为 frontier-aware intent classifier。
3. `MemoryPromptAssembler` 收敛为 epistemic context assembler。
4. `MemoryExperienceDistillationService` 与 `MemoryProcedureInductionService` 收敛为 kernel/counterexample distillation。
5. `MemoryAdmissionPolicy`、`MemoryAdmissionFeatureExtractor`、`MemoryAdmissionScore`、`MemoryAdmissionExplanation` 从 relevance/confidence 语义收敛到 decision-delta / transfer / evidence / decay 语义。

#### 应逐步边缘化的旧抽象

以下概念在 RMS 下仍可能保留为存储或兼容字段，但不应继续作为一等运行时语义：

1. `MemoryLifecycleTier`
2. `MemoryRetentionService`
3. `MemoryLifecycleManager`
4. `MemoryWorkingSetBudgeter`
5. 基于 `MemoryLayer` / `MemoryKind` 的主导型检索思路

原因不是这些概念完全没用，而是它们描述的是存储与温度治理，不足以表达 frontier、counterexample、verification debt 这些会直接改变动作选择的对象。后续如果保留，也应该只作为 secondary metadata，而不是 planner 的核心轴。

#### 应计划删除的 rollout 与 UI 暴露

如果 RMS 进入主线，下面这类开关和 UI 文案不能长期保留旧名字，否则产品语义会持续误导：

1. `AppSettings` 里的旧 rollout 命名与 bridge 字段
2. `SettingsMemoryView` 里对应的 toggle 与旧说明文案
3. `MemoryManagementViewModel` 和 memory 管理面板里只围绕 `lifecycleTier`、`admissionExplanation` 展示价值的视图逻辑
4. `MemoryRuntimeSnapshotViewModel` 中仍把 `Legacy layer-based retrieval` 作为核心解释的文案

这些对象可以在迁移初期以兼容别名存在，但必须设置删除时点，而不是无限期叠加。

### 8.7 迁移冻结快照（2026-03-14）

当前仓库状态已经形成一版可执行的 sunset 冻结点，可作为后续删除 legacy 概念的依据：

1. `TaskMemory` 直接语义写入：`compatibility-only`
说明：写路径已收窄为 `episode-delta` 兼容层，读取端仍保留旧 tag 的 backward compatibility。
2. `MemoryLifecycleTier`：`removed`
说明：生命周期层级字段、展示与 rebalance 路径已从代码主线删除，不再作为 planner、snapshot 或治理 UI 的概念存在。
3. 旧 rollout flags：`removed`
说明：`enableAdmissionV2`、`enableGoalConditionedRetrieval`、`enableLifecycleManager`、`enableExperienceDistillation` 已从代码主线删除，统一收敛到 RMS 命名字段。

同一天的验证结果也应一并冻结，避免后续讨论时把“定向回归通过”和“全量 smoke 通过”混为一谈：

1. Tasks 1-9 组合定向回归通过，共 64 个 targeted tests。
2. `Quality Smoke` 仍失败，但当前失败集中在现有 UI smoke 项：`ChatFlowUITests`、`SessionManagementUITests`、`ToolCallUITests`、`WorkflowRecoveryUITests`。
3. 因此可以认定 RMS 迁移主链当前为 `targeted-green / smoke-red`，后续需要单独处理 UI smoke 基线，而不是回滚 RMS 语义迁移。

## 9. 产品与工程层的预期收益

如果 RMS 成功落地，收益不应只体现在“命中更多记忆”，而应体现在以下结果：

1. agent 在长任务中的重复错误明显下降。
2. 面对相似失败场景时，恢复路径更快收敛。
3. verify 和 reflection 不再像事后补丁，而是由 frontier memory 统一驱动。
4. prompt 长度不一定显著增加，但单位 token 的决策效率更高。
5. 用户能看到 memory 为什么影响了当前行动，而不是只能看到它被展示了出来。

对 agentGui 这种 coding agent 来说，最直接的表现会是：

1. 少走重复的错误修复路径。
2. 更早识别“证据不足但仍在硬做”的局面。
3. 更稳定地区分经验、事实、约束和反例。
4. 在多轮修复任务里保持更一致的完成标准。

## 10. 风险与约束

### 10.1 最大风险不是实现复杂，而是把语义做虚

如果只是给现有 record 再加几个字段，却没有让 host runtime 真正基于 frontier 和 decision impact 做动作选择，那么 RMS 会退化成“更复杂的 memory schema”。

### 10.2 不应把原始 chain-of-thought 直接当长期记忆写入

agent-first memory 需要 reasoning residue，而不是原始隐式推理文本。应优先保存：

1. 被验证过的中间结论。
2. 被证伪的假设。
3. 适用条件明确的 tactic kernel。
4. 失败原因与替代路径。

而不是无筛选地保存完整思维链。

### 10.3 不应让 counterfactual 评估变成高成本内环

Decision Delta Test 和 impact ranking 不要求每轮都做昂贵模拟。第一阶段完全可以用启发式近似：

1. 该记忆是否改变工具选择。
2. 是否改变验证顺序。
3. 是否改变 stop/go 判断。
4. 是否曾在相似失败中触发恢复。

只有高风险 frontier 才值得进入更深的 test-time compute 分析。

## 11. 推荐的迁移路线

### Phase 0：先定义提取协议，再允许新对象入场

在真正写新 store 和新 planner 之前，先补齐运行时抽取协议：

1. 定义 `EpistemicInputEnvelope` 和 `Atomic Epistemic Event`。
2. 在 agent loop 中明确消息、工具结果、review、测试、diff 如何进入抽取器。
3. 先做 runtime-only 的 frontier / constraint / debt / counterexample 提取，不急着长期持久化。

目标是先验证“能不能稳定抽出来”，再决定“以什么 schema 存下去”。

### Phase 1：把 unresolved frontier 引入现有 runtime

先不动底层 store，优先新增：

1. `EpistemicState`
2. `FrontierMemory`
3. `VerificationDebt`
4. `MemoryInfluenceTrace`

目标是让系统先能表达“当前缺什么”，而不是只会表达“当前有什么”。

### Phase 2：引入 negative memory 和 kernel distillation

在现有 background jobs 上新增：

1. `CounterexampleDistillationJob`
2. `TacticKernelDistillationJob`
3. `MemoryInvalidationJob`

目标是让 memory 具备真正的自我修正能力。

### Phase 3：把 retrieval planner 改成 decision impact planner

逐步替换 top-k / static budget 风格的 retrieval 逻辑，引入：

1. frontier-aware retrieval intent
2. counterexample-first retrieval mode
3. high-risk branch extra budget
4. influence trace output

### Phase 4：让 verify、reflection、memory 使用同一套 epistemic state

这一步很关键。memory、verify、reflection 如果继续各自维护自己的摘要对象，系统仍然会回到多套状态并存、信息不断丢失的问题。

最终应统一到：

1. open claims
2. evidence refs
3. counterexamples
4. repair queue
5. stop conditions

### Phase 5：系统性清理旧概念，禁止双语义长期共存

当 `EpistemicState` 已成为主链输入后，应启动一轮显式清理，而不是继续兼容：

1. 将 `MemoryLifecycleTier`、layer-first retrieval、旧 admission score 降级为兼容字段或删除。
2. 删除 `MemoryExperienceDistillationService` 与 `MemoryProcedureInductionService`，统一由 RMS distillation 服务承担产出。
3. 移除 `AppSettings`、`SettingsMemoryView`、`MemoryManagementViewModel` 中不再对用户有意义的旧 rollout 开关和文案。
4. 清理只验证旧语义的测试，改为围绕 frontier extraction、counterexample activation、verification debt、influence trace 建立新测试基线。
5. 为每个 legacy type 标注 sunset 版本与删除条件，避免“先 deprecated，后永久遗留”。

这里的关键不是代码洁癖，而是保证系统里同时只存在一套真正驱动决策的 memory 语义。

## 12. 最终建议

如果只想在现有基础上做稳妥增强，那么继续强化 admission、retrieval、lifecycle、explanation 当然仍然有价值。但这条路的上限已经逐渐清楚：它会得到一个更可治理、更可观测的 memory system，却不一定得到一个真正更会思考的 agent。

如果目标是让 agentGui 进入下一阶段，memory 的设计对象必须从“记录”改成“认知控制”。

因此，建议后续技术路线不再把 memory 视为：

`长期存储 + 检索 + 压缩`

而应把它重新定义为：

`frontier management + counterexample activation + tactic distillation + verification debt control`

只有这样，memory 才会从传统软件工程里的 supporting subsystem，转成真正属于 agent runtime 的 cognitive substrate。

## 13. 一句话版本

适合写入后续架构文档的定义如下：

`下一代 memory 不应再是面向记录的控制平面，而应是面向决策改变量的推理基底：它持续维护 agent 的未决前沿、约束、反例、策略 kernel 与验证债务，并只在这些对象会改变下一步动作或停止条件时让它们进入高影响推理。`