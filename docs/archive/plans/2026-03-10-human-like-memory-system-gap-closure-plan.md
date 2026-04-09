# Human-Like Memory System Gap Closure Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the remaining gaps between the current unified memory runtime and the requirements document so agentGui has a usable read-write memory loop with consolidation, governance, retention, and UI visibility.

**Architecture:** Keep the existing read-path foundation (`MemoryRuntimeCoordinator`, `MemoryRetrievalPlanner`, `MemoryPromptAssembler`, `TaskMemoryStoreAdapter`, `StoryMemoryStoreAdapter`) intact, then add the missing write-path in thin layers: write-capable adapters, governed routing, consolidation, retention, and UI surfaces. Do not rewrite `TaskMemoryService` or `StoryMemoryService` up front; wrap them behind a unified runtime contract and migrate legacy entry points only after the new path is covered by tests.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing Claude service extensions, existing TaskMemory JSON persistence, existing StoryMemory SwiftData models.

---

## 1. 差距结论

### 已完成的能力

- 统一抽象层已存在：`MemoryLayer`、`MemoryKind`、`MemoryScope`、`MemoryRecord`、`MemoryRuntimeRequest`、`MemoryRuntimeContext`
- 基础领域 profile 已存在：`creative-writing`、`coding-task`、`user-preferences`
- 统一读路径已存在：`MemoryRuntimeCoordinator` + `MemoryRetrievalPlanner` + `MemoryPromptAssembler`
- `TaskMemory` / `StoryMemory` 已有读侧映射适配器
- 主 Agent loop 已能优先注入统一记忆切片
- 设置页与工具详情页已暴露部分运行时 metadata
- 测试基座已覆盖核心类型、profile、planner、assembler、coordinator、governance、store adapter

### 仍未完成的需求

- 缺少统一写路径，`memory_write` 仍写入 `~/.agentgui/memory.md`
- `MemoryStoreAdapter` 只有读接口，没有 persist / archive / replace / touch / list 冷热记录的能力
- `MemoryConsolidationEngine` 还是空实现，没有 M0/M1 向 M2/M3/M4/M5 的流转规则
- `MemoryGovernanceService` 只能给出决策，不能驱动后台写入、归档、确认队列、拒绝审计
- 没有冲突检测、`supersededBy` 链、TTL 清理、再验证调度
- 没有编码领域的通用情节性记忆，也没有程序性记忆与归档记忆的真实存储
- UI 只显示运行时命中信息，没有记忆管理面板、待确认写入面板、冲突面板、归档面板

### 分期建议

- P0：统一写路径闭环，优先补齐 requirements 第 8、9、10、11 节中的核心缺口
- P1：巩固、冲突、遗忘、再验证，补齐 requirements 第 10、14 节
- P2：UI 管理面、用户控制、legacy 收敛，补齐 requirements 第 13 节并完成迁移收口

## 2. 实施原则

- 先补闭环，再补智能化：先让写入、治理、归档、召回能真实工作，再做更复杂的语义检索或程序性自演化。
- 先为编码任务补齐通用记忆，再扩展创作 / 工作流特化写路径。
- 继续兼容当前 `TaskMemoryService`、`StoryMemoryService`、`memory.md`，但新增路径一律走统一 runtime 协议。
- 每个阶段都先加失败测试，再做最小实现，再跑 focused tests。
- 所有新写入都必须带来源、scope、confidence、verification、retention metadata，避免继续产生不可治理的“裸文本记忆”。

## 3. 任务拆解

### Task 1: 封住当前基线并补齐写路径契约

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryStoreAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRecord.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/UnifiedMemoryStoredRecord.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedMemoryStoreContractTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: 写失败测试，固定新契约**

新增 contract tests，明确统一存储层至少要支持：

- `records(for:)`
- `persist(record:)`
- `replace(recordID:with:)`
- `archive(recordID:reason:)`
- `touch(recordID:accessedAt:)`
- `records(for:includeArchived:)`

测试同时固定以下语义：

