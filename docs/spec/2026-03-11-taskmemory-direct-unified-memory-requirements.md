# TaskMemory 直接并入统一 Memory 架构需求说明

日期：2026-03-11

关联对象：`TaskMemory`、`TaskMemoryService`、`TaskMemoryStoreAdapter`、`MemoryRecord`、`UnifiedMemoryStoredRecord`、`UnifiedMemoryFileStoreAdapter`、`MemoryRuntimeCoordinator`、主 Agent Loop

## 1. 背景

当前项目中的 `TaskMemory` 仍然是独立的 legacy JSON 模型，主链路形态如下：

- `TaskMemoryService` 负责把 `TaskMemory` 持久化到 `~/.agentgui/task-memories/<sessionId>.json`
- `TaskMemoryStoreAdapter` 在读取阶段把 `TaskMemory` 投影为 `[MemoryRecord]`
- `MemoryRuntimeCoordinator` 通过 `taskRecordsProvider` 把这批投影结果并入统一运行时上下文

这意味着 `TaskMemory` 目前并不是统一 Memory 架构中的一等存储实体，而只是一个被读取时再转换的 legacy 中间层。其直接问题包括：

- 任务记忆存在双重 schema：写入写到 `TaskMemory`，读取时再转换成 `MemoryRecord`
- 统一记忆运行时读到的是投影结果，而不是原生统一记录，导致行为边界分裂
- `TaskMemoryStoreAdapter` 承担了事实、尝试、失败、问题等任务态到统一记录的核心映射逻辑，增加理解和维护成本
- `MemoryRuntimeCoordinator` 需要感知 TaskMemory 的特殊读取方式，无法把 session 级任务记忆完全视为统一 store 的自然组成部分
- 后续治理、归档、冲突处理、替代链和迁移对账都必须同时考虑 legacy JSON 与 unified store 两套来源

本需求的目标不是继续维持 adapter-based 兼容，而是把 `TaskMemory` 直接改造成统一 Memory 架构的一部分，并移除适配器相关主路径代码。

## 2. 目标

本次需求目标如下：

- 让 session 级任务记忆直接以统一 Memory schema 表达，而不是先写 legacy `TaskMemory` 再投影
- 让 `MemoryRecord` / `UnifiedMemoryStoredRecord` 成为 TaskMemory 主链路的唯一权威数据模型
- 让 `MemoryRuntimeCoordinator` 直接从统一 store 读取 session scope 的任务记录，不再依赖 `TaskMemoryStoreAdapter`
- 移除 `TaskMemoryService`、`TaskMemoryStoreAdapter` 以及围绕 legacy TaskMemory JSON 的主路径调用链
- 为已有 `TaskMemory` 历史数据提供一次性迁移能力，并在迁移完成后删除兼容分支

## 3. 不在本次范围

- 不在本次内重写 `StoryMemory` 的整体存储形态
- 不引入新的远程同步、云端记忆或向量检索基础设施
- 不改变统一记忆治理的总体策略，只收敛 TaskMemory 的存储和读写架构
- 不要求保留长期双写；兼容仅允许存在于迁移阶段

## 4. 现状问题定义

### 4.1 数据权威源分裂

当前任务记忆的真实写入源是 `TaskMemory` JSON，而统一运行时使用的是 `TaskMemoryStoreAdapter.project(memory:)` 生成的 `[MemoryRecord]`。这会导致“持久化数据结构”和“运行时消费结构”不一致。

### 4.2 统一治理无法覆盖 TaskMemory 原生写入

统一架构已经围绕 `MemoryRecord`、`UnifiedMemoryStoredRecord`、`MemoryStoreAdapter` 建立了 `persist / replace / archive / touch` 能力，但 `TaskMemory` 仍绕开这套主存储契约，保留独立文件写入逻辑。

### 4.3 适配器成为业务逻辑中心

`TaskMemoryStoreAdapter` 并非简单格式转换，而是在定义：

- 什么是 task layer record
- confirmed fact / attempted action / failed attempt / pending question 各自映射到什么 kind、verification status、tags、retention policy
- ID 如何生成

这些本应属于统一 memory schema 的业务规则，不应长期藏在 adapter 中。

### 4.4 读取链路复杂且不自然

`MemoryRuntimeCoordinator` 当前同时组合：

- TaskMemory 投影结果
- StoryMemory 投影结果
- unified store 原生结果

其中只有 TaskMemory 仍需要单独读 legacy 数据再转换。这违背了统一架构的目标。

## 5. 目标架构

### 5.1 核心原则

- session 级任务记忆必须直接落入 unified store
- 统一 store 中的 session scope records 必须成为 TaskMemory 唯一权威来源
- 任务态信息以统一 record 表达，不再维护独立的 `confirmedFacts`、`attemptedActions`、`failedAttempts`、`pendingQuestions` 数组作为主存储
- 若仍需保留“TaskMemory”这一概念，它只能是统一记录上的领域视图或构建器，而不是独立持久化 schema

