# verify 能力升级技术说明：从 agent-first 视角重写

日期：2026-03-14

## 1. 结论先行

前一版说明的根本问题，不是结论错了，而是 framing 仍然偏传统软件设计：它默认先有一个主流程，再在流程末端挂一个 verifier、coordinator、gate、state machine，把 verify 当成一个“附加模块”。

这不是 agent-first。

从 agent-first 角度看，verify 不是流程尾部的审批节点，而是 agent 在不确定环境中维持任务正确性的持续能力。它本质上是一个运行时认知回路，负责五件事：

1. 识别当前完成声明里哪些内容只是模型猜测，哪些内容有外部证据支撑。
2. 维护一个可持续更新的“未决问题前沿”，而不是每轮重新通读整段历史。
3. 决定下一单位验证预算该花在什么地方：跑命令、读 diff、调 reviewer、做检索、还是直接停止。
4. 在发现反例或证据缺口时，把失败变成可执行修正，而不是只返回一个布尔值。
5. 在边际收益足够低时给出收敛证书，允许 agent 结束，而不是被动撞到 `maxRounds`。

因此，本项目正确的目标不应是“做一个更强的 verifier 子系统”，而应是把 verify 升级为 agent runtime 的内生能力：

`verification as epistemic control`

对应到实现层，真正应该建设的不是单一 `VerifierCoordinator`，而是一套围绕 claim、evidence、risk、repair 和 budget 运转的验证控制环。

## 2. 什么叫 agent-first

### 2.1 传统设计视角的问题

传统软件设计视角通常这样建模：

1. 主 agent 负责产出结果。
2. verifier 负责检查结果。
3. coordinator 负责把通过/失败路由到下一步。

这种建模的默认对象是“模块”，而不是“智能体在不确定性下的行动策略”。

它有三个自然后果：

1. verify 被放在末端，太晚介入。
2. verify 的输出被压缩成 `pass/fail`，信息损失严重。
3. 系统优化目标变成“让 verifier 更准”，而不是“让 agent 更快收敛到正确可交付状态”。

### 2.2 agent-first 的核心转向

agent-first 不是把软件架构图换成“更多 agent”。

它真正的转向是：把系统主问题从“模块如何协作”改成“agent 如何在部分可观测、预算受限、可调用工具的环境里持续减少不确定性”。

在这个视角下：

1. 任务不是一次生成，而是多轮 belief update。
2. verification 不是单次判断，而是主动信息采样策略。
3. failure 不是异常分支，而是 belief 被反例修正后的正常状态转移。
4. memory 不是日志堆积，而是 agent 的外部工作记忆。
5. stop condition 不是轮数上限，而是“继续验证的期望价值已经足够低”。

如果用更形式化的话说，可以把当前任务近似看成一个带工具动作的部分可观测决策过程：agent 不能直接看到“答案是否真的完成”，只能看到代码、测试输出、review 文本、网页证据、工具回执等局部观测；verify 的职责，就是让 agent 在这些观测上维持一个持续可更新的 epistemic state。

## 3. 相关论文与理论的真正启发

下面只保留对本项目最有工程价值的研究脉络，不做泛综述。

### 3.1 ReAct：验证必须和行动交织，而不是后置

ReAct（Yao et al., 2023）的价值不是 prompting 技巧本身，而是把“reasoning”和“acting”统一成一个 loop：模型不再先想完再做，而是边想边做、边做边修正。

对 verify 的启发很直接：

1. 验证不能只放在 `end_turn` 之后。
2. 每次关键工具执行之后，都应该允许 agent 更新对“是否完成”的判断。
3. verify 的主要对象不是最终答案文本，而是 reasoning trace 加 tool trace 的组合。

### 3.2 Toolformer 与 CRITIC：自我纠错要依赖外部工具，而不是只靠自我感觉

Toolformer（Schick et al., 2023）说明工具使用应被内化为模型行为的一部分，而不是外部补丁。

CRITIC（Gou et al., 2023）进一步说明：LLM 的自我纠错一旦接入外部工具，效果会显著强于仅靠内部自评。

对本项目的启发：

1. verify 不能只问模型“你觉得自己做完了吗”。
2. verifier 的价值不在“更会判断”，而在“更善于触发合适的外部校验动作”。
3. 代码任务中的真实证据优先级必须高于自然语言解释：测试输出、文件状态、diff、command exit status、review rejection 都是更高等级的观测。

