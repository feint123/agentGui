# agentGui 类人分层记忆系统架构设计

日期：2026-03-10

对应需求：`docs/spec/2026-03-10-human-like-memory-system-requirements.md`

补充需求：`docs/spec/2026-03-10-memory-governance-operations-and-taskmemory-migration-requirements.md`

关联对象：`ContextMemory`、`TaskMemory`、`StoryMemory`、主 Agent Loop、Subagent / Workflow Runtime、SwiftData、文件型持久化记忆、Prompt 组装链路

## 1. 设计目标

本设计文档的目标，是把“类人分层记忆系统”的需求进一步落到可实现的架构层。

需要解决的不是抽象概念，而是 agentGui 中几个具体问题：

- 现有 `ContextMemory`、`TaskMemory`、`StoryMemory` 各自可用，但彼此缺少统一认知模型
- 主链路里对记忆的读取、压缩、注入、更新分散在多个服务和扩展中
- 创作记忆已经开始领域化，但编码任务、工作流任务和用户偏好还没有统一接入框架
- 记忆写入和记忆召回之间缺少统一编排，导致功能容易继续堆叠在主 loop 上

因此，本设计采取的核心策略不是重写所有记忆实现，而是增加一层统一的 memory runtime，把当前已有能力逐步收敛进去。

## 2. 目标架构总览

目标架构分成五个横向层次：

1. 输入与感知层：接收用户输入、工具输出、编辑器状态、会话状态
2. 记忆运行时层：决定本轮读什么、写什么、注入什么、延后什么
3. 领域模式层：定义创作、编码、用户偏好等不同领域的记忆 schema 与策略
4. 存储与检索层：对接 SwiftData、本地文件、向量索引、归档存储
5. 治理与观测层：处理可信度、冲突、TTL、版本、审计、可视化

对应的核心模块如下：

- `MemoryRuntimeCoordinator`
- `MemoryDomainProfileRegistry`
- `MemoryConsolidationEngine`
- `MemoryRetrievalPlanner`
- `MemoryGovernanceService`
- `MemoryStoreAdapter` 协议及其实现
- `MemoryPromptAssembler`

其中：

- Coordinator 负责“一轮请求”的统一调度
- Domain Profile 负责“不同任务该用什么记忆模型”
- Consolidation 负责“如何把低层输入提升为中高层记忆”
- Retrieval Planner 负责“如何为当前任务召回最小相关切片”
- Governance 负责“这条记忆是否可信、是否冲突、是否应归档或过期”

## 3. 分层记忆的工程映射

### 3.1 M0 到 M5 的工程定位

M0：瞬时记忆

- 实现来源：当前用户消息、当前工具原始输出、当前编辑器上下文、当前终端状态
- 典型载体：主 loop 内部临时值、未持久化的 tool result、输入解析结果
- 生命周期：单轮或单步骤

M1：短期工作记忆

- 实现来源：`ContextMemory`、消息摘要、当前目标状态、当前激活对象列表
- 典型载体：当前 conversation state、loop 内摘要对象、工作上下文切片
- 生命周期：线程级、会话级短周期

M2：中期任务记忆

- 实现来源：`TaskMemory`、当前项目当前阶段状态、任务级持续状态
- 典型载体：结构化 JSON / SwiftData 对象 / 任务级 durable state
- 生命周期：跨上下文重置，围绕单任务或单阶段

M3：情节性记忆

- 实现来源：Story timeline、scene、continuity、编码调查轨迹、研究检索轨迹
- 典型载体：事件流对象
- 生命周期：中长期

M4：语义长期记忆

- 实现来源：角色卡、世界规则、地点、风格、用户偏好、项目稳定事实、代码库稳定事实
- 典型载体：结构化实体 + 半结构化文档
- 生命周期：长期

M5：程序性与归档记忆

- 实现来源：反思结果、提示词演化、策略规则、历史版本快照、已 superseded 对象
- 典型载体：策略记录、版本快照、归档对象
- 生命周期：长期，默认冷数据