- `lastAccessedAt` 会在读取或显式 touch 后更新
- `supersededBy` 可以把旧记录链接到新记录
- `archiveOnly` 记录不会默认进入 prompt

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/UnifiedMemoryStoreContractTests -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL，因为当前 `MemoryStoreAdapter` 只有读接口，`MemoryRecord` 也没有可持久化的 DTO。

**Step 3: 写最小实现**

- 把 `MemoryStoreAdapter` 扩成读写协议，但不要立即改所有适配器
- 增加 `UnifiedMemoryStoredRecord` 作为可编码 DTO，避免直接让带关联值的 `MemoryRecord` 背负持久化格式职责
- 在 `MemoryRuntimeTypes` 中补充读写结果类型，例如 `MemoryWriteRequest`、`MemoryWriteResult`、`MemoryArchiveReason`
- 保持现有读路径 API 不破坏已有测试

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS，且现有 `MemoryRuntimeIntegrationTests` 不回归。

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryStoreAdapter.swift agentGui/Models/MemoryRecord.swift agentGui/Models/MemoryRuntimeTypes.swift agentGui/Models/UnifiedMemoryStoredRecord.swift agentGuiTests/UnifiedMemoryStoreContractTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "feat: define unified memory write contract"
```

### Task 2: 落地统一持久化存储与基础读写适配器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryStoreAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryStoreAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedMemoryFileStoreAdapterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryStoreAdapterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryStoreAdapterTests.swift`

**Step 1: 先写失败测试**

新增文件型统一存储测试，覆盖：

- 同 scope 的多条记录可持久化并按 layer 读取
- `includeArchived = false` 时不会返回归档记录
- `replace` 会写 `supersededBy` 链
- `touch` 会更新时间戳

为 `TaskMemoryStoreAdapter` 和 `StoryMemoryStoreAdapter` 补一组兼容测试，要求它们在只读模式下继续可用，但也能逐步接入写接口或写 facade。

**Step 2: 跑测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/UnifiedMemoryFileStoreAdapterTests -only-testing:agentGuiTests/TaskMemoryStoreAdapterTests -only-testing:agentGuiTests/StoryMemoryStoreAdapterTests
```

Expected: FAIL，因为统一持久化 adapter 还不存在。

**Step 3: 写最小实现**

- 新增 `UnifiedMemoryFileStoreAdapter`，把通用 M2/M3/M4/M5 记录保存到 `~/.agentgui/unified-memory/` 下的 JSON 文件
- 让 `MemoryRuntimeCoordinator` 能同时读取 legacy adapter 和统一 store adapter
- `TaskMemoryStoreAdapter` 继续负责 legacy `TaskMemory -> [MemoryRecord]` 投影，不负责新存储格式的真写入
- `StoryMemoryStoreAdapter` 继续保留 SwiftData 的读优势，后续写侧由 facade 调用现有 `StoryMemoryService`

**Step 4: 跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/UnifiedMemoryFileStoreAdapter.swift agentGui/Services/TaskMemoryStoreAdapter.swift agentGui/Services/StoryMemoryStoreAdapter.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGuiTests/UnifiedMemoryFileStoreAdapterTests.swift agentGuiTests/TaskMemoryStoreAdapterTests.swift agentGuiTests/StoryMemoryStoreAdapterTests.swift
git commit -m "feat: add unified memory file store adapter"
```

### Task 3: 接通治理决策与真实写回编排

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+MemoryTool.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryConfirmationCandidate.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryGovernedWriteRoutingTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryGovernanceServiceTests.swift`

**Step 1: 先写失败测试**

覆盖四类治理分支：

- `acceptHotPath` 会真正持久化到统一 store
- `acceptBackground` 会进入后台队列，不再返回 error string
- `archiveOnly` 会写入归档区而不是丢失
- `needsUserConfirmation` 会生成待确认对象，而不是仅返回错误文本

同时补一个集成测试，要求 `memory_write` 不再直接依赖 `memory.md` 作为唯一长期真相源。

**Step 2: 跑测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryGovernedWriteRoutingTests -only-testing:agentGuiTests/MemoryGovernanceServiceTests
```

