# Memory System Enhancement Design

> 基于 Claude Code 源码深度分析，梳理 agentGui 内置 Agent Memory 的可改进方向。
> 本文档将改进项拆分为独立可交付的小 Feature，每个 Feature 可单独实现和测试。

---

## 一、背景分析：Claude Code Memory 架构总结

通过精读 `/claude-code-source-code-main/src/memdir/` 和相关服务代码，归纳出以下核心设计亮点：

### 1.1 分层存储模式（Index + Topic Files）

```
~/.claude/projects/<sanitized-cwd>/memory/
    MEMORY.md           ← 始终加载的轻量索引 (≤200行 / ≤25KB)
    user_role.md        ← 每条记忆独立文件，含 frontmatter
    feedback_tests.md
    project_release.md
    ...
    team/               ← 团队共享层 (TEAMMEM feature flag 控制)
        MEMORY.md
        ...
```

- `MEMORY.md` 是每次 System Prompt 都注入的索引，每行一个指针 `- [Title](file.md) — one-line hook`
- 具体内容存在独立话题文件，按需加载（not always-loaded）

### 1.2 四类型语义分类（Memory Type Taxonomy）

| 类型 | 说明 | 保存时机 |
|------|------|----------|
| `user` | 用户身份、偏好、专业背景 | 学到用户角色/偏好时 |
| `feedback` | 用户给出的行为纠正或确认 | 被更正或被明确认可时 |
| `project` | 项目进展、目标、deadline、事故 | 了解项目上下文时 |
| `reference` | 外部系统指针（Linear/Grafana等） | 发现外部信息来源时 |

每类型都有 `when_to_save` / `how_to_use` / `body_structure` / `examples` 的详细 prompt 指导。

### 1.3 双后台服务：Extract + Dream

**ExtractMemories**（`extractMemories.ts`）：
- 在每次完整对话轮次结束时触发（`handleStopHooks`）
- 使用 `runForkedAgent` 共享父会话的 Prompt Cache 前缀
- 约束工具集（只允许 Read/Write/Edit/Glob/Grep）
- 检测 `hasMemoryWritesSince` 避免重复提取

**AutoDream**（`autoDream.ts`）：
- 触发条件：距上次 consolidation ≥ 24h **且** 新增 session ≥ 5
- 4 阶段 consolidation prompt：Orient → Gather → Consolidate → Prune
- 用 `consolidationLock` 防止并发
- 以 `DreamTask` 注册进任务注册表，UI 可见（Footer pill）

### 1.4 智能记忆召回（Relevant Memory Recall）

- `findRelevantMemories.ts`：扫描所有 `.md` 文件的 frontmatter，生成 manifest
- 发起独立的 secondary Sonnet API call（`sideQuery`），返回最多 5 个相关文件路径
- 结合 `memoryAge.ts` 附加时效性警告（> 1 天的记忆标注 "X days ago"）
- `alreadySurfaced` Set 防止同一会话重复加载

### 1.5 Agent 专属记忆目录（Agent-Type Memory）

```
~/.claude/agent-memory/<agentType>/      ← user scope
.claude/agent-memory/<agentType>/        ← project scope (VCS-trackable)
.claude/agent-memory-local/<agentType>/ ← local scope (gitignored)
```

每个 agent 类型独立的记忆空间 + Snapshot 初始化机制（从项目快照同步到本地）。

### 1.6 Session Memory（会话内临时记事）

`sessionMemory.ts`：后台运行，定期更新当前会话的临时笔记文件，不跨会话持久化，主要用于 AutoCompact 后的上下文恢复。

---

## 二、agentGui 现状差距分析