### 3.3 Reflexion 与 ExpeL：反思应当写回经验状态，而不是一次性附言

Reflexion（Shinn et al., 2023）提出 verbal reinforcement learning，把失败经验写成语言性反馈供下一轮使用。

ExpeL（Zhao et al., 2024）强调 agent 能从经验中抽取可迁移策略，而不是只在单轮里局部修补。

对本项目的启发：

1. reflection 不应只是 verify fail 后追加一条 prompt。
2. reflection 必须写回持久化状态，至少包括失败模式、优先修复项、禁忌动作和剩余风险。
3. 下一轮 agent 不是“重新尝试”，而是“在更新后的经验状态上继续尝试”。

### 3.4 LATS、RAP、process-reward-guided search：验证本质上是搜索控制问题

Language Agent Tree Search（Zhou et al., 2023）和 RAP 系列工作说明，agent 的强弱不只取决于生成能力，还取决于是否能用 value、reflection 和 planning 去引导搜索。

2025 年 process reward-guided tree search 方向进一步说明：如果系统拥有 step-level reward 或 process-level evaluator，复杂推理和搜索会明显更稳。

对本项目的启发：

1. verify 的核心不是更细的状态机，而是更好的 frontier selection。
2. 系统必须知道“接下来验证哪一条 claim 最值”。
3. 预算控制比“所有项一视同仁地审一遍”更关键。

### 3.5 process supervision：最终对错不如中间过程是否可证

Solving Math Word Problems with Process- and Outcome-Based Feedback（2022）与 Let’s Verify Step by Step（Lightman et al., 2023）都指出：只监督最终答案不够，监督中间步骤往往更有效。

对本项目的启发：

1. `verify_completion` 只记录最终自报结论是不够的。
2. verify 必须能查看中间执行过程是否真的发生，以及是否支持最终声明。
3. 对代码任务来说，最重要的 process signals 不是 chain-of-thought，而是 command trace、file mutations、review/test artifacts 和修复轨迹。

### 3.6 CoVe、SAFE、FActScore：长答案验证必须 claim-first

CoVe（2024）强调先生成答案，再显式生成验证问题。

SAFE（2024）与 FActScore（2023）强调长文本 factuality 的基本单位不是整段文本，而是 atomic facts。

对本项目的启发：

1. verify 的基本单位必须是 claim，而不是整段 answer。
2. “通过/失败”必须能还原到具体 claim。
3. 长输出场景下，不做 atomic decomposition，验证必然不经济。

### 3.7 CRAG 与不确定性估计：不是所有 claim 都值得同等深度核查

CRAG（2024）说明检索本身也需要被校正：先判断现有检索是否可信，再决定是否补充或纠偏。

语义熵、采样一致性和后续 uncertainty work 说明：系统可以在不知道真值的前提下，先估计哪些地方更可能在胡说。

对本项目的启发：

1. verify 应先做 risk shaping，再做深度验证。
2. 不是每条 claim 都需要 multi-hop search。
3. “证据不足”与“存在反证”必须分开建模。

### 3.8 autonomous agent survey：agent 的关键部件不是模块，而是 profile、memory、planning、action、feedback 闭环

2024 年 autonomous agents survey 的统一框架基本收敛到 profile、memory、planning、action、feedback 这些层。

对本项目的直接启发是：verify 不能独立于 planning、memory、tooling 存在，它应该承担 feedback 层对整套 agent runtime 的回灌职责。

## 4. 对当前方案的重新诊断

### 4.1 当前问题不在 verifier 不够聪明

当前实现已经在往 verify state、verifier subagent、reflection hook、execution guard 这些方向演进，这些工作并不无效。但它们仍然主要围绕“怎么在 loop 里插入一个验证阶段”展开。

真正的瓶颈是：

1. verify 的对象还是“完成声明”而不是结构化 claim frontier。
2. verification state 还没有成为 agent 的一等运行时状态。
3. verifier subagent 仍更像审稿人，而不是 search policy 的一部分。
4. reflection 和 verify 之间虽然有连接，但还不是同一个 epistemic state machine。

### 4.2 当前 framing 仍然偏“审批流”

如果系统的心智模型是：

`主 agent -> verifier -> 通过/失败 -> reflection`

那它依然是审批流。

agent-first 的更合理模型应该是：

`主 agent runtime -> 维护 claim/evidence/risk state -> 调用 specialist critique/probe -> 更新 belief -> 决定修复/继续/停止`

