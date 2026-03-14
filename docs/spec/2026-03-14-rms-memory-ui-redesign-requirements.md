# RMS Memory UI 重设计需求文档

日期：2026-03-14

状态：需求草案

## 1. 背景

当前 memory 相关 UI 主要由以下对象构成：

1. `MemoryManagementPanel`
2. `MemoryRuntimeSnapshotPanel`
3. `MemoryRuntimeSnapshotCharts`
4. `MemoryRuntimeSnapshotRecordList`
5. `MemoryConflictList`
6. `MemoryConfirmationList`
7. `SettingsMemoryView` 中面向治理面板的入口与 rollout 配置展示

这套界面的出发点是 memory control plane 的治理与可观测性，因此它强调的是：

1. scope / layer 统计
2. 归档数量与 sweep 报告
3. 待确认写入与冲突记录
4. 候选 / 入选 / 排除记录
5. prompt 字符数和 budget 分布
6. rollout flag 状态

这些信息对实现早期的系统治理有价值，但它们已经不适合当前 RMS 语义。

RMS 的核心对象不再是 record store 的运营状态，而是：

1. frontier
2. counterexample
3. constraint
4. verification debt
5. influence trace
6. next-action shaping

因此，当前 memory UI 的根本问题不是“文案旧了”，而是信息架构仍然围绕存储层、治理层和调试层展开，无法回答用户真正关心的问题：

1. 当前 agent 还卡在哪些未决前沿。
2. 哪些反例正在阻止错误动作。
3. 哪些约束正在限制当前方案。
4. 为什么系统建议下一步做这个动作。
5. 当前还欠哪些验证，完成风险在哪里。

结论很直接：`当前 memory UI 不应继续迭代修补，而应整体下线，改为 RMS-native 的认知状态界面。`

## 2. 产品定位

新的 RMS memory UI 首先服务于用户对 agent 当前认知状态的理解，而不是服务于开发者查看底层 store 和治理流水。

默认定位如下：

1. 主定位：面向用户的运行时认知面板
2. 次定位：少量面向调试的辅助信息
3. 非定位：统一存储库浏览器、治理运营后台、历史兼容面板

这意味着新的界面不再以“记录有多少、按 layer 怎么分布、哪些候选待审批”为主叙事，而应以“系统现在知道什么、不知道什么、接下来为何行动”为主叙事。

## 3. 设计目标

### 3.1 核心目标

1. 让用户能在一个界面内理解当前 RMS 的认知状态。
2. 让 memory 的价值以“如何改变下一步动作”而不是“存了多少条记录”被呈现。
3. 让 frontier、counterexample、constraint、verification debt 成为一等可见对象。
4. 让当前轮或当前任务的 memory influence 可被解释，而不是只显示底层快照。
5. 移除不再属于主产品语义的治理型、统计型和 rollout 型 memory 视图。

### 3.2 非目标

1. 不保留当前 memory 治理工作台的交互结构。
2. 不保留当前 snapshot 图表和 layer 预算表作为主界面。
3. 不为历史 snapshot 数据提供兼容浏览 UI。
4. 不在第一版中提供全量 unified memory store 浏览器。
5. 不把当前 approval / reject / conflict resolution 工作流包装成用户主界面的一部分。

## 4. 方案比较

### 方案 A：RMS 认知面板，用户语义优先

将 memory UI 重构为一个单一的“RMS 认知面板”，主视图只呈现 frontier、counterexample、constraint、verification debt、activated memories 和 next actions。

优点：

1. 与 RMS 的主语义一致。
2. 用户能直接理解 memory 对当前任务的作用。
3. 能显著降低“治理数据很多，但不知道为什么有用”的割裂感。

缺点：

1. 开发期调试信息会减少。
2. 原有治理工作流需要迁移到内部工具或次级入口。

### 方案 B：双层界面，用户面板 + 调试控制台

保留一个面向用户的认知面板，同时额外保留一个调试台用于查看记录、分布、sweep、写入队列等底层状态。

优点：

1. 能兼顾产品语义和开发调试。
2. 对内部开发者迁移成本较低。

缺点：

1. 两套 memory UI 会长期并存。
2. 容易再次滑回 store-centric 设计。
3. 用户入口和调试入口边界会持续模糊。

### 方案 C：完全内联，不再有独立 memory 面板

不保留独立 memory 面板，只在消息、工具调用和任务区域内联展示 frontier、counterexample 和 debt 摘要。

优点：

1. 最贴近任务流。
2. UI 数量最少。

缺点：

1. 缺少集中查看认知状态的地方。
2. 不利于长任务中回顾整体前沿。
3. 第一版实现风险更高，因为需要改动多个主界面区域。

### 推荐

推荐采用方案 A。

原因很简单：当前问题的核心是 memory UI 语义错位，不是入口数量太多。先建立一个清晰、单一、RMS-native 的认知面板，比保留双轨或直接分散到内联展示更稳。

## 5. 新界面需求