### 5.2 推荐形态

推荐将 TaskMemory 收敛为以下两层之一：

- 方案 A：彻底取消独立 `TaskMemory` 持久化模型，统一以 `MemoryRecord` + `UnifiedMemoryFileStoreAdapter` 表示 session task memory
- 方案 B：保留一个轻量 `TaskMemoryDomain` 或 `TaskMemoryQuery` 作为领域视图，但其底层读写必须完全基于 unified store，不得再持有独立 JSON schema

本需求推荐采用方案 A。原因如下：

- 可以真正移除 adapter，而不是换一个名字保留同类中间层
- 可以让写路径、读路径、治理路径和迁移路径全部围绕同一套 record 模型展开
- 可以减少 `TaskMemory` 与 unified runtime 之间的概念重复

## 6. 功能需求

### 功能点 1：TaskMemory 直接写入 unified store

需求：

- 所有原本写入 `TaskMemoryService` 的任务记忆内容，必须改为直接生成 `MemoryRecord`
- 写入目标必须是 `UnifiedMemoryFileStoreAdapter` 或后续同等统一存储实现
- 每条任务记忆必须显式携带统一字段：
  - `scope`
  - `layer`
  - `kind`
  - `domainProfile`
  - `verificationStatus`
  - `retentionPolicy`
  - `source`
  - `sourceRefs`
  - `tags`
  - `createdAt / updatedAt`

约束：

- 不允许先组装 legacy `TaskMemory` 再转换
- 不允许在 unified 写入前再经过 `TaskMemoryStoreAdapter.project(memory:)` 一类投影步骤

### 功能点 2：TaskMemory 直接从 unified store 读取

需求：

- `MemoryRuntimeCoordinator` 必须把 session 级 task records 视为 unified store 的普通读取结果
- TaskMemory 相关读取不得再依赖 `TaskMemoryService.load(sessionId:)`
- `prepareContext(for:)` 在组装 session 范围任务记忆时，必须直接读取 session scope unified records

结果要求：

- 统一运行时不再区分“TaskMemory 投影记录”和“Unified store 原生记录”
- 对 task memory 的 `touch`、过滤、预算裁剪、排序逻辑统一适用于同一批 records

### 功能点 3：任务态语义改由统一 record 约定表达

需求：

- 以下 legacy 任务态必须被重新定义为统一记录约定，而不是数组字段：
  - confirmed facts
  - attempted actions
  - failed attempts
  - pending questions
  - verification entries
- 每种任务态必须定义最小映射约定，至少包括：
  - 推荐的 `layer`
  - 推荐的 `kind`
  - 推荐的 `verificationStatus`
  - 推荐的 `retentionPolicy`
  - 必备 tag
  - payload 结构

最低约定建议：

- confirmed fact：`layer = .task`，`kind = .working` 或更明确的 task fact kind，`verificationStatus = .verified`，tag 包含 `confirmed-fact`
- attempted action：`layer = .task`，`verificationStatus = .partial`，tag 包含 `attempt`
- failed attempt：`layer = .task`，payload 至少包含 `action` 与 `reason`，`verificationStatus = .failed`，tag 包含 `failed-attempt`
- pending question：`layer = .task`，`verificationStatus = .unverified`，tag 包含 `pending`

说明：

- 如果现有 `MemoryKind` 不足以清晰表达这些任务态，可在统一 schema 中扩展 `MemoryKind`，但不能回退到独立 TaskMemory schema。

### 功能点 4：移除适配器相关主路径代码

需求：

- 以下代码不应继续存在于主链路：
  - `TaskMemoryService`
  - `TaskMemoryStoreAdapter`
  - `MemoryRuntimeCoordinator` 中基于 `TaskMemoryStoreAdapter` 的 `taskRecordsProvider`
  - 任何依赖 `~/.agentgui/task-memories/` 作为任务记忆权威源的调用链

允许的过渡形态：

- 可以保留只用于数据迁移的 legacy reader，但必须：
  - 不参与日常读写主链路
  - 命名上显式体现 migration/import 用途
  - 在迁移完成后可被彻底删除

### 功能点 5：迁移历史 TaskMemory 数据

需求：

- 系统必须能够识别 legacy `TaskMemory` 文件
- 系统必须提供一次性迁移，将 legacy JSON 数据转换为 session scope unified records
- 迁移过程必须输出对账结果，至少包括：
  - session 数量
  - legacy 文件数量
  - 生成 record 数量
  - 成功数
  - 失败数
  - 差异或跳过原因

迁移要求：

- 迁移后的 session 应只从 unified store 读取
- 迁移失败的 session 必须被标记，并可重新执行迁移
- 在迁移确认完成前，不允许直接删除原始 legacy 文件

### 功能点 6：清理文档、测试与配置说明

需求：

- README 中关于“TaskMemory 仍是 adapter-based”的描述必须更新
- 技术架构文档中 TaskMemory 读侧 adapter 的表述必须调整为 direct unified architecture
- 测试必须从“adapter 投影正确”转为“统一记录读写正确”