这里的 verifier 不再是唯一判断者，而是一个可被调用的 specialist policy。

## 5. 新的 agent-first 设计原则

### 5.1 verification 是策略，不是角色

verifier 可以保留，但它不应该是 verify 的唯一承载体。

更准确地说：

1. verification 是 host runtime 的控制策略。
2. verifier、reviewer、executor、web retrieval、diff reader 只是这套策略可以调动的行动器。
3. 最终完成决策由 host 持有的 verification state 收敛得出，而不是单个 subagent 的一句话决定。

### 5.2 verification state 必须是一等运行时对象

建议把验证状态显式化为：

```json
{
  "round": 3,
  "mode": "deep",
  "riskScore": 0.68,
  "claims": [],
  "evidence": [],
  "frontier": [],
  "repairQueue": [],
  "openQuestions": [],
  "expectedValueOfMoreVerification": 0.21,
  "certificate": null
}
```

其中最关键的不是字段数量，而是以下四个对象必须存在：

1. `ClaimGraph`
2. `EvidenceGraph`
3. `RiskFrontier`
4. `ConvergenceCertificate`

### 5.3 verify 必须围绕 frontier 运作

每轮 verify 的目标不应是“重新判整段话”，而应是：

1. 找出当前最重要、最不确定、最可被反例推翻的 frontier claims。
2. 选择最划算的 probing action。
3. 根据结果把 frontier 缩小。

这意味着每轮输出至少要回答两个问题：

1. 哪些未决 claim 已经关闭了。
2. 哪个 claim 现在是最值得继续验证的下一个点。

### 5.4 优先找反例，而不是优先背书

对复杂任务而言，“快速找到一个致命反例”通常比“慢慢收集很多支持证据”更有效。

因此验证策略应当优先做：

1. blocker 级 review mismatch 检查。
2. command claimed-but-not-run 检查。
3. file-state claimed-but-not-present 检查。
4. citation 或事实 claim 的矛盾搜索。

只有在高风险反例都未发现时，再做支持性背书。

### 5.5 停机条件必须是知识性的，而不是控制性的

`maxRounds` 只能是保险丝，不应是 verify 的主停止机制。

更合理的停止条件是：

1. 所有高重要度 claim 已被支持或反证。
2. 剩余 claim 即便未完全解决，也不足以改变最终交付结论。
3. 继续验证的预期价值低于成本阈值。
4. 存在不可验证项，需要降级为 `abstain` 或“带保留完成”。

## 6. 推荐架构：EVC Loop

为了避免继续沿用“verifier 模块”心智模型，这里建议把新方案描述为：

`EVC = Epistemic Verification and Correction Loop`

它不是一个独立服务，而是 host runtime 的验证控制环。

### 6.1 核心回路

```text
Observe -> Decompose -> Prioritize -> Probe -> Update -> Decide
```

对应含义：

1. `Observe`
  收集本轮代码、工具、review、测试、检索等观测。

2. `Decompose`
  把完成声明与回答拆成 atomic claims。

3. `Prioritize`
  计算 risk frontier，决定最值得验证的 claim。

4. `Probe`
  选择最合适的动作：运行命令、读 diff、调 verifier、调 reviewer、做 search、或读取现有 artifact。

5. `Update`
  更新 claim、evidence 和 risk 状态，并生成 repair queue。

6. `Decide`
  输出 `pass | revise | fail | abstain`，以及是否继续验证。

### 6.2 运行时对象

#### ClaimGraph

每条 claim 至少需要：

1. `claimId`
2. `text`
3. `type`
4. `importance`
5. `verifiability`
6. `status`
7. `dependsOn`
8. `evidenceRefs`

推荐 claim 类型：

1. `execution`
2. `file_state`
3. `behavioral`
4. `factual`
5. `coverage`
6. `policy`
7. `citation`

#### EvidenceGraph

证据不是拼接文本，而是带来源和强度的节点：

1. tool output
2. test report
3. review artifact
4. diff snapshot
5. file read span
6. web source

#### RiskFrontier

frontier score 可以先用启发式：

$$
score = importance \times uncertainty \times externality \times impact
$$

其中：

1. `importance` 表示对最终交付的影响。
2. `uncertainty` 表示当前信息不足程度。
3. `externality` 表示是否需要外部证据。
4. `impact` 表示一旦为假会不会直接推翻完成声明。

#### ConvergenceCertificate

最终不再只返回 `passed`，而应返回：

