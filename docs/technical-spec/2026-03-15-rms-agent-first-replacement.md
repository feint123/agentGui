# 2026-03-15 RMS 极简替换技术方案

日期：2026-03-15

## 1. 结论

当前 RMS 的问题不是“功能不够”，而是把一个本应服务 agent 决策的运行时，做成了一个带 profile、layer、governance、background job、snapshot、TTL、confirmation 和多组 feature flag 的 memory control plane。

这条路线天然会继续长出更多协调器、更多状态、更多兼容分支，最终让 agent memory 变成传统软件式中台，而不是 agent 的认知底盘。

本方案建议直接废弃当前 RMS 主实现，改为一套只有一条主链的 agent-first 结构：

`RMS = agent 的推理残留物运行时，而不是通用记忆平台。`

新方案只保留三类能力：

1. 维护当前任务的认知状态。
2. 沉淀少量真正会改变未来动作的长期 insight。
3. 在每轮开始前把高价值 insight 注入 prompt。

其余能力全部按“不是核心，就删除”处理，不保留兼容层，不保留旧路径，不维持双轨语义。

## 2. 当前实现的根问题

结合现有代码，当前 RMS 的复杂度主要来自以下五个根部错误。

### 2.1 把 record 当成一等对象，而不是把 decision state 当成一等对象

当前主链仍然围绕 `MemoryRecord`、`MemoryLayer`、`MemoryDomainProfile`、`MemoryRetrievalPlan` 运转。`EpistemicState` 已经存在，但更像附属投影，而不是运行时真相源。

这会导致系统更擅长回答“存了什么”，不擅长回答“现在还缺什么、下一步该做什么、哪些旧经验此刻应该阻止动作”。

### 2.2 一个任务被拆成太多 service 和阶段

当前设计把一次简单的 memory 行为拆成了 extraction、planner、budget、governance、consolidation、distillation、invalidation、snapshot、UI projection 多段流水线。每一段都可单独失败、单独 fallback、单独开关。

这不是 agent-first，而是典型传统软件控制平面思路。

### 2.3 feature flag 矩阵让语义不再单一

`enableUnifiedMemoryRuntime`、`enableEpistemicExtraction`、`enableRMSRetrieval`、`enableRMSDistillation`、`enableMemoryGovernance`、`enableMemoryTTLSweep` 这类开关把本该是单一路径的运行时拆成很多不完整组合。

最终结果不是可控，而是不可推理：代码和测试都必须假设一堆中间状态存在。

### 2.4 检索目标错了

当前 planner 仍然以 layer 预算和 task kind 为主，frontier 只是附加修饰。也就是说，它本质仍在做“分层选记录”，而不是“为当前 frontier 选会改变动作的 insight”。

如果检索目标不从第一性原理改掉，再多的 RMS 术语都会退化成复杂版 record retrieval。

### 2.5 后台 job 和治理流把主链拖重了

distillation、invalidation、TTL sweep、confirmation、governance queue 这些机制，本质都假设 memory 是一套独立运营系统，需要生命周期管理、审批流和异步维护。

对当前产品阶段，这些机制的收益远低于复杂度成本。

## 3. 第一性原理

新的 RMS 只遵守四条原则。

### 3.1 记忆只为下一步动作服务

如果一条内容不能改变 agent 的下一步动作选择、验证策略或停止条件，它就不该进入 RMS 主路径。

### 3.2 运行时只保留认知状态，不保留运营状态

RMS 关心 frontiers、constraints、counterexamples、verification debt、tactics，不关心层级、温度、审批状态、TTL、治理审计。

### 3.3 持久化只保留 reasoning residue，不保留原始过程垃圾

长期存储只接受抽取后的 insight，不接受原始对话堆叠、冗余日志、链路中间件解释文本。

### 3.4 整个系统必须只有一条主链

同一轮 memory 行为不能同时存在“新路径”和“兼容 fallback 路径”两个语义真相源。最终状态里只允许一套 RMS。

## 4. 方案对比

### 方案 A：极简 agent-first RMS

