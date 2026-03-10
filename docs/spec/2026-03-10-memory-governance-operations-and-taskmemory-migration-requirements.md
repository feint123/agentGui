# 记忆治理操作流、周期性巩固调度与 TaskMemory 全新 Schema 迁移需求说明

日期：2026-03-10

关联对象：`MemoryManagementPanel`、`MemoryConfirmationStore`、`MemoryBackgroundWriteQueue`、`MemoryRetentionService`、`MemoryRuntimeCoordinator`、`MemoryConsolidationEngine`、`TaskMemory`、`TaskMemoryService`、`TaskMemoryStoreAdapter`、统一记忆运行时

## 1. 背景

当前统一记忆运行时已经具备以下基础能力：

- 统一读路径：`TaskMemory`、`StoryMemory`、unified store 可以被收敛成单一 prompt slice
- 统一写路径：governed write 已可落到 hot path、background、archive、pending confirmation 四条路径
- 最小治理可见性：设置页与 `MemoryManagementPanel` 已可展示统计、冲突/替代链与待确认列表
- 最小 coordinator 闭环：`recordOutcome` 与 `scheduleConsolidation` 已可驱动原始 outcome 写回与规则化巩固

但当前仍存在三个关键缺口：

### 1.1 待确认写入仍是只读状态

现在系统可以把 speculative 写入放进 pending confirmations，但用户无法在 UI 中明确执行 approve / reject，也无法看到批准后会写入什么、拒绝后会如何处置。

### 1.2 后台巩固与 TTL sweep 还只是最小即时实现

当前 `MemoryBackgroundWriteQueue` 只是一次性异步写入，`MemoryRetentionService` 也只在测试或显式调用时运行，尚未形成真正的周期性后台调度机制。

### 1.3 TaskMemory 仍停留在 legacy schema

当前 `TaskMemory` 与 `TaskMemoryService` 更接近“会话级任务日志 JSON”，虽然已能通过 adapter 接入统一运行时，但 schema 仍未成为统一 memory runtime 的一等模型。用户当前要求不再维持长期双轨，而是把 `TaskMemory` 迁移为全新的 schema，在确认迁移完成后移除老代码与旧适配器。

本需求说明用于明确这三项能力的目标范围、交互要求、迁移策略和验收标准，作为下一阶段实现与评审依据。

## 2. 目标

本轮需求目标如下：

- 让待确认写入从“可见但不可操作”升级为“可审阅、可批准、可拒绝、可追踪”的完整治理流程
- 让后台巩固与 TTL sweep 从“即时触发的最小实现”升级为“有调度周期、状态可见、失败可恢复”的后台系统能力
- 让 `TaskMemory` 从 legacy JSON schema 迁移到新的统一 schema，使其成为统一记忆运行时的正式存储层，而不是长期依赖 legacy adapter
- 在迁移完成前保证数据可校验、可回滚、可对账；在迁移确认完成后清理旧代码与兼容层

## 3. 不在本次范围

- 不引入云同步、多设备同步或远程记忆服务
- 不在本次内完成向量检索或 embedding 基础设施改造
- 不把 `StoryMemory` 一并重写为全新 schema
- 不实现复杂审批工作流，如多人审阅、批量自定义规则脚本

## 4. 功能点

### 功能点 1：待确认写入 approve / reject 操作流

需求：

- `MemoryManagementPanel` 中的待确认写入列表必须支持逐条 `approve` 与 `reject`
- 用户点击某条待确认项时，必须能看到至少以下信息：
  - 标题
  - 摘要
  - 目标 scope
  - 目标 layer / kind
  - 来源 profile
  - 生成原因
  - 批准后将写入的 record 预览
- `approve` 后系统必须：
  - 将该待确认项从 pending store 中移除
  - 通过统一写路径将对应 record 正式写入 unified store
  - 若命中冲突规则，则按 replace / supersededBy 链处理，而不是绕过治理
  - 记录审计结果，至少包括批准时间、批准动作、最终 record ID
- `reject` 后系统必须：
  - 将该待确认项从 pending store 中移除
  - 不将对应 record 写入 live store
  - 为该候选保留最小审计记录，便于后续解释“为什么没有被写入”

交互要求：

- 列表态必须清楚区分 `pending`、`approved`、`rejected`
- approve / reject 必须有明确确认动作，避免误触
- 执行后 UI 必须立即反映结果，不允许需要重启或手动刷新才能看到状态变化

最低数据要求：

- `MemoryConfirmationCandidate` 需要具备稳定 ID、状态字段、操作时间、操作结果、最终 record ID 或 rejection reason
- 若采用单文件存储 pending confirmations，则必须支持安全更新和状态迁移；也允许升级为独立 SwiftData / JSONL 审计模型

### 功能点 2：后台巩固调度器

需求：

- 系统必须具备独立于单次工具调用生命周期的后台巩固调度器
- 调度器至少负责两类工作：
  - 消费待执行的 consolidation tasks
  - 消费 background write tasks