### 3.2 与当前实现的对应关系

第一阶段不改动已有功能语义，只建立统一映射：

- `ContextMemory` 作为 M1 的现有实现基础
- `TaskMemory` 作为 M2 的现有实现基础
- `StoryMemory` 的事件、场景、连续性记录映射到 M3
- `StoryMemory` 的角色、规则、地点、风格映射到 M4
- 反思结果、领域策略、归档快照逐步收敛到 M5

这意味着当前代码可以继续工作，但未来新增功能必须优先挂到统一 memory runtime 协议，而不是继续新增平行系统。

## 4. 核心模块设计

### 4.1 MemoryRuntimeCoordinator

职责：负责一轮请求中的统一记忆编排。

建议接口：

```swift
@MainActor
protocol MemoryRuntimeCoordinating {
    func prepareContext(for request: MemoryRuntimeRequest) async throws -> MemoryRuntimeContext
    func recordOutcome(_ outcome: MemoryRuntimeOutcome) async
    func scheduleConsolidation(for outcome: MemoryRuntimeOutcome) async
}
```

`MemoryRuntimeRequest` 建议包含：

- 当前 session / thread / workflow run 标识
- 当前用户请求
- 当前任务类型或 workflow role
- 当前绑定项目或工作区上下文
- 当前可用上下文预算
- 当前启用的领域 profile

`MemoryRuntimeContext` 建议包含：

- 选择后的领域 profile 列表
- 当前轮读取到的记忆切片
- 已组装的 prompt sections
- 本轮允许的写入策略
- 本轮风险与缺失信息提示

工作流程：

1. 识别当前 scope 与任务意图
2. 选择领域 profile
3. 拉取 M1 / M2 热记忆
4. 必要时召回 M3 / M4
5. 生成最小 prompt slice
6. 在轮次结束后接收 outcome
7. 决定哪些信息走热路径写入，哪些进入后台巩固

### 4.2 MemoryDomainProfileRegistry

职责：统一管理领域模式。

建议接口：

```swift
protocol MemoryDomainProfiling {
    var id: String { get }
    var version: Int { get }
    var supportedTaskKinds: Set<MemoryTaskKind> { get }
    func writePolicy(for request: MemoryRuntimeRequest) -> MemoryWritePolicy
    func retrievalPlanSeed(for request: MemoryRuntimeRequest) -> MemoryRetrievalSeed
    func consolidationRules() -> [MemoryConsolidationRule]
}
```

初期至少内置三个 profile：

- `creative-writing`
- `coding-task`
- `user-preferences`

后续 profile 可以组合使用，例如：

- `coding-task + user-preferences`
- `creative-writing + user-preferences`

选择逻辑优先级建议：

1. 显式 workflow role 指定
2. 当前会话绑定项目类型
3. 当前任务分类结果
4. 默认 profile 回退

### 4.3 MemoryRetrievalPlanner

职责：针对当前请求决定召回什么、不召回什么。

建议接口：

```swift
protocol MemoryRetrievalPlanning {
    func makePlan(
        request: MemoryRuntimeRequest,
        profiles: [MemoryDomainProfile]
    ) -> MemoryRetrievalPlan
}
```

`MemoryRetrievalPlan` 应包含：

- 需要查询的 memory layers
- 每层预算
- 每层过滤条件
- 召回排序规则
- 注入格式要求

设计重点：

- 不直接把“所有相关对象”塞进 prompt
- 优先结构化过滤，再做语义补召回
- 允许 profile 决定不同领域的优先级

示例：

创作场景中，如果用户说“继续写这一章，先确认顾沉现在的状态和北塔规则”，Planner 应优先：

- 取 M1 当前写作目标和当前场景状态
- 取 M4 中顾沉角色卡和北塔相关规则
- 取 M3 最近与顾沉、北塔相关的事件
- 不取整个项目全量人物和全量章节

### 4.4 MemoryPromptAssembler