1. `decision`
2. `supportedClaims`
3. `contradictedClaims`
4. `openClaims`
5. `residualRisks`
6. `expectedValueOfMoreVerification`
7. `stopReason`

## 7. 对当前仓库的具体改造建议

### 7.1 `AgentLoopVerificationCoordinator` 的定位需要变化

它不应继续被理解成“调用 verifier subagent 然后解析 JSON 的 coordinator”。

更合理的定位是：

1. 持有并更新 `VerificationState`。
2. 驱动 claim decomposition。
3. 计算 frontier。
4. 决定下一步 probe action。
5. 在需要时才调用 `verifier`、`reviewer`、`executor` 或检索工具。

也就是说，verifier subagent 是它的一个 action backend，不是它的整个定义。

### 7.2 `verifying` phase 不应只在结束前出现一次

当前设计把 `verifying` 放在 `finalizing` 前，这对于第一版是合理的，但从 agent-first 角度还不够。

更合理的做法是把 verifying 视为可反复进入的 control phase：

1. 工具执行后可进入。
2. reviewer rejection 后可进入。
3. 计划更新后可进入。
4. 声称完成前必须进入。

因此它不是单次 terminal gate，而是 runtime 的一个常驻评估相位。

### 7.3 `verify_completion` 工具应降级为 self-report，不应再承担最终完成性语义

它应只负责：

1. 让主 agent 显式提交自己的 completion claims。
2. 提供 claim decomposition 的原始材料。
3. 为 host runtime 提供“agent 自认为哪些项已完成”的自报视图。

它不应再被用作完成真实性来源。

### 7.4 reflection 应直接消费 `VerificationState`，而不是零散失败文本

reflection 的输入至少应包括：

1. `contradictedClaims`
2. `openClaims`
3. `missingEvidence`
4. `frontier`
5. `repairQueue`

这样 reflection 才能真正输出“下一轮先修什么、先查什么、别再做什么”。

### 7.5 reviewer、executor、verifier 的关系应重新定义

建议重新分工如下：

1. `executor`
  负责创造执行证据。

2. `reviewer`
  负责创造质量反例和设计层缺陷证据。

3. `verifier`
  负责在给定 state 下帮助 host 综合判断 frontier 的闭合情况，或生成下一组验证问题。

4. `host verification loop`
  负责最终的 belief update 与 completion decision。

## 8. 推荐的最小落地顺序

### Phase 1：把 verification state 做成一等对象

先别追求更强 verifier，先把以下对象落稳：

1. `ClaimGraph`
2. `EvidenceRefs`
3. `openClaims`
4. `repairQueue`
5. `convergence fields`

### Phase 2：把 verifier 从“裁判”改成“specialist”

保留 verifier subagent，但让它输出：

1. frontier claim ranking
2. missing evidence list
3. recommended probe action
4. residual risk summary

而不是只输出 `passed`。

### Phase 3：让 verify 驱动动作选择

引入最小 probing policy：

1. `execution claim` 优先调 executor 或读工具轨迹。
2. `file_state claim` 优先读 diff 或 file span。
3. `factual claim` 优先检索。
4. `coverage claim` 优先对照任务清单。

### Phase 4：引入收敛证书

当且仅当高重要度 frontier 关闭，或者继续验证预期价值足够低时，允许真正结束。

## 9. 用一句话重新定义 verify

适合写进后续技术文档或需求文档的表述是：

`verify 不是一个末端审批模块，而是 agent runtime 在不确定性下持续维护完成性信念、主动分配验证预算并在发现反例后组织修复的认知控制环。`

这句话比“新增 verifier 子代理”和“新增 verifying phase”更接近真正的系统方向。

## 10. 最终建议

如果只从工程实现上看，当前仓库继续补 `verifier`、`verifying`、`reflection`、`execution guard`，当然可以把系统做得更稳。

但如果目标是从根上摆脱传统软件设计思路，下一阶段不应再把注意力放在“如何把 verify 模块做得更完整”，而应转到这三个核心问题：

1. agent 当前到底在维护什么可更新的验证信念状态。
2. 下一单位验证预算如何被分配到最有价值的 frontier claim。
3. 系统凭什么认为现在已经足够收敛，可以停止继续验证。

回答了这三个问题，verifier、reviewer、executor、state machine 和 prompt 才会自然地回到正确位置。

回答不了这三个问题，再多的 hook、coordinator 和 gate，最终也还是传统审批流，只是外面套了 agent 的名字。