| 维度 | Claude Code | agentGui 现状 | 缺口 |
|------|------------|---------------|------|
| 存储结构 | Index(MEMORY.md) + 话题文件 | SwiftData + JSON 文件（`UnifiedMemoryStoredRecord`） | 无轻量 always-loaded 索引 |
| 语义分类 | 4 类型 + 详细 prompt 指导 | `RMSInsightKind`(constraint/counterexample/tactic) + `MemoryKind` | 缺少 user/feedback/project/reference 语义 |
| 自动提取 | 每轮结束自动 Extract | 无自动提取，只有手动 write-on-demand | **缺失** |
| 后台整合 | AutoDream（24h/5 sessions）| 无 | **缺失** |
| 智能召回 | Secondary model call（top-5） | Bootstrap 只在 session 开始注入（RMSSelector） | 无 mid-conversation 动态召回 |
| 时效性信号 | Age in days + staleness warning | 无 | **缺失** |
| Agent 专属目录 | 按 agentType 隔离 | 全局/project/session scope，不按 agentType | Agent 记忆混用 |
| 团队共享记忆 | team/ 子目录（TEAMMEM） | 无 | **缺失** |
| 记忆 prompt 指导 | 丰富的 when/what/how/not-to-save 说明 | RMS 注入但无分类指导 | Prompt 指导贫乏 |
| Session vs Persistent | 明确区分 | 有区分但无 session-level 动态更新服务 | 无 SessionMemory 后台服务 |

---

## 三、Feature 列表

> 按优先级排序（P0 代表直接影响记忆质量的核心能力，P1/P2 是增强）

---

### Feature M-01：语义记忆类型注解系统 (P0)

**目标**：在现有 `RMSInsightKind` 和 `MemoryRecord` 基础上添加 Claude Code 式的四类型语义，并将丰富的 prompt 指导注入 agent system prompt。

**工作内容**：

1. 在 `RMSInsight` 或新建 `MemorySemanticType` enum 中添加：
   ```swift
   enum MemorySemanticType: String, Codable, Sendable {
       case user       // 用户角色/偏好/背景
       case feedback   // 用户给出的行为纠正或确认
       case project    // 项目进展、目标、decision
       case reference  // 外部系统指针
   }
   ```

2. 编写 `MemoryTypeGuidanceComposer.swift`（nonisolated），为 agent system prompt 动态生成 `## Types of memory` 节：
   - 每种类型含 `description` / `when_to_save` / `how_to_use` / `body_structure` / `examples`
   - 含 `## What NOT to save`：不存储可从代码/git/文件结构推导出的内容

3. 将 guidance 注入 `AgentLoopMemoryBootstrapComposer` 的 system prompt 部分

4. 为 `RMSInsight.semanticType` 字段做存储迁移（SwiftData migration）

**可测试性**：单元测试 `MemoryTypeGuidanceComposerTests` 验证每种类型的 prompt 输出格式。

---

### Feature M-02：MEMORY.md 轻量索引文件层 (P0)

**目标**：引入 `MEMORY.md` 始终加载索引模式，解决现有 RMS bootstrap 把所有记忆内容塞入同一 prompt 块的上下文损耗问题。

**工作内容**：

1. 新建 `MemoryIndexWriter.swift`：
   - 读取 project-scope 所有记忆记录
   - 写入 `<projectDir>/.agentgui/memory/MEMORY.md`
   - 格式：每行一条 `- [<title>](<filename>) — <one-line-hook>`
   - 限制：≤ 200 行，≤ 25KB（超出则截断并附 warning）

2. 新建 `MemoryIndexReader.swift`：
   - 同步读取 `MEMORY.md` 内容
   - 替换 `AgentLoopMemoryBootstrapComposer` 中的全量注入逻辑
   - MEMORY.md 作为 System Prompt 的 `## MEMORY.md` 节，话题文件按需加载

3. 在 `MemoryStoreAdapter.persist()` 调用后触发索引更新（非阻塞，async write）

4. 工具层：agent 可通过 `memory_write` 工具写入话题文件并自动更新索引

**可测试性**：`MemoryIndexWriterTests` 验证截断逻辑和格式规范。

---

### Feature M-03：会话末记忆自动提取服务 (P0)