职责：把 Retrieval Planner 的结果装配成模型可消费的最小切片。

该模块不是简单字符串拼接器，而是一个按层、按类型、按风险分组的上下文编排器。

建议输出格式：

- 当前工作记忆
- 已验证事实
- 相关事件
- 规则与约束
- 风险 / 待确认项
- 本轮不应写入的推测

创作与编码可共享外层结构，但每个 profile 的 section renderer 可以不同。

### 4.5 MemoryConsolidationEngine

职责：负责记忆巩固与升降级。

建议分成两条路径：

- 规则驱动路径：适合高确定性信息提取
- 模型驱动路径：适合反思、聚合、风格提炼、经验抽象

建议接口：

```swift
protocol MemoryConsolidating {
    func consolidate(_ outcome: MemoryRuntimeOutcome) async throws -> [MemoryCandidate]
}
```

`MemoryCandidate` 至少包含：

- 目标 layer
- 目标 kind
- 目标 scope
- payload
- source refs
- confidence
- write recommendation

Consolidation Engine 不直接写库，而是把候选交给 Governance 层判定。

### 4.6 MemoryGovernanceService

职责：统一处理可信度、冲突、TTL、版本与权限。

建议接口：

```swift
protocol MemoryGoverning {
    func evaluate(_ candidate: MemoryCandidate) -> MemoryGovernanceDecision
    func detectConflicts(for candidate: MemoryCandidate) -> [MemoryConflict]
}
```

`MemoryGovernanceDecision` 至少支持：

- `acceptHotPath`
- `acceptBackground`
- `needsUserConfirmation`
- `reject`
- `archiveOnly`

适用场景示例：

- 编码任务里，工具实证支持的构建失败信息可直接写入 M2
- 创作任务里，模型推断出的“顾沉可能喜欢林澈”不能直接写入 M4，需要用户确认或只作为推测存在于 M1

### 4.7 MemoryStoreAdapter

职责：统一存储访问协议。

建议协议：

```swift
protocol MemoryStoreAdapter {
    func fetch(_ query: MemoryQuery) throws -> [MemoryRecord]
    func upsert(_ record: MemoryRecord) throws
    func archive(_ id: MemoryRecord.ID) throws
    func markSuperseded(_ id: MemoryRecord.ID, by newID: MemoryRecord.ID) throws
}
```

第一阶段建议的实现：

- `SwiftDataMemoryStoreAdapter`
- `FileMemoryStoreAdapter`
- `ArchiveMemoryStoreAdapter`

向量检索可以第二阶段再引入为补充能力，而不是第一阶段的强依赖。

## 5. 统一数据模型设计

### 5.1 抽象记录模型

建议引入统一的抽象概念 `MemoryRecord`，作为运行时检索和治理层的通用对象。

建议字段：

```swift
struct MemoryRecord: Sendable {
    var id: String
    var layer: MemoryLayer
    var kind: MemoryKind
    var domainProfile: String
    var scope: MemoryScope
    var title: String
    var summary: String
    var payload: MemoryPayload
    var source: MemorySource
    var sourceRefs: [MemorySourceRef]
    var confidence: Double
    var verificationStatus: MemoryVerificationStatus
    var retentionPolicy: MemoryRetentionPolicy
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?
    var supersededBy: String?
    var tags: [String]
}
```

说明：

- 运行时统一使用 `MemoryRecord`
- 底层可以继续映射到不同 SwiftData 模型或文件结构
- 这样 Retrieval Planner 和 Governance 层不需要直接理解所有具体业务对象

### 5.2 scope 设计

建议 `MemoryScope` 至少支持：

- `user`
- `workspace`
- `project(projectId)`
- `session(sessionId)`
- `thread(threadId)`
- `workflowRun(runId)`

规则：

- 用户偏好默认放 `user`
- 创作 canon 默认放 `project`
- `TaskMemory` 默认放 `session`
- `ContextMemory` 默认放 `thread`

### 5.3 kind 设计