Expected: FAIL，因为当前治理层只返回字符串结果。

**Step 3: 写最小实现**

- 让 `MemoryGovernanceService` 返回结构化 routing 结果，而不是只有枚举判断
- 在 `MemoryRuntimeCoordinator` 中增加 `recordOutcome(_:)` 与 `scheduleConsolidation(for:)`
- `ClaudeService+MemoryTool` 改为优先走统一 runtime 写路径；`memory.md` 只保留兼容镜像或 fallback
- 引入轻量后台队列，先用 `Task {}` + actor 封装即可，不要先上复杂调度器
- `needsUserConfirmation` 先落地为持久化候选队列，UI 下一任务再接入

**Step 4: 跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryGovernanceService.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Services/ClaudeService+MemoryTool.swift agentGui/Services/ClaudeService+ToolDispatch.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Models/MemoryConfirmationCandidate.swift agentGuiTests/MemoryGovernedWriteRoutingTests.swift agentGuiTests/MemoryGovernanceServiceTests.swift
git commit -m "feat: route governed memory writes through runtime"
```

### Task 4: 实现巩固引擎与编码 / 创作的基础流转规则

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConsolidationEngine.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryDomainProfileRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryConsolidationRule.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConsolidationEngineTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryDomainProfileTests.swift`

**Step 1: 先写失败测试**

为以下规则写测试：

- coding：M1 工作记忆中的已确认事实与失败原因可固化到 M2
- coding：多次失败链可提升为 M3 情节性记录
- coding：高置信度且多次复现的事实可提升为 M4 语义事实
- creative-writing：timeline / scene 增量可沉淀为 M3；角色/规则/地点更新走 M4
- speculative 内容不会越过 governance 直接进入 M4

**Step 2: 跑测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryConsolidationEngineTests -only-testing:agentGuiTests/MemoryDomainProfileTests
```

Expected: FAIL，因为 `MemoryConsolidationEngine` 还是空实现，profile 也没有 consolidation rules。

**Step 3: 写最小实现**

- 给 `MemoryDomainProfile` 增加 retrieval seed、write policy、consolidation rule 暴露点
- `MemoryConsolidationEngine` 先做规则驱动版本，不依赖新模型调用
- 输出 `MemoryCandidate` 时补齐 `sourceRefs`、`confidence`、`retentionPolicy`
- 先实现 coding 和 creative-writing 两个 profile 的最低可用规则；`user-preferences` 只接受显式用户偏好写入

**Step 4: 跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryConsolidationEngine.swift agentGui/Services/MemoryDomainProfileRegistry.swift agentGui/Models/MemoryRuntimeTypes.swift agentGui/Models/MemoryConsolidationRule.swift agentGuiTests/MemoryConsolidationEngineTests.swift agentGuiTests/MemoryDomainProfileTests.swift
git commit -m "feat: add rule-based memory consolidation"
```

### Task 5: 补齐冲突、替代、TTL 与再验证治理

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryGovernanceTypes.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetentionService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConflictResolver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetentionServiceTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConflictResolverTests.swift`

**Step 1: 先写失败测试**

覆盖：

- 同 scope、同 tag、同对象键的事实冲突能被标记出来
- 新事实替代旧事实时会写 `supersededBy`
- `sessionBound` 记录过期后不会继续参与默认召回
- `archiveOnly` 记录仍可在审计模式读到
- `partial` / `unverified` 记录可以进入再验证队列

**Step 2: 跑测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRetentionServiceTests -only-testing:agentGuiTests/MemoryConflictResolverTests -only-testing:agentGuiTests/MemoryGovernanceServiceTests
```

Expected: FAIL，因为当前没有 retention service 和 conflict resolver。

**Step 3: 写最小实现**

- `MemoryConflictResolver` 先用规则化键匹配，不做模糊语义冲突检测
- `MemoryRetentionService` 先支持 TTL sweep、archive sweep、revalidation queue 三种 job
- `MemoryGovernanceService` 在写入前调用冲突检测；命中冲突时写 warning 和替代链
- 先不做后台定时器 UI，保留显式调用入口和测试覆盖即可