核心思路：把 RMS 收敛为 `任务态 + 长期 insight` 两层对象，删除 record-centric control plane。

优点：

1. 语义单一。
2. 代码体积最小。
3. 与 agent loop 的耦合最自然。
4. 最符合“禁止兼容性代码、禁止传统中台化”的约束。

缺点：

1. 需要直接删掉现有一批 service 和测试。
2. 会让一部分历史 memory 数据失去迁移价值。

### 方案 B：保留当前 store，只重写 coordinator

核心思路：继续保留 `MemoryRecord`、jobs、governance、snapshot store，只把 runtime 逻辑简化。

问题：

1. 旧语义仍在。
2. 删除边界不清晰。
3. 后续代码还是会被 record/model 层牵回去。

结论：不推荐。

### 方案 C：做完整 cognitive graph / event sourcing

核心思路：把 frontiers、claims、evidence、tactic、counterexample 建成图结构或事件流。

问题：

1. 设计漂亮，但明显超出当前产品阶段。
2. 会再次进入系统工程扩张。

结论：不推荐。

### 推荐结论

采用方案 A。

原因很简单：当前任务的目标不是“修好 RMS”，而是“用一套更精简、更高效、agent-first 的新实现替代旧实现，并删除历史代码”。只有方案 A 与这个目标一致。

## 5. 新 RMS 架构

### 5.1 新的真相源

新架构只保留两个一等对象。

#### 对象一：`RMSState`

作用：表示当前任务正在维护的认知状态。

建议字段：

1. `taskID`
2. `sessionID`
3. `threadID`
4. `summary`
5. `frontiers`
6. `constraints`
7. `counterexamples`
8. `verificationDebts`
9. `candidateActions`
10. `stopSignals`
11. `updatedAt`

这就是当前任务 memory 的唯一真相源。UI、prompt、继续执行判断，都从这里读。

#### 对象二：`RMSInsight`

作用：表示跨任务可复用的长期残留物。

只允许三种 kind：

1. `constraint`
2. `counterexample`
3. `tactic`

建议字段：

1. `id`
2. `kind`
3. `summary`
4. `appliesWhen`
5. `changesDecision`
6. `replacementAction`
7. `evidenceRefs`
8. `scope`
9. `confidence`
10. `updatedAt`

不再存在 `MemoryLayer`、`MemoryKind`、`MemoryDomainProfile`、`MemoryConsolidationRule` 这一整套中间语义。

### 5.2 新的五个组件

新 RMS 只有五个组件。

#### 组件一：`RMSExtractor`

输入：最近一轮对话、工具结果、旧 `RMSState`。

输出：

1. `RMSStateDelta`
2. `RMSInsightProposal[]`

它一次性完成现在分散在 event extraction、frontier synthesis、counterexample extraction、constraint/debt extraction 里的事情。

不再允许四段式 extraction pipeline 和多层 fallback。

#### 组件二：`RMSReducer`

作用：把 `RMSStateDelta` 合并进当前 `RMSState`。

原则：

1. 合并规则确定。
2. 没有异步副作用。
3. 不依赖 feature flag。

#### 组件三：`RMSInsightStore`

作用：存取长期 insight。

它是一个极简持久层，只负责：

1. `load(scope)`
2. `upsert(insight)`
3. `remove(id)`

不负责 governance、queue、tier、TTL、confirmation。

#### 组件四：`RMSSelector`

作用：从当前 `RMSState` 和可用 insight 中选出应该进 prompt 的内容。

选择目标不是相关性，而是 `decision change`。具体规则：

1. 优先 constraint。
2. 再选能阻止错误路径的 counterexample。
3. 最后选 tactic。
4. 总数严格受 budget 限制。

这里不再做 layer budget，也不做 profile routing。

#### 组件五：`RMSPromptComposer`

作用：把 `RMSState + ActivatedInsights` 直接渲染为 prompt slice。

输出结构固定为：

1. `Current Frontiers`
2. `Constraints`
3. `Known Counterexamples`
4. `Verification Debt`
5. `Preferred Next Actions`