建议 `MemoryKind` 至少支持：

- `working`
- `episodic`
- `semantic`
- `procedural`
- `archive`

`working` 主要用于 M1 / M2，其他四类用于 M3 / M4 / M5。

## 6. 两类重点领域的详细设计

### 6.1 创作记忆 Profile

创作 profile 的核心对象：

- 角色
- 世界规则
- 地点
- 章节
- 场景
- 时间线事件
- 伏笔
- 连续性问题
- 风格档案

推荐映射：

- 章节 / 场景 / 时间线事件 / 连续性问题 / 伏笔状态变更：主要归 M3
- 角色 / 世界规则 / 地点 / 风格档案：主要归 M4
- 写作策略、风格修正规则、连续性修复经验：逐步归 M5

创作 profile 的召回优先级：

1. 当前写作目标和当前场景状态
2. 活跃角色卡片
3. 相关世界规则
4. 最近相关事件
5. 未解决伏笔
6. 连续性风险
7. 风格约束

写入策略：

- 明确事实可以直接 upsert 到 M3 / M4
- 推测性人物动机默认只进入 M1 或标为 inference
- 连续性冲突默认写问题对象，不直接改 canon

### 6.2 编码记忆 Profile

编码 profile 的核心对象：

- 仓库结构事实
- 构建与测试入口
- 已确认 bug 现象
- 已尝试修复动作
- 失败原因
- 受影响文件与符号
- 验证结论
- 工作区约束

推荐映射：

- 调查轨迹、修复尝试、测试过程：主要归 M3
- 已验证的项目结构、接口事实、稳定规则：主要归 M4
- 修复策略模板、失败后的恢复规则：逐步归 M5

编码 profile 的召回优先级：

1. 当前 bug / 当前任务状态
2. 最近尝试与失败原因
3. 已验证代码事实
4. 构建测试约束
5. 关键文件与关键符号上下文

写入策略：

- 只有被工具结果验证的信息才能直接升到 M4
- 模型自行猜测的 root cause 不得直接写入长期事实层
- 失败尝试适合写入 M2 或 M3，防止重复劳动

## 7. 运行时数据流

### 7.1 请求开始时

1. 主 loop 收到用户输入或 workflow 激活
2. `MemoryRuntimeCoordinator` 构造 `MemoryRuntimeRequest`
3. `MemoryDomainProfileRegistry` 选择 profile
4. `MemoryRetrievalPlanner` 生成召回计划
5. 各 Store Adapter 执行查询
6. `MemoryPromptAssembler` 组装最小切片
7. 切片注入模型上下文

### 7.2 请求结束时

1. 收集模型输出、工具结果、验证结果
2. 生成 `MemoryRuntimeOutcome`
3. 热路径写入直接更新 M1 / M2 中高确定性状态
4. 将复杂巩固任务交给 `MemoryConsolidationEngine`
5. 候选记忆经 `MemoryGovernanceService` 审核后再写 M3 / M4 / M5

### 7.3 冲突处理时

1. Governance 发现候选记忆与现有长期事实冲突
2. 若可自动 supersede，则创建新版本并标记旧版本被替代
3. 若不可自动判定，则输出待确认项
4. UI 或上层 workflow 可以请求用户确认

## 8. 与当前代码的迁移方案

### 8.1 Phase 1：只加抽象，不推翻现有实现

第一阶段建议新增：

- `MemoryLayer`
- `MemoryKind`
- `MemoryScope`
- `MemoryRuntimeRequest`
- `MemoryRuntimeContext`
- `MemoryRuntimeOutcome`
- `MemoryDomainProfile` 协议
- `MemoryStoreAdapter` 协议

这一阶段不要求把 `StoryMemoryService` 或 `TaskMemoryService` 重写，只要求能被适配。

### 8.2 Phase 2：先接入 Creative 与 Coding 两个 profile

原因：

- 这两个领域差异最明显
- 现有仓库已经有创作记忆实现基础和编码任务记忆雏形
- 用这两个 profile 足以验证架构是否合理