- 调度器必须支持最小配置：
  - 是否启用
  - 调度周期
  - 最大并发数或串行模式
  - 失败重试策略
- 调度器必须可观测：
  - 最近一次运行时间
  - 上次成功时间
  - 当前队列长度
  - 最近失败原因

执行要求：

- 当 `MemoryRuntimeCoordinator.scheduleConsolidation` 产生候选时，默认进入持久化任务队列，而不是仅靠进程内瞬时任务
- 应用重启后，未消费的后台巩固任务必须能恢复，而不是丢失
- 后台任务执行失败时，不能静默吞掉；必须进入可见状态并允许重试

非功能要求：

- 不能阻塞主 Agent Loop 的热路径响应
- 在大量消息到来时，调度器需要具备节流 / 去重能力，避免为同一 session 持续创建重复 consolidation task

### 功能点 3：周期性 TTL sweep 与再验证调度

需求：

- `TTL sweep` 不能只作为手动或测试路径存在，必须由后台调度器定期执行
- sweep 范围至少包括：
  - 过期的 session-bound records
  - 长期未访问、已降温的 working / task records
  - 长期未验证的 partial / unverified records
- 对不同记录类型，应支持不同动作：
  - 直接 archive
  - 加入 revalidation queue
  - 保持不动但标记 stale

调度要求：

- sweep 周期必须可配置
- 每次 sweep 必须产出审计摘要：处理数量、archive 数量、revalidation 数量、跳过原因
- sweep 不得删除仍被活跃 session 引用的关键 records，除非存在明确 superseded / expired 依据

交互要求：

- 管理面板必须可见 TTL / sweep 的最近状态
- 用户至少可以手动触发一次 sweep，并看到结果摘要

### 功能点 4：TaskMemory 全新 schema 设计

需求：

- 现有 `TaskMemory` 必须迁移为新的统一 schema，不再长期依附 legacy JSON 形态
- 新 schema 必须直接表达统一 memory runtime 关心的信息，而不是先写 legacy 结构再投影
- 新 schema 至少需要支持：
  - session / thread / workflowRun scope
  - record-level metadata
  - verification status
  - retention policy
  - source refs
  - superseded chain
  - tags
  - attempted actions / failed attempts / confirmed facts 这类任务态信息的结构化表达

设计约束：

- 新 schema 不是简单给 legacy `TaskMemory` 加几个字段，而应重新定义其数据边界
- 新 schema 必须能作为统一写路径的直接目标
- 新 schema 必须支持与 `MemoryRecord` 的低成本互转，最好避免再通过“投影 adapter”承担核心逻辑

建议方向：

- `TaskMemory` 可以升级为“session-scoped unified record collection + task-state index”的组合模型
- 如果仍保留文件存储，应明确版本号和 migration state
- 如果改为 SwiftData，也必须说明与当前文件型数据的迁移方式和回滚策略

### 功能点 5：TaskMemory 迁移流程与切换策略

需求：

- 必须定义明确的迁移阶段，而不是在一次提交中直接删旧代码
- 迁移流程至少包含四步：
  - 定义新 schema 与双写 / 导入机制
  - 运行迁移并生成对账结果
  - 在真实数据和测试环境中确认新 schema 行为完整
  - 移除旧 `TaskMemoryService`、legacy schema、旧 adapter 与兼容分支

迁移期间要求：

- 必须能识别某个 session 是否仍是 legacy 数据、是否已迁移、是否迁移失败
- 必须保留迁移报告，至少包括总记录数、成功数、失败数、差异数
- 对于迁移失败的 session，系统必须回退到安全读取模式，而不是直接读空

切换条件：

- 只有在以下条件同时满足后，才允许移除老代码：
  - 所有受支持的 legacy `TaskMemory` 数据都已完成迁移
  - 新 schema 在读写、治理、巩固、TTL、UI 可见性上均通过验收测试
  - 对账结果达到预设阈值，且不存在高优先级数据丢失问题

### 功能点 6：旧代码清理与适配器退场

需求：

- 在迁移确认完成后，必须移除以下 legacy 资产或将其降级为只读迁移工具：
  - `TaskMemoryService`
  - 旧 `TaskMemory` schema
  - `TaskMemoryStoreAdapter` 中仅用于 legacy 投影的主路径逻辑
  - 依赖 legacy `TaskMemory` JSON 的直接调用链
- 清理完成后，统一运行时和主 Agent Loop 不应再依赖 legacy `TaskMemory` 作为权威来源

注意事项：

- 删除旧代码前必须先更新文档、测试和迁移脚本
- 如需保留 legacy reader，也应明确其仅用于恢复和导入，而不是主链路运行

## 5. 关键用户场景

### 场景 1：批准待确认写入