**Step 4: 跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryGovernanceService.swift agentGui/Services/UnifiedMemoryFileStoreAdapter.swift agentGui/Models/MemoryGovernanceTypes.swift agentGui/Services/MemoryRetentionService.swift agentGui/Services/MemoryConflictResolver.swift agentGuiTests/MemoryRetentionServiceTests.swift agentGuiTests/MemoryConflictResolverTests.swift agentGuiTests/MemoryGovernanceServiceTests.swift
git commit -m "feat: add memory conflict and retention governance"
```

### Task 6: 提升检索规划与 prompt 组装，完成最小相关切片原则

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalPlanner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryPromptAssembler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryPromptBudgetingTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetrievalPlannerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryPromptAssemblerTests.swift`

**Step 1: 先写失败测试**

覆盖：

- coding 请求会优先拿 M1/M2，再按对象相关性取 M3/M4
- creative 请求会优先拿 M1/M4，再补对象相关的 M3
- `archiveOnly` 和过期记录不进入 prompt
- prompt 会按“已验证事实 / 当前推测 / 风险与待确认项 / 建议忽略”分组
- budget 压缩时优先保留 verified semantic 与 active task records

**Step 2: 跑测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryPromptBudgetingTests -only-testing:agentGuiTests/MemoryRetrievalPlannerTests -only-testing:agentGuiTests/MemoryPromptAssemblerTests
```

Expected: FAIL，因为当前 planner 只按 layer 平分预算，assembler 也没有不确定性分组。

**Step 3: 写最小实现**

- 在 `MemoryRetrievalPlan` 中加入 filter / ranking / includeArchived 开关
- planner 先做规则化对象过滤：scope、tag、verification、layer priority
- assembler 输出固定四组：`已验证事实`、`当前推测`、`风险 / 待确认项`、`相关事件`
- coordinator 在读后统一 touch 已命中记录的 `lastAccessedAt`

**Step 4: 跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryRetrievalPlanner.swift agentGui/Services/MemoryPromptAssembler.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Models/MemoryRuntimeTypes.swift agentGuiTests/MemoryPromptBudgetingTests.swift agentGuiTests/MemoryRetrievalPlannerTests.swift agentGuiTests/MemoryPromptAssemblerTests.swift
git commit -m "feat: improve memory retrieval and prompt slicing"
```

### Task 7: 增加待确认 / 冲突 / 归档的可见性与管理入口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryManagementViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryManagementPanel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryConflictList.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryConfirmationList.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryManagementViewModelTests.swift`

**Step 1: 先写失败测试**

覆盖：

- 设置页可控制统一写路径、自动后台巩固、确认阈值、TTL sweep 开关
- 管理面能显示 scope 统计、layer 统计、待确认数量、冲突数量、归档数量
- 工具详情页能显示本轮是否触发后台巩固、是否发现冲突、是否产生待确认写入

**Step 2: 跑测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryManagementViewModelTests
```

Expected: FAIL，因为当前没有管理面板和相应 view model。

**Step 3: 写最小实现**

- 保持 UI 第一版只做浏览和确认，不做复杂批量编辑
- 在 `ContentView` 的长期记忆区域加入统一 runtime 状态摘要和管理入口
- `ToolCallDetailContentView` 扩充写路径 metadata 展示
- `MemoryManagementViewModel` 从统一 store 读取 scope/layer 统计和候选队列

**Step 4: 跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ContentView.swift agentGui/Views/ToolCallDetailContentView.swift agentGui/Views/ChatView.swift agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift agentGui/Models/AppSettings.swift agentGui/ViewModels/MemoryManagementViewModel.swift agentGui/Views/Memory/MemoryManagementPanel.swift agentGui/Views/Memory/MemoryConflictList.swift agentGui/Views/Memory/MemoryConfirmationList.swift agentGuiTests/MemoryManagementViewModelTests.swift
git commit -m "feat: add memory governance management ui"
```