### 8.3 Phase 3：把 prompt 注入逻辑迁移到统一编排

当前注入逻辑分散在：

- 主 loop 对 `TaskMemory` 的加载
- Story memory bootstrap
- 各类临时摘要逻辑

目标是逐步改成：

- 所有记忆注入统一经过 `MemoryRuntimeCoordinator.prepareContext`
- 各 profile 只提供 retrieval seed 和 renderer，不直接各自拼 prompt

### 8.4 Phase 4：接入后台巩固与治理面

这一步再引入：

- 归档
- TTL
- superseded 链
- 再验证调度
- UI 级冲突治理

## 9. 测试策略

需要分四层测试。

### 9.1 协议与纯逻辑测试

测试内容：

- profile 选择逻辑
- retrieval planning
- consolidation rule
- governance decision

特点：

- 纯 Swift 单元测试
- 不依赖 UI

### 9.2 存储适配测试

测试内容：

- SwiftData adapter 的 fetch / upsert / supersede
- 文件型 adapter 的持久化一致性

### 9.3 集成流程测试

测试内容：

- 给定请求是否能生成正确 memory runtime context
- 创作 profile 与编码 profile 是否召回不同切片
- 冲突候选是否被正确拦截

### 9.4 UI 与可见性测试

测试内容：

- 用户能否看到本轮用了哪些记忆层
- 是否能区分读取、写入、待确认与回退状态

## 10. 风险与权衡

### 10.1 风险：抽象过大，短期落地慢

应对：

- 第一阶段只引入最少协议和适配层
- 不强求一次性把所有服务迁完

### 10.2 风险：领域 profile 过多后难维护

应对：

- 强制 profile 走统一协议
- 通用字段统一收敛到 `MemoryRecord`

### 10.3 风险：长期记忆污染

应对：

- 强制区分 scope
- 强制通过 Governance 层决定长期写入

### 10.4 风险：Prompt 组装继续膨胀

应对：

- Planner 只返回最小切片
- 每层预算显式化
- profile 定义注入优先级和剔除规则

## 11. 推荐的下一步实施顺序

1. 定义核心协议与枚举：Layer / Kind / Scope / Profile。
2. 为 `TaskMemory` 和 `StoryMemory` 写第一个 adapter。
3. 落地 `creative-writing` 与 `coding-task` 两个 profile。
4. 新增 `MemoryRetrievalPlanner` 与 `MemoryPromptAssembler` 的第一版。
5. 把主 loop 中现有的 task memory / story memory 注入迁到统一 coordinator。
6. 最后再做后台巩固、归档和治理 UI。

## 11.1 当前实现进度（2026-03-10）

当前仓库已经完成到“统一读路径 + 基础治理”的阶段，状态如下：

- 已落地：核心 runtime vocabulary、domain profile registry、Task/Story adapter、retrieval planner、prompt assembler、runtime coordinator
- 已接线：主 Agent loop 会优先走统一 memory bootstrap，再回退到 legacy task/story 注入路径
- 已可见：设置页增加统一运行时与治理开关；工具调用详情可以展示 runtime profiles / layers / warnings metadata
- 已有治理：`MemoryGovernanceService` 第一版静态规则已存在，`memory_write` 经过受治理包装，但底层仍写回 legacy `memory.md`
- 仍待完成：后台 consolidation、真正的统一写回路径、归档与冲突处理 UI

## 12. 结论

这套架构的重点不是“做一个更大的 memory 模块”，而是把 agentGui 现有零散记忆能力收敛成统一运行时：

- 用统一分层模型解释已有实现
- 用领域 profile 解耦创作与编码差异
- 用统一 coordinator 接管读写编排
- 用治理层控制长期记忆质量

这样后续无论是继续增强创作记忆、补齐编码记忆，还是引入研究型记忆与多代理协作，都有稳定的扩展基座，而不是继续在主 agent loop 上叠加新分支。