用户在治理面板看到“顾沉可能爱上林澈”这条 speculative semantic candidate。用户点开详情，确认这条信息在当前创作上下文中已经被明确写定，于是点击 `approve`。系统将该 candidate 从待确认列表中移除，并通过统一写路径写入 project scope 的 semantic layer。如果已有同标题旧规则，则自动建立 superseded 链。用户立即在管理面板中看到待确认数减少、semantic 记录数增加。

### 场景 2：拒绝待确认写入

用户发现某条推测性记忆不成立，点击 `reject`。系统将其从 pending 列表移除，不写入 live store，并留下 rejection 审计。后续用户查看这次工具调用时，仍能知道“该条记忆曾被提出但被拒绝”。

### 场景 3：后台巩固调度

主 Agent 在长编码任务中连续多次产出 verified facts 与 failed attempts。热路径结束后，这些 outcome 被写入调度队列。后台巩固器在下一个周期消费队列，把重复失败尝试整合为 failure chain，把稳定 verified fact 晋升为 task / semantic 记录。整个过程不阻塞前台对话。

### 场景 4：TTL sweep 与再验证

系统定期扫描 unified store，发现一批 session-bound records 已过期，同时几条 오래된 partial records 长期未再验证。过期记录被归档，partial records 被加入 revalidation queue。用户打开治理面板时，可以看到本次 sweep 的处理摘要。

### 场景 5：TaskMemory schema 迁移

应用升级后，系统识别到某些 session 仍使用 legacy `TaskMemory` JSON。迁移器读取旧数据，转换为新 schema，生成迁移报告和对账结果。若转换成功，该 session 后续全部从新 schema 读取；若转换失败，则保留 legacy reader 兜底并提示需要修复。待全部迁移确认完成后，再移除旧服务与 adapter。

## 6. 数据与状态要求

### 6.1 待确认项状态机

待确认项至少应支持以下状态：

- `pending`
- `approved`
- `rejected`
- `failedToApply`

每个状态变更都必须记录时间、操作者语义和结果摘要。

### 6.2 后台任务状态机

后台巩固 / sweep 任务至少应支持：

- `queued`
- `running`
- `completed`
- `failed`
- `cancelled`

任务需要具备稳定 ID、任务类型、目标 scope、创建时间、最后运行时间、失败摘要。

### 6.3 TaskMemory 迁移状态

每个 session 或对应数据文件至少应可识别：

- `legacy`
- `migrating`
- `migrated`
- `migrationFailed`

## 7. 非功能要求

- 数据安全：approve / reject / migration / sweep 都不能产生静默数据丢失
- 可恢复：应用中断后，pending confirmations、后台任务、迁移状态必须可恢复
- 可观测：管理面板和日志中必须能看到关键治理动作
- 一致性：同一条记录不能同时被视为 pending、live、archived 多种互斥状态
- 可测试：三项能力必须都有 focused tests 和至少一组迁移/调度集成测试

## 8. 验收标准

1. 用户可以在治理面板中对待确认写入执行 approve / reject，且状态立即更新。
2. `approve` 后对应 record 进入 unified store；`reject` 后不会进入 live store，但会留下审计结果。
3. 管理面板可以展示 pending、approved、rejected 的数量或最近记录。
4. 后台巩固任务在应用重启后不会丢失，且能够被继续消费。
5. TTL sweep 可以按配置周期自动运行，并生成可见的处理摘要。
6. `TaskMemory` 新 schema 能覆盖当前统一运行时所需的任务态信息，不再依赖 legacy 投影作为主链路。
7. 存在可执行的迁移流程，能够把 legacy `TaskMemory` 数据迁移到新 schema，并生成对账结果。
8. 在迁移确认完成前，旧数据不会因为新 schema 上线而变成不可读。
9. 迁移确认完成后，旧 `TaskMemoryService` 与旧 adapter 可以被移除，且 memory 相关测试仍通过。

## 9. 优先级

- P0：待确认 approve / reject、后台巩固调度器、TaskMemory 新 schema 设计
- P1：周期性 TTL sweep、迁移报告与对账、管理面板状态扩展
- P2：批量审批、复杂 revalidation 策略、legacy 导入工具的长期保留策略

## 10. 与现有文档关系

- 本文档是对 `docs/spec/2026-03-10-human-like-memory-system-requirements.md` 的补充与收敛，聚焦已经进入实现阶段的三个高风险能力。
- 对于 `TaskMemory`，本文档显式覆盖了早期“长期保持 adapter 兼容优先”的策略：兼容可以作为迁移阶段手段，但不再是最终目标。
- 若本文档与早期计划文档中“暂不重写 TaskMemoryService”的表述冲突，以本文档为新的需求约束。

## 11. 后续建议文档

建议在本文档基础上再补两份配套文档：

- 迁移设计文档：定义 `TaskMemory` 新 schema、迁移算法、对账方式与回滚策略
- 调度设计文档：定义后台巩固队列、TTL sweep scheduler、任务持久化模型与恢复机制