**目标**：模仿 Claude Code 的 `extractMemories.ts`，在每个对话轮次完整结束后（无 tool call 时），后台发起 subagent 提取本轮值得保留的记忆，写入文件系统。

**工作内容**：

1. 新建 `SessionMemoryExtractorService.swift`（`@MainActor`）：
   - 注册 `postSamplingHook`（接入现有 `AgentLoopRoundExecutor` 的 hook 管道）
   - 触发条件：本轮无 tool_use，且距上次 extraction ≥ N 条 user+assistant 消息
   - 使用 `ClaudeService.runSubagentLoop` 发起 forked extraction agent

2. 新建 `MemoryExtractionPromptBuilder.swift`：
   - 提供 extraction agent prompt（角色：只读取当前 session 并判断哪些值得持久化）
   - 限制工具集：`file_read`、`memory_write`、`file_glob`
   - 含 `alreadyExtractedSince` 消息 UUID 防止重复提取

3. 在 `ClaudeService+AgenticLoop.swift` 的 `stopHook` 调用点接入提取触发器

4. 守卫条件：提取 agent 正在运行时不重复启动（`isExtracting: Bool` flag）

**可测试性**：`SessionMemoryExtractorServiceTests` mock round executor，验证触发条件和 subagent 调用参数。

---

### Feature M-04：记忆时效性信号（Memory Freshness）(P1)

**目标**：对注入 prompt 的记忆加上时效性标注，防止陈旧记忆被当作当前事实断言（Claude Code `memoryAge.ts` 对应实现）。

**工作内容**：

1. 新建 `MemoryFreshnessAnnotator.swift`（nonisolated）：
   ```swift
   func freshnessNote(updatedAt: Date) -> String? {
       let days = Calendar.current.dateComponents([.day], from: updatedAt, to: .now).day ?? 0
       guard days > 1 else { return nil }
       return "This memory is \(days) days old. It reflects a point-in-time observation — verify against current state before asserting as fact."
   }
   ```

2. 在 `RMSPromptComposer.compose()` 中为每条 insight 附加 freshness note（仅 > 1 天时）

3. 在 `findRelevantMemories` 等按需加载路径同样附加 freshness note

4. 在 `MemoryRecord` 的 `updatedAt` 和 `lastAccessedAt` 基础上计算年龄，UI 层（记忆列表）显示 "X days ago"

**可测试性**：`MemoryFreshnessAnnotatorTests` 验证 0/1/7/30 天的输出。

---

### Feature M-05：智能中段记忆召回（Mid-Conversation Recall）(P1)

**目标**：模仿 Claude Code `findRelevantMemories.ts`，在对话进行中根据当前 user query 发起 secondary API call，动态追加相关记忆，而不只是在 session 开始时全量注入。

**工作内容**：

1. 新建 `RelevantMemoryRecallService.swift`：
   - 扫描 `<projectDir>/.agentgui/memory/` 所有 `.md` 文件的 frontmatter（title/description/type）
   - 构建 manifest（类似 `formatMemoryManifest`）
   - 调用 `haiku-3-5` / `sonnet-3-5` sideQuery，传入 `currentUserQuery + manifest`，返回最多 5 个文件名
   - 读取对应话题文件内容，以 `<system-reminder>` 包装注入当前轮 user message

2. `alreadySurfaced: Set<String>` 跨轮维护，避免同一会话重复注入相同文件

3. 触发时机：在 `AgentLoopRoundExecutor` 的 `prepareContext` 阶段，获取到 user message 后异步召回（超时 2s 则 skip）

4. `RecentToolsFilter`：当前轮若已调用某工具，不再 surface 该工具的 reference 文件（减少噪音）

**可测试性**：`RelevantMemoryRecallServiceTests` mock API call，验证 manifest 格式、召回过滤逻辑。

---

### Feature M-06：后台记忆整合 Daemon（Dream Equivalent）(P1)

**目标**：模仿 Claude Code AutoDream，实现一个后台整合服务，在满足时间和轮次双门槛时触发 consolidation subagent，将多轮 session transcript 蒸馏为持久记忆。