### 5.1 顶层对象

新的 memory UI 应被重新定义为：`RMS 认知面板`。

它不再展示“统一记录治理状态”，而是展示“当前任务的认知控制状态”。

建议主区域包含以下六个模块：

1. 当前前沿 `Frontiers`
2. 激活反例 `Counterexamples`
3. 当前约束 `Constraints`
4. 验证债务 `Verification Debt`
5. 记忆影响解释 `Influence Trace`
6. 下一步建议 `Suggested Next Actions`

### 5.2 模块要求

#### A. Frontiers

需要回答：系统当前还没解决什么。

每条 frontier 至少展示：

1. goal
2. open claim
3. impact level
4. suggested probe
5. stop condition

#### B. Counterexamples

需要回答：系统当前在避免什么错误路径。

每条 counterexample 至少展示：

1. 被推翻的错误路径摘要
2. 当前为什么仍然相关
3. 替代动作

#### C. Constraints

需要回答：当前任务有哪些明确边界。

每条 constraint 至少展示：

1. 约束摘要
2. 约束来源类型，例如 user / repo / tool / policy
3. 对当前动作的影响

#### D. Verification Debt

需要回答：当前还有哪些重要判断没被证实。

每条 debt 至少展示：

1. 待验证判断
2. 缺失证据
3. 风险等级

#### E. Influence Trace

需要回答：memory 为什么影响了这一步。

至少展示：

1. 哪些 memory object 被激活
2. 它们改变了什么动作排序或判断
3. 哪些 object 只是背景信息，哪些真正改变了策略

#### F. Suggested Next Actions

需要回答：如果现在继续，系统建议的下一步是什么。

每个建议动作至少展示：

1. 动作摘要
2. 动作理由
3. 它主要关闭哪个 frontier 或 debt

## 6. 需要移除的现有视图

本需求明确要求整体验证通过后，下列视图从产品主界面移除，而不是继续保留重命名版本：

1. `MemoryManagementPanel`
2. `MemoryRuntimeSnapshotPanel`
3. `MemoryRuntimeSnapshotCharts`
4. `MemoryRuntimeSnapshotRecordList`
5. `MemoryConflictList`
6. `MemoryConfirmationList` 在 memory 主界面中的入口
7. `SettingsMemoryView` 中旧的 memory 主界面入口

与这些视图强耦合的下列内容也应从主产品体验中移除：

1. scope / layer 分布图
2. archive / sweep 运营卡片
3. rollout flag 面板
4. candidate / selected / excluded record 列表
5. prompt 预览面板
6. 基于 store 的“最近更新记录”列表

## 7. 信息架构要求

### 7.1 入口

第一阶段建议只保留一个明确入口：从设置页或任务相关界面进入 `RMS 认知面板`。

入口命名不应再使用“治理”“快照”“上下文预算”“记录面板”等术语。

推荐命名：

1. `RMS 认知面板`
2. `当前推理记忆`
3. `任务认知状态`

推荐文案是 `RMS 认知面板`，因为它最直接，也和当前架构名一致。

### 7.2 层级

界面层级应遵守：

1. 先显示当前认知问题
2. 再显示约束与反例
3. 再显示影响解释
4. 最后才允许查看少量辅助明细

也就是说，顺序必须从“当前要做什么”而不是“底层记录长什么样”出发。

## 8. 调试信息处理原则

当前界面中仍有一部分开发期可用的信息，例如 bridge expansion 数、dereference 数、record breakdown、estimated chars。这些信息并非完全无用，但它们不应继续占据 memory UI 主界面。

本需求要求：

1. 调试信息降为 secondary details。
2. 不在第一屏展示原始 record 统计。
3. 不要求用户理解 layer、scope、candidate trimming 等内部术语。
4. 如需保留，必须折叠到“开发调试信息”区域，且默认关闭。

## 9. 验收标准

满足以下条件，才能认为新的需求被实现：

1. 当前 memory UI 中不再出现“治理工作台”“上下文快照”“layer 预算”“入选/排除记录”等旧主叙事。
2. 新界面第一屏能直接看到 frontiers、counterexamples、constraints、verification debt。
3. 用户能从界面理解“为什么建议下一步动作”。
4. 用户不需要理解 unified memory store 结构，也能看懂 memory 对当前任务的作用。
5. 当前基于治理和快照的 memory 视图及其入口已从产品主路径中移除。

## 10. 后续实施建议

这份文档只定义需求，不定义详细实现步骤。

下一步建议单独输出一份实现设计或 implementation plan，至少覆盖：

1. 新的 `RMSCognitionPanel` 结构
2. 新 view model 的数据来源与聚合方式
3. 如何把现有 `EpistemicState` 与 `MemoryInfluenceTrace` 投影为 UI sections
4. 旧视图、旧路由和旧测试的删除计划

一句话总结：`memory UI 不应再是统一存储与治理状态的控制台，而应是用户理解 agent 当前认知状态和下一步行动依据的 RMS 认知面板。`