必须清理或替换的测试类型包括：

- `TaskMemoryStoreAdapterTests`
- 依赖 legacy TaskMemory 文件读写作为主验证路径的测试
- 依赖 `TaskMemoryService` 的主链路行为测试

## 7. 数据模型要求

### 7.1 权威模型

TaskMemory 主链路的权威模型必须是以下之一：

- 运行时模型：`MemoryRecord`
- 持久化模型：`UnifiedMemoryStoredRecord`

要求：

- 两者之间转换必须是直接且低成本的
- 任何 TaskMemory 语义不得只存在于 legacy JSON 专属字段中

### 7.2 Scope 要求

TaskMemory 直接并入统一架构后，至少必须支持：

- `session` scope 作为默认任务记忆边界
- 未来可扩展到 `project`、`thread`、`workflowRun`，但本次至少不能阻断这些扩展

### 7.3 来源标记要求

对于由 TaskMemory 语义写入 unified store 的记录，允许继续使用 `source = .taskMemory` 作为来源标记，但该标记仅表示来源语义，不表示仍然存在独立 TaskMemory 存储。

## 8. 迁移与切换策略

### 8.1 迁移阶段

迁移至少分为四步：

1. 定义 direct unified TaskMemory 的 record 约定与写入入口
2. 增加 legacy 导入器，把历史 `TaskMemory` JSON 转为 unified records
3. 将主读取链路切到 unified store，并完成回归验证
4. 删除 `TaskMemoryService`、`TaskMemoryStoreAdapter` 和 legacy 主链路代码

### 8.2 切换条件

只有在以下条件同时满足后，才允许删除 legacy 代码：

- 历史 TaskMemory 数据迁移已完成或明确放弃
- 统一运行时在 session task memory 读取上不再依赖 adapter
- 相关测试全部迁移到 unified path 并通过
- README、技术文档、用户可见说明已更新

### 8.3 回滚要求

- 若迁移阶段发现 unified 映射规则错误，允许重新执行导入
- 回滚应以“重新导入或重新构建 unified records”为主，而不是恢复长期双轨运行
- 任何回滚机制都不应把 `TaskMemoryService` 重新恢复为长期权威源

## 9. 非功能要求

- 一致性：同一 session task memory 不得同时由 legacy JSON 和 unified store 共同作为权威源
- 可维护性：任务态语义规则必须集中定义在统一 schema 或构建器层，而不是散落在 adapter 中
- 可观测性：迁移、导入、读取失败必须有日志或审计信息
- 可测试性：必须覆盖 direct unified read/write、迁移正确性、历史数据兼容导入三类测试
- 可清理性：迁移完成后，adapter 相关主路径代码可以物理删除，而不是长期保留死代码

## 10. 验收标准

1. 新产生的 TaskMemory 相关数据不再写入 `~/.agentgui/task-memories/`。
2. `MemoryRuntimeCoordinator` 在准备上下文时，不再通过 `TaskMemoryStoreAdapter` 获取 session task records。
3. session 级任务记忆可以直接从 unified store 读取、排序、预算裁剪和 `touch`。
4. confirmed facts、attempted actions、failed attempts、pending questions 均能以统一 record 正确表达。
5. 历史 legacy `TaskMemory` 数据可以迁移到 unified store，并产出对账结果。
6. 迁移完成后，`TaskMemoryService` 与 `TaskMemoryStoreAdapter` 可以从主工程中删除或仅保留为短期迁移工具。
7. README 与架构文档中不再把 TaskMemory 描述为 adapter-based 读侧来源。
8. 相关测试通过，且不再依赖 adapter 投影作为正确性前提。

## 11. 影响范围

本需求预计至少影响以下模块：

- `agentGui/Models/TaskMemory.swift`
- `agentGui/Services/TaskMemoryService.swift`
- `agentGui/Services/TaskMemoryStoreAdapter.swift`
- `agentGui/Services/MemoryRuntimeCoordinator.swift`
- `agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- `agentGui/Models/MemoryRecord.swift`
- `agentGui/Models/UnifiedMemoryStoredRecord.swift`
- `agentGuiTests/TaskMemoryStoreAdapterTests.swift`
- memory runtime 相关集成测试
- README 与 memory / architecture 相关文档

## 12. 与既有文档关系

- 本文档聚焦 `TaskMemory` 直接并入统一 Memory 架构，属于更窄、更强约束的专项需求说明。
- 若与 `docs/spec/2026-03-10-memory-governance-operations-and-taskmemory-migration-requirements.md` 中关于“迁移阶段保留 adapter”或更宽泛范围的表述冲突，以本文档为准。
- 本文档不讨论 pending confirmation、后台调度器、TTL sweep 的完整需求，仅要求它们未来面对 TaskMemory 时应基于 unified records 运作，而不是基于 legacy TaskMemory。