**工作内容**：

1. 新建 `MemoryConsolidationService.swift`（`@MainActor`）：
   - 调度条件：距上次 consolidation ≥ 24h **且** 新增 session ≥ 5（可由 AppSettings 配置）
   - 使用 `consolidationLock`（文件 mtime 作为乐观锁）防止并发
   - 发起 consolidation subagent（`ClaudeService.runSubagentLoop`）

2. 新建 `MemoryConsolidationPromptBuilder.swift`：
   - 4 阶段 prompt：Orient / Gather / Consolidate / Prune
   - Orient：ls 记忆目录，读 MEMORY.md 索引
   - Gather：从近期 session transcripts 提取新信号
   - Consolidate：按逻辑合并至话题文件，absolute dates
   - Prune：维护 MEMORY.md 索引 ≤ 200 行

3. 新建 `MemoryConsolidationLockManager.swift`：
   - `tryAcquire(lastConsolidatedAt:) -> Bool`
   - `rollback(to priorMtime: Date)`

4. 在 `backgroundHousekeeping` 调用点注册（类似 Claude Code 的 `initAutoDream`）

5. 在 UI 层以 Task indicator 显示整合进度（可选，参考 `DreamTask` 模式）

**可测试性**：`MemoryConsolidationServiceTests` 验证双门槛触发逻辑、lock 竞争保护。

---

### Feature M-07：Agent 专属记忆隔离（Per-AgentType Memory）(P1)

**目标**：每个 built-in agent 类型（explore、coder、reviewer 等）拥有独立的记忆存储路径，避免不同专业角色的记忆相互污染。

**工作内容**：

1. 扩展 `MemoryScope` 增加 `agentType` 维度（或在路径层处理）：
   ```swift
   // ~/.agentgui/agent-memory/<agentType>/
   // <projectDir>/.agentgui/agent-memory/<agentType>/  (project scope)
   ```

2. 新建 `AgentTypeMemoryPathResolver.swift`：
   - `dir(agentType: String, scope: AgentMemoryScope) -> URL`
   - 对 agentType 做路径安全化（替换 `:` → `-`，拒绝 `..`/空字节）

3. `AgentDefinitionDocument.swift`（已有）新增 `memoryScope: AgentMemoryScope?` frontmatter 字段：
   - 默认 `project`，can be `user` or `local`

4. `loadAgentMemoryPrompt(agentType:scope:)` 替换现有 `AgentLoopMemoryBootstrapComposer` 的单一路径

5. Snapshot 机制：项目可提供 `.agentgui/agent-memory-snapshots/<agentType>/snapshot.json`，新设备首次运行时自动初始化（参考 `agentMemorySnapshot.ts`）

**可测试性**：`AgentTypeMemoryPathResolverTests` 验证路径安全化、scope 映射。

---

### Feature M-08：Session Memory 后台更新服务 (P2)

**目标**：在 AutoCompact 触发后或长时间对话中维护一份当前会话的结构化临时笔记，作为上下文压缩后的恢复基点（对齐 Claude Code `SessionMemory`）。

**工作内容**：

1. 新建 `SessionMemoryUpdateService.swift`：
   - 定期（每 N 个 tool_use 后）发起 lightweight subagent
   - Subagent 更新 `<sessionDir>/session-memory.md`（结构化 markdown：当前任务/进度/决策/已踩坑）
   - 文件路径：`.agentgui/sessions/<sessionID>/session-memory.md`

2. 在 AutoCompact 触发前读取 `session-memory.md`，注入压缩后的新 system prompt 前缀

3. 区分 persistent（写入 project memory）vs session-only（写入 session-memory.md）

4. `SessionMemoryConfig`：update interval（tool call 数）、token budget for session memory

**可测试性**：`SessionMemoryUpdateServiceTests` 验证触发间隔、文件写入格式。

---

### Feature M-09：团队共享记忆层（Team Memory）(P2)