不再混入运营指标、snapshot 统计、working set 成本解释。

## 6. 运行时流程

### 6.1 轮次开始前

1. 读取当前任务的 `RMSState`。
2. 从 `RMSInsightStore` 读取当前 scope 下全部 insight。
3. `RMSSelector` 基于当前 frontier 选出少量激活 insight。
4. `RMSPromptComposer` 生成一段统一 prompt slice。
5. 将该 slice 注入 agent loop。

### 6.2 轮次结束后

1. 收集最新用户消息、assistant 输出、工具结果。
2. `RMSExtractor` 产出新的 `RMSStateDelta` 与 `RMSInsightProposal[]`。
3. `RMSReducer` 更新当前 `RMSState`。
4. 将高置信 proposal 直接 upsert 为 `RMSInsight`。
5. 持久化新的 `RMSState`。

### 6.3 UI 刷新

UI 直接读当前 task 绑定的 `RMSState`。

不允许再使用“最近会话最新 snapshot”这种全局回退逻辑。

## 7. 保留功能与删除功能

### 7.1 必须保留的功能

新架构必须保留以下能力。

1. 当前任务的 frontier 展示。
2. 当前约束展示。
3. 反例与替代动作展示。
4. verification debt 展示。
5. 在 prompt 中注入高价值长期记忆。
6. 记忆项带 evidence refs。

### 7.2 必须删除的功能

以下能力不再属于新 RMS，必须删除。

1. `MemoryLayer` 驱动的 retrieval。
2. `MemoryDomainProfile` 与 `consolidationRules`。
3. `MemoryGovernanceService` 与 confirmation flow。
4. `MemoryBackgroundScheduler` 的 distillation、invalidation、TTL sweep。
5. `MemoryRetentionService`。
6. `MemoryConsolidationEngine`。
7. `MemoryAdmissionScore`、`MemoryAdmissionFeatureVector` 一整套 admission 打分逻辑。
8. `MemoryRuntimeSnapshotStore` 的全局 latest fallback 读取。
9. 多个 RMS rollout 开关。
10. 一切为了兼容旧 record 语义而保留的 adapter / bridge。

## 8. 代码替换边界

### 8.1 新增文件

建议新增以下文件作为新主实现。

1. `agentGui/Models/RMSState.swift`
2. `agentGui/Models/RMSInsight.swift`
3. `agentGui/Models/RMSDelta.swift`
4. `agentGui/Services/RMSExtractor.swift`
5. `agentGui/Services/RMSReducer.swift`
6. `agentGui/Services/RMSInsightStore.swift`
7. `agentGui/Services/RMSSelector.swift`
8. `agentGui/Services/RMSPromptComposer.swift`
9. `agentGui/ViewModels/RMSPanelViewModel.swift`
10. `agentGui/Views/Memory/RMSPanel.swift`

### 8.2 必改文件

1. `agentGui/Services/ClaudeService+AgenticLoop.swift`
2. `agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`
3. `agentGui/Models/AppSettings.swift`
4. `agentGui/Views/Settings/SettingsMemoryView.swift`
5. 与当前 task 详情页、tool call 详情页相关的 RMS 入口文件

### 8.3 计划删除的旧实现

以下文件默认进入删除名单。

1. `agentGui/Services/MemoryRuntimeCoordinator.swift`
2. `agentGui/Services/MemoryRetrievalPlanner.swift`
3. `agentGui/Services/MemoryRetrievalIntentClassifier.swift`
4. `agentGui/Services/MemoryPromptAssembler.swift`
5. `agentGui/Services/MemoryBackgroundScheduler.swift`
6. `agentGui/Services/MemoryGovernanceService.swift`
7. `agentGui/Services/MemoryRetentionService.swift`
8. `agentGui/Services/MemoryConsolidationEngine.swift`
9. `agentGui/Models/MemoryAdmissionScore.swift`
10. `agentGui/Models/MemoryAdmissionFeatureVector.swift`
11. `agentGui/Models/MemoryConsolidationRule.swift`
12. `agentGui/Models/MemoryGovernanceTypes.swift`
13. `agentGui/Models/MemoryConfirmationStatus.swift`
14. `agentGui/Models/MemoryConfirmationCandidate.swift`
15. `agentGui/Models/MemorySweepReport.swift`
16. `agentGui/ViewModels/RMSCognitionPanelViewModel.swift` (type name: `RMSPanelViewModel`)
17. `agentGui/Views/Memory/RMSCognitionPanel.swift` (type name: `RMSPanel`)