### Task 8: 收敛 legacy 路径并补齐迁移与文档

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-human-like-memory-system-requirements.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-10-human-like-memory-system-implementation.md`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryMigrationIntegrationTests.swift`

**Step 1: 先写失败测试**

覆盖：

- 打开统一 runtime 后，旧 `memory_write` 仍兼容，但默认读取以统一 store 为准
- `TaskMemoryService` 与 `StoryMemoryService` 的写操作可通过 facade 同步产生统一记录或审计记录
- 关闭统一 runtime 时应用仍可按旧模式运行

**Step 2: 跑测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryMigrationIntegrationTests
```

Expected: FAIL，因为当前 legacy path 还没有迁移 facade。

**Step 3: 写最小实现**

- 给 legacy 服务增加 facade 或 hook，不要直接重写内部存储结构
- README 与 spec 补上当前迁移状态、开关说明、确认与归档流程
- 旧文档 `2026-03-10-human-like-memory-system-implementation.md` 标注“Phase 1 已完成，后续参照 gap closure plan”

**Step 4: 跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ContextCompression.swift agentGui/Services/TaskMemoryService.swift agentGui/Services/StoryMemoryService.swift README.md docs/spec/2026-03-10-human-like-memory-system-requirements.md docs/plans/2026-03-10-human-like-memory-system-implementation.md agentGuiTests/MemoryMigrationIntegrationTests.swift
git commit -m "chore: migrate legacy memory paths behind unified runtime"
```

## 4. 里程碑与验收

### Milestone A: 写路径闭环可用

完成 Task 1-3 后，必须满足：

- 统一 runtime 不再只是 read-only
- 治理分支不再只返回错误文本
- `memory_write` 可以写入结构化记录
- 后台写入、归档、待确认对象至少能持久化

### Milestone B: 生命周期治理可用

完成 Task 4-6 后，必须满足：

- 至少 coding / creative-writing 两个 profile 具备基础巩固规则
- 系统支持冲突检测、替代链、TTL 与再验证队列
- prompt 只注入最小相关切片，并能区分 verified / speculative / risk

### Milestone C: 产品面可见且可控

完成 Task 7-8 后，必须满足：

- 用户可以看到本轮是否命中哪些记忆层、是否触发后台巩固、是否产生冲突与待确认写入
- 用户可以浏览 scope/layer 统计、待确认队列、冲突队列、归档对象
- legacy 路径被统一 facade 收敛，需求文档中的 Phase 3 / Phase 4 关键项具备可用实现

## 5. 风险与取舍

- 不要在这一轮同时引入向量检索。当前最大缺口是写路径与治理闭环，不是召回算法不够高级。
- 不要把 `TaskMemory`、`StoryMemory` 一次性迁移成全新 schema。先通过 facade 收敛，避免破坏现有功能。
- `UnifiedMemoryFileStoreAdapter` 是过渡性通用存储，不排斥后续加 SwiftData 版本或索引层；本轮重点是把 runtime 协议跑通。
- UI 第一版只需要“可见、可确认、可清理”，不需要做完整知识库浏览器。

## 6. 推荐执行顺序

1. Task 1-3 作为一条连续主线先做完，优先让 runtime 从只读升级为读写闭环。
2. Task 4-6 第二波做，把记忆生命周期真正补全，避免写入后继续堆垃圾。
3. Task 7-8 最后做，把治理能力暴露给用户并完成 legacy 收口。

## 7. 完成定义

以下条件全部成立，才视为本需求真正完成：

- requirements 第 8.1 到 8.6 的模块都不再只有骨架或占位实现
- requirements 第 10 节的写入、巩固、遗忘、验证四段生命周期均有真实代码路径
- requirements 第 11 节的最小相关切片原则由测试覆盖，而不是只在文档里声明
- requirements 第 13 节的记忆可见性、管理界面、用户控制至少有最小可用实现
- requirements 第 14 节的可靠性与可测试性要求由 focused tests 覆盖核心路径

Plan complete and saved to `docs/plans/2026-03-10-human-like-memory-system-gap-closure-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?