**目标**：支持团队成员共享 project-scope feedback 和 reference 记忆，通过 VCS 跟踪（对标 Claude Code TEAMMEM feature）。

**工作内容**：

1. 扩展 `MemoryScope` 增加 `team` case（或在项目 scope 下分子目录）：
   ```
   <projectDir>/.agentgui/memory/team/
       MEMORY.md       ← 团队共享索引
       feedback_*.md   ← 团队级 feedback（testing policy 等）
       reference_*.md  ← 团队级外部系统指针
   ```

2. 在 `MemoryTypeGuidanceComposer` 中为 team-scope 添加 `<scope>` 标注：
   - `user` → always private
   - `feedback` → default private，项目级规范时 → team
   - `project` → bias toward team
   - `reference` → usually team

3. Team memory 写入前校验：`private feedback` 不能与已有 `team feedback` 矛盾

4. `MemoryIndexWriter` 合并 private + team 两个 MEMORY.md 展示给 agent

**可测试性**：`TeamMemoryTests` 验证 scope 分流逻辑和冲突检测。

---

### Feature M-10：记忆健康度面板（Memory Health UI）(P2)

**目标**：在 agentGui 设置或 Debug 面板中提供记忆系统可观测性，便于用户理解和清理记忆。

**工作内容**：

1. 新建 `MemoryHealthViewModel.swift`：
   - 统计各 scope/type 记忆数量、总体积、最老/最新时间戳
   - 检测 MEMORY.md 是否超限（行数/字节数）
   - 列出 > 30 天未访问的"可能已过时"记忆

2. SwiftUI `MemoryHealthView`：
   - 分 scope 展示统计卡片
   - 入口：Settings → Memory → "Memory Health"
   - 操作：删除单条、清空 scope、手动触发 consolidation

3. 在 `MemoryStoreAdapter` 协议增加 `healthReport() -> MemoryHealthReport` 方法（默认实现从现有 records 聚合）

**可测试性**：`MemoryHealthViewModelTests` 验证统计计算和过期检测。

---

## 四、实施优先级路线图

```
Sprint 1（核心质量）
  M-01  语义类型注解系统    ← prompt 质量立竿见影
  M-02  MEMORY.md 索引文件层 ← 解决 context 膨胀
  M-04  时效性信号          ← 防止陈旧记忆被断言

Sprint 2（自动化）
  M-03  会话末自动提取服务  ← 记忆积累不再依赖手动
  M-05  智能中段召回        ← 记忆真正参与推理

Sprint 3（长时运行）
  M-06  后台整合 Daemon     ← 多会话知识蒸馏
  M-07  Agent 专属记忆隔离  ← 角色专业化

Sprint 4（协作与可观测）
  M-08  Session Memory 服务
  M-09  团队共享记忆层
  M-10  记忆健康度面板
```

---

## 五、关键设计约束（来自 Claude Code 实践）

1. **不存储可推导内容**：代码架构、git 历史、文件结构等任何时刻 grep/read 能得到的内容不应进记忆，避免 staleness 风险。

2. **记忆 ≠ 任务列表**：当前轮次进度用 tasks，跨会话才用 memory；实现计划用 plans，不用 memory。

3. **不让 agent 在写之前先检查目录是否存在**：在 bootstrap 阶段保证 memdir 已创建（`ensureMemoryDirExists`），减少无效 tool call。

4. **Consolidation 前必须加锁**：Dream/Consolidation 是高开销操作，多进程/多 window 并发时必须用文件 mtime 乐观锁防止爆炸。

5. **Secondary API call 必须可跳过**：`findRelevantMemories` 使用 `sideQuery` 且有超时，主对话不因召回失败而阻塞。

6. **User memory 始终私有**：用户身份/偏好记忆不得写入 team/project scope，防止无意暴露个人信息。

7. **安全路径校验**：所有 agentType 名称进入路径前必须 sanitize（拒绝 `..`、null byte、URL 编码穿越）。