说明：本轮实现已删除 legacy runtime coordinator / governance / background scheduler 相关 service 与旧测试，剩余文件主要是共享值对象与 snapshot 模型。

如果其中少数文件被其他功能共用，需要先拆出共用小部件，再整体删除 RMS 旧语义，不允许把旧 service 继续留作适配层。

## 9. 设置与产品语义

### 9.1 设置项收敛

最终产品只保留以下两项设置。

1. `memoryContextBudget`
2. `memoryEnabled`

以下开关在新架构落地后全部删除：

1. `enableUnifiedMemoryRuntime`
2. `enableMemoryGovernance`
3. `enableEpistemicExtraction`
4. `enableRMSRetrieval`
5. `enableRMSDistillation`
6. `enableUnifiedMemoryWritePath`
7. `enableBackgroundMemoryConsolidation`
8. `enableMemoryTTLSweep`

如果实现阶段需要灰度，只允许在开发分支短暂存在内部编译常量，不允许把 rollout flag 带入最终主线。

### 9.2 UI 语义收敛

UI 不再展示“memory runtime metrics dashboard”。

新的 memory UI 只表达三件事：

1. agent 当前卡在哪里。
2. agent 当前不能做什么。
3. agent 下一步应该优先做什么。

## 10. 性能与复杂度预期

新的 RMS 会用以下方式降低复杂度。

1. 一轮只做一次 extraction，而不是多阶段抽取。
2. 不再有后台 scheduler 持续轮询。
3. 不再做 layer budget 分配。
4. 不再做治理与确认流。
5. UI 直接绑定 task state，不再查找 global latest snapshot。

预期效果：

1. 主链类型数量明显下降。
2. 设置项明显下降。
3. 测试面从“矩阵测试”收敛为“单主链测试”。
4. memory 语义更容易被 agent loop 和 UI 理解。

## 11. 实施策略

实施必须遵守以下顺序。

### 阶段 1：建立新主链

1. 新建 `RMSState`、`RMSInsight`、`RMSExtractor`、`RMSSelector`、`RMSPromptComposer`。
2. 接入 `AgentLoopMemoryBootstrapComposer` 和 agent loop。
3. 让新 panel 能直接展示 `RMSState`。

### 阶段 2：切换调用方

1. 设置页改接新 RMS。
2. 当前 task 详情页改接新 RMS。
3. tool call / workflow 相关入口改为读取 task-bound state。

### 阶段 3：删除历史代码

1. 删除旧 coordinator、planner、jobs、governance、snapshot fallback、旧 UI。
2. 删除旧 feature flags。
3. 删除旧测试并补新主链测试。

整个过程不保留 bridge 作为长期状态。允许短时间编译中断，但不允许为了“平滑”而保留双套运行时。

## 12. 验收标准

当以下条件全部满足时，认为新 RMS 替换完成。

1. 代码里不再存在旧 `MemoryRuntimeCoordinator` 主链引用。
2. 代码里不再存在旧 RMS feature flag 分支。
3. memory UI 只读取 `RMSState`。
4. agent loop 每轮只走一套 memory extraction 和 prompt injection 流程。
5. 长期记忆只包含 `constraint`、`counterexample`、`tactic` 三类 insight。
6. 不再有 governance、TTL、background distillation 等历史机制残留。

## 13. 一句话总结

这次重构的本质不是“把现有 RMS 再修一轮”，而是把它从一套传统 memory control plane，收敛为一套真正服务 agent 决策的极简认知运行时。