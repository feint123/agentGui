# Memory System Refactor — Design Document

> 分析基准：Claude Code 源码 (`src/memdir/`) vs agentGui 现有实现  
> 原则：不需要迁移兼容，冗余/不合适的设计直接删除替换。

---

## 背景：两套系统的本质差异

### Claude Code 的设计
Claude Code 使用**单一文件存储通道**：  
- `~/.claude/projects/<hash>/memory/` — 一个目录，里面是 Markdown 文件  
- `MEMORY.md` — 索引文件（≤200行/25KB），bootstrap 时注入系统提示  
- `<topic>.md` — 每个记忆一个文件，frontmatter 含 `type`/`description`  
- `memory_write` 工具 / FileWriteTool — Agent **直接写文件**，无中间层  
- 提取：会话结束时 forked agent 用 FileWriteTool/FileEditTool 写 `.md` 文件  
- Recall：side-query 读 frontmatter → 选出相关文件 → 注入 `<system-reminder>`  
- 内存类型分类法：`user` / `feedback` / `project` / `reference`（闭合四类）  

### agentGui 的现状（问题）

agentGui 演化出了**三条并行存储通道**，互相桥接但职责混乱：

```
通道 A: RMSInsightStore (rms-insights.json) + RMSInsight 模型  
         ↓ memory_write 工具写入  
         ↓ triggerMemoryIndexRebuild() 转换为 MemoryRecord  
通道 B: UnifiedMemoryFileStoreAdapter (unified-memory/*.json) + MemoryRecord 模型  
         ↓ MemoryIndexWriter 构建 MEMORY.md  
通道 C: 文件系统 Memory/ (MEMORY.md + topic .md files) ← Claude Code 对齐的部分  
         ↑ MemoryIndexFileSystem.rebuild()  
         
AgentLoopMemoryBootstrapComposer 读的是 通道A (RMSInsightStore)，不是 通道C
RelevantMemoryRecallService 读的是 通道C，是对的
SessionMemoryExtractorService 写的是 通道A，不是 通道C
```

此外有一层庞大的"治理层"（Governance Layer）— `MemoryAdmission*`、`MemoryConsolidation*`、`MemoryInvalidation*`、`TacticKernelDistillation*` 等 — 这些在 Claude Code 中完全不存在，属于过度设计。

---

## 重构目标

**删除通道 A 和通道 B，以及整个治理层，只保留通道 C（文件系统 Markdown）。**

统一后的流程：
```
memory_write 工具 → 直接写 topic .md 文件 → 重建 MEMORY.md 索引
SessionMemoryExtractorService → 给子 agent FileWrite 权限 → 写 .md 文件
AgentLoopMemoryBootstrapComposer → 读 MEMORY.md → 注入系统提示
RelevantMemoryRecallService → 扫描 topic 文件 → side-query → 注入 <system-reminder>
```

---

## Feature 拆分

---

### Feature M-01：删除 RMS 子系统（最大减量）

**目标**：彻底移除 RMS（Runtime Memory System）—— 这是一套与文件存储通道完全平行且与 Claude Code 设计无关的系统。

**删除的文件（Services/）**：
```
Services/RMSExtractor.swift              (245 行)
Services/RMSInsightGenerator.swift       (490 行)
Services/RMSInsightStore.swift           (117 行)
Services/RMSPromptComposer.swift         (114 行)
Services/RMSSelector.swift               (94 行)
Services/RMSStateReducer.swift           (187 行)
Services/RMSRawContentStore.swift        (62 行)
Services/AgentLoopMemoryBootstrapComposer.swift  (67 行)
```

**删除的文件（Models/）**：
```
Models/RMSInsight.swift                  (269 行)
Models/RMSInsight+MemoryRecord.swift     (46 行)
Models/RMSMemoryRuntimeContext.swift
Models/MemorySemanticType.swift
```

**删除的测试**：
```
agentGuiTests/AgentLoopRMSExtractionRemovalTests.swift  ← 已是删除验证测试
agentGuiTests/AgentLoopRoundStreamAssemblerUsageTests.swift (RMS 相关部分)
```

**副作用处理**：
- `ClaudeService+ToolDispatch.swift` 中 `executeGovernedMemoryWrite()` 和 `makeMemoryWriteInsight()` 删除（Feature M-03 中替换实现）
- `triggerMemoryIndexRebuild(store:)` 删除（Feature M-03 中重新实现为直接操作文件）
- `SessionMemoryExtractorService.runExtraction()` 中读取 RMSInsightStore 的部分删除（Feature M-04 中替换）
- `ClaudeService+MemoryExtraction.swift` 删除（内容合并到 Feature M-03）

**完成标志**：项目中无任何 `RMS`、`rms` 前缀符号引用，无 `rms-insights.json` 文件创建逻辑。

---

### Feature M-02：删除 JSON-backed MemoryRecord 系统和治理层

**目标**：移除 `UnifiedMemoryFileStoreAdapter` JSON 存储体系以及与之配套的治理/审计基础设施。

**删除的文件（Services/）**：
```
Services/MemoryStoreAdapter.swift
Services/UnifiedMemoryFileStoreAdapter.swift
Services/MemoryEvidenceResolver.swift
Services/MemoryInvalidationService.swift
Services/MemoryDomainProfileRegistry.swift
Services/TacticKernelDistillationService.swift
Services/CounterexampleDistillationService.swift
```

**删除的文件（Models/）**：
```
Models/MemoryRecord.swift
Models/MemoryAdmissionExplanation.swift
Models/MemoryAdmissionFeatureVector.swift
Models/MemoryAdmissionScore.swift
Models/MemoryBackgroundJob.swift
Models/MemoryConfirmationCandidate.swift
Models/MemoryConfirmationStatus.swift
Models/MemoryConsolidationRule.swift
Models/MemoryDecisionImpactAssessment.swift
Models/MemoryEvidenceAnchor.swift
Models/MemoryGovernanceAuditEntry.swift
Models/MemoryGovernanceTypes.swift
Models/MemoryKind.swift
Models/MemoryLayer.swift
Models/MemoryRetrievalIntent.swift
Models/MemoryRuntimeTypes.swift          ← MemoryDomainProfile, MemoryRuntimeRequest, MemoryRuntimeOutcome 等
Models/MemorySweepReport.swift
Models/UnifiedMemoryStoredRecord.swift
```

**保留的文件（注意不要误删）**：
```
Models/MemoryScope.swift                 ← 保留（RelevantMemoryRecallService 使用）
Models/MemoryRuntimeSnapshot.swift       ← 保留（执行运行时用，与 RMS 无关）
```

**`unified-memory/` 目录**：
- `MemoryIndexFileSystem` 的写入目标从 `unified-memory/` 改为直接操作 `memory/` 目录（Feature M-05 中处理）

**删除的测试**（治理/invalidation/domain 相关）：
- 与 `MemoryDomainProfile`、`MemoryRecord`、`MemoryInvalidation` 相关的测试

**完成标志**：`unified-memory/*.json` 不再生成；无 `MemoryRecord`/`MemoryStoreAdapter` 编译引用。

---

### Feature M-03：删除 Consolidation 子系统

**目标**：移除 `MemoryConsolidationService` —— Claude Code 没有独立的 consolidation 调度，会话结束的提取（extraction）已经足够。

**删除的文件（Services/Memory/）**：
```
Services/Memory/MemoryConsolidationService.swift
Services/Memory/MemoryConsolidationLockManager.swift
Services/Memory/MemoryConsolidationPromptBuilder.swift
Services/Memory/MemoryConsolidationScheduleGate.swift
Services/Memory/ConsolidationProgressState.swift
Services/AgentLoopHooks/MemoryConsolidationHook.swift
```

**删除的模型**：
```
Models/MemoryConsolidationRule.swift    ← M-02 中已列
```

**修改 `AgentLoopBuiltInHookFactory.swift`**：
- 删除 `MemoryConsolidationHook` 的注册和构建
- `AgentLoopHookDependencyFactory` 中删除 consolidation callback 构建代码

**保留的设置字段**（`AppSettings`）：
- 删除 `memoryConsolidationEnabled`、`memoryConsolidationMinHours`、`memoryConsolidationMinSessions`

**完成标志**：hook pipeline 中无 consolidation hook；无定时/计数触发的 memory 子 agent。

---

### Feature M-04：修复 `memory_write` 工具 → 直接写 Markdown 文件

**目标**：`memory_write` 工具当前写入 `RMSInsightStore`（JSON），删除 RMS 后需要改为直接创建/更新 `.md` topic 文件，与 Claude Code 的 FileWriteTool 路径对齐。

**修改 `ClaudeService+ToolDispatch.swift`**：
- 删除 `executeGovernedMemoryWrite()` / `makeMemoryWriteInsight()` / `triggerMemoryIndexRebuild(store:)`
- 新增 `executeFileMemoryWrite()` 方法：
  ```swift
  // 伪代码逻辑
  func executeFileMemoryWrite(input:) async -> String {
      // 1. 解析 content / type（user|feedback|project|reference）/ title
      // 2. 生成 filename = MemoryTopicFilename.filename(title, hash)
      // 3. 构建 frontmatter + body，写入 memoryDir/filename.md
      // 4. 更新 MEMORY.md 索引（MemoryIndexFileSystem.rebuildFromFiles()）
      // 5. 返回 "Memory saved: <filename>"
  }
  ```

**修改工具定义（`ClaudeService+ToolBuilder.swift`）**：
- 更新 `memory_write` 的 `description`，去掉"RMS"术语
- 新增 `type` 参数（`user|feedback|project|reference`，可选，默认 `project`）
- 保留 `content` 为必填，`title` 为可选

**修改 `MemoryTopicFileComposer.swift`**：
- 确保 frontmatter 包含 `type:` 字段（来自工具输入或推断）

**新增 `MemoryIndexFileSystem.rebuildFromFiles()`**：
- 扫描 `memoryDir` 下所有 `.md` 文件（复用 `MemoryTopicScanner`），从 frontmatter 构建 MEMORY.md 索引行
- 取代原来从 `[MemoryRecord]` 构建的路径（`MemoryIndexWriter.build(records:)`）

**完成标志**：调用 `memory_write` 后，`memoryDir` 下出现新 `.md` 文件，且 `MEMORY.md` 索引行更新。

---

### Feature M-05：修复 Memory Bootstrap → 读 MEMORY.md 注入系统提示

**目标**：`AgentLoopMemoryBootstrapComposer` 当前读取 `RMSInsightStore`，删除 RMS 后需要改为读取 `MEMORY.md`，对齐 Claude Code `loadMemoryPrompt`。

**删除**：`AgentLoopMemoryBootstrapComposer.swift`（整个文件）

**新建**（或简化替换）`AgentLoopMemoryBootstrapComposer.swift`：
```swift
struct AgentLoopMemoryBootstrapComposer {
    let memoryIndexReader: MemoryIndexReader
    let memoryDir: URL

    func compose() -> AgentLoopMemoryBootstrapComposition {
        guard let result = memoryIndexReader.read(from: memoryDir.appending("MEMORY.md")) else {
            return AgentLoopMemoryBootstrapComposition()
        }
        // 注入为系统提示补丁，不再用 user/assistant 消息对
        return AgentLoopMemoryBootstrapComposition(
            systemPromptSection: buildMemorySection(result.content)
        )
    }
}
```

**修改 `MemoryBootstrapHook`**：
- `loader` 改为调用新 Composer
- 注入方式：`AgentLoopHookResult.systemPromptAppend(section)` 而不是 `.messagePatch`（两条 user/assistant 插入）
- 移除硬编码中文 "【RMS】以下是当前任务的认知状态…" 前缀

**注入格式**（对齐 Claude Code `buildMemoryLines`）：
```markdown
## Your Memory

The following are your persistent memories from past sessions.

<memory>
[MEMORY.md content]
</memory>

This directory already exists — write to it directly with the memory_write tool.
```

**完成标志**：新对话启动时，系统提示包含 MEMORY.md 内容节；不再出现中文 "[RMS]" 用户消息。

---

### Feature M-06：修复 Extraction Subagent → 写 Markdown 文件而非 RMSInsightStore

**目标**：`SessionMemoryExtractorService` 启动的提取 subagent 当前受限于 `memory_write` 工具（写入 RMS）；删除 RMS 后，提取 subagent 应拥有直接写 `memoryDir` 的能力，对齐 Claude Code `createAutoMemCanUseTool`。

**修改 `SessionMemoryExtractorService.runExtraction()`**：
1. 删除从 `RMSInsightStore` 读取 existing insights 的部分
2. 替换工具集：从 `buildExtractionTools()` 返回的工具改为包含 `memory_write`（新版，写文件）而非旧版 RMS 路径
3. 删除 `ClaudeService+MemoryExtraction.swift`，工具构建逻辑内联或移至 `ClaudeService+ToolBuilder`

**修改 `MemoryExtractionPromptBuilder`**：
1. 删除 "## Existing memories（RMSInsights 列表）" 段落
2. 新增："当前已有的记忆文件" —— 由 `MemoryTopicScanner` 扫描后注入 manifest，防重复写入（对齐 Claude Code `scanMemoryFiles` 注入 listing）
3. 保持四类型语义指导（user/feedback/project/reference），与 Claude Code `buildExtractAutoOnlyPrompt` 对齐
4. 新增 `body_structure` 指引（为 `feedback` 类型添加 "Why:" / "How to apply:" 结构要求）
5. 新增 `when_to_save` 中关于相对日期转绝对日期的指引

**完成标志**：session 结束触发提取后，`memoryDir` 出现新 `.md` 文件；`RMSInsightStore` 不被写入。

---

### Feature M-07：修复 Memory Index 构建路径（从文件系统驱动）

**目标**：现在 `MEMORY.md` 是由 `MemoryIndexWriter.build(records: [MemoryRecord])` 从结构化 JSON 记录构建的；删除 MemoryRecord 系统后，需改为从文件系统扫描构建。

**修改 `MemoryIndexFileSystem.swift`**：
- 原 `rebuild(with records: [MemoryRecord])` 改为 `rebuildFromDirectory()`
- 内部流程：
  1. `MemoryTopicScanner.scan(memoryDir:)` 扫描所有 `.md` 文件 frontmatter
  2. 按 mtime 排序（最新在前）
  3. 每行格式：`- [title](filename) — description`（从 frontmatter 读取）
  4. 应用 `maxLines=200` / `maxBytes=25000` 截断规则
  5. 写入 `MEMORY.md`

**修改 `MemoryIndexWriter.swift`**：
- 删除 `build(records: [MemoryRecord])` 方法
- 保留截断逻辑（`truncate(lines:)`），供 `MemoryIndexFileSystem` 内部调用

**完成标志**：`MEMORY.md` 内容反映 `memoryDir` 中的实际 `.md` 文件，无需 `MemoryRecord` 中间层。

---

### Feature M-08：内存类型 Frontmatter 强制校验

**目标**：确保所有通过 `memory_write` 工具和提取 subagent 写入的文件都含有合法的 `type:` frontmatter 字段，对齐 Claude Code `parseMemoryType`。

**新增 `MemoryTopicFrontmatter.swift`**：
```swift
enum MemoryTopicType: String, CaseIterable {
    case user, feedback, project, reference
    
    static func parse(_ raw: String?) -> MemoryTopicType? {
        guard let raw else { return nil }
        return MemoryTopicType(rawValue: raw.lowercased())
    }
}

struct MemoryTopicFrontmatter {
    var type: MemoryTopicType?
    var title: String
    var description: String?
    var createdAt: Date
}
```

**修改 `MemoryTopicScanner`**：
- `MemoryTopicHeader.memoryType: String?` 替换为 `memoryType: MemoryTopicType?`（通过 `MemoryTopicType.parse()` 解析）

**修改 `MemoryManifestFormatter`**：
- type tag 显示对齐 Claude Code：`[user]`、`[feedback]`、`[project]`、`[reference]`，未知类型显示为空

**修改 `MemoryTopicFileComposer`**：
- 写 topic 文件时，type 为空则默认为 `project`（fallback）

**完成标志**：manifest 行始终带 `[type]` 标签；`MemoryTopicType` 类型安全枚举。

---

### Feature M-09：Memory Age / Freshness 注入规范化

**目标**：对齐 Claude Code `memoryFreshnessText()` —— 对超过 1 天的记忆在注入时附加陈旧警告。

**现状**：`RelevantMemoryRecallService.formatInjectionBlock()` 已有 freshness 逻辑，但与 Claude Code 措辞不同，且没有独立的 `memoryAge(mtimeMs:)` 工具函数。

**新增 `MemoryAge.swift`**（对齐 `memoryAge.ts`）：
```swift
func memoryAgeDays(_ mtimeMs: Double) -> Int
func memoryAge(_ mtimeMs: Double) -> String    // "today" / "yesterday" / "N days ago"
func memoryFreshnessText(_ mtimeMs: Double) -> String   // 空字符串或陈旧警告句
func memoryFreshnessNote(_ mtimeMs: Double) -> String   // <system-reminder> 包装
```

**修改 `RelevantMemoryRecallService.formatInjectionBlock()`**：
- 使用 `memoryFreshnessNote()` 替换现有 freshness 逻辑
- 措辞对齐："This memory is N days old. Memories are point-in-time observations..."

**完成标志**：超过 1 天的 recalled 记忆在注入块中包含 freshness 警告。

---

### Feature M-10：AppSettings 清理 + 测试修复

**目标**：清理删除后散落在 `AppSettings`、View、测试中的死引用。

**`AppSettings` 中删除的字段**：
```
memoryConsolidationEnabled
memoryConsolidationMinHours
memoryConsolidationMinSessions
```

**`AppSettings` 中保留的字段**：
```
memoryEnabled             ← 保留（控制整体 memory 功能开关）
```

**更新测试**：
- `ClaudeServiceMemoryExtractionToolsTests` — 验证新的 extraction 工具集（不含 RMS 路径）
- `ClaudeServiceMemoryGuidanceInjectionTests` — 验证 bootstrap 注入格式（系统提示而非消息对）
- 新增：`MemoryWriteToFileTests` — 验证 `executeFileMemoryWrite()` 创建 `.md` 文件并更新 MEMORY.md
- 新增：`MemoryIndexRebuildFromDirectoryTests` — 验证 `rebuildFromDirectory()` 正确构建索引

**清理工具**：
```
Services/Utilities/MemoryBusinessLogger.swift  → 检查是否只引用 RMS/MemoryRecord；若是则删除
```

**完成标志**：`xcodebuild test` 全部通过；无废弃符号编译警告。

---

---

## 补充分析：Session Memory（会话内记忆）的缺失

### Claude Code 的 Session Memory 设计

Claude Code 除了跨会话持久记忆（`memory/` 目录），还维护一个**会话生命周期内**的独立 Notes 文件，称为 Session Memory。两者是正交的系统：

```
持久记忆 (memory/ 目录)          ← 跨会话，agentGui 已有实现
Session Memory (summary.md)   ← 会话内持续更新，agentGui 完全缺失
```

**Session Memory 工作原理**：

1. **存储位置**：`{projectDir}/{sessionId}/session-memory/summary.md`（session 级别，不跨会话）
2. **触发时机**：`postSamplingHook` —— 每次模型采样后检查：
   - 上下文 Token 数首次超过 10,000 时初始化
   - 此后每增长 5,000 tokens 且累计 3 次工具调用后触发更新
3. **更新方式**：forked agent（FileEditTool）更新 `summary.md`，并行发出所有 Edit 调用后停止
4. **Summary 模板**（9 个固定节，结构不可破坏）：
   ```markdown
   # Session Title         ← 5-10 词描述性标题
   # Current State         ← 当前正在做什么，待完成任务
   # Task specification    ← 用户要求构建什么
   # Files and Functions   ← 重要文件及其作用
   # Workflow              ← 常用命令和执行顺序
   # Errors & Corrections  ← 遇到的错误和修复方式
   # Codebase and System Documentation
   # Learnings             ← 什么有效，什么无效
   # Key results           ← 用户要求的精确输出
   ```
5. **下游用途**
   - **Context Compaction**：`/compact` 命令优先用 `summary.md` 替换旧消息，保留近期上下文
   - **Away Summary**：用户离开再回来时，基于 `summary.md` 生成 1-3 句"离开期间进展"
   - **autoDream（consolidation）**：自动整合时从 session transcripts 提炼，`summary.md` 作为辅助 signal
   - **Skillify**：`/skill` 命令将 `summary.md` 注入给 skill 生成 agent 作为上下文

**关键设计细节**：
- `summary.md` **不注入系统提示**，只在 compaction、away summary、skill 时按需读取
- 更新是 sequential 的（防并发覆写），不阻塞主 loop（postcallback 立即返回）
- 会话结束后 `summary.md` **不删除**，但下次新 session（不同 sessionId）会创建新文件
- 超出 `MAX_SECTION_LENGTH=2000 tokens/section` 时 subagent 自动压缩该节旧内容

---

### Feature M-11：实现 Session Memory（会话内 Notes 自动更新）

**目标**：新增与 Claude Code 对齐的 session-scoped notes 文件，支持 context compaction 时使用。

**新增文件 `Services/SessionMemory/SessionMemoryService.swift`**：
```swift
/// 会话内记忆维护服务。
/// 使用 forked subagent 在后台周期性更新 summary.md，不阻塞主 loop。
struct SessionMemoryService: Sendable {

    /// 触发阈值（对齐 Claude Code 默认值）
    static let minimumTokensToInit = 10_000
    static let minimumTokensBetweenUpdate = 5_000
    static let toolCallsBetweenUpdates = 3

    let sessionId: String
    let memoryDB: URL    // 指向 {agentGuiDir}/sessions/{sessionId}/session-memory/summary.md
    
    /// 判断是否应触发 session memory 更新（在 AgentLoopHook 中调用）
    func shouldExtract(currentTokenCount: Int, toolCallsSinceLast: Int, ...) -> Bool
    
    /// 构建 session memory hook callback（forked subagent 更新 summary.md）
    func buildCallback() -> @Sendable (AgentLoopHookContext) async -> Void
}
```

**新增 `Services/SessionMemory/SessionMemoryPromptBuilder.swift`**：
- 默认 9 节模板（对齐 Claude Code `DEFAULT_SESSION_MEMORY_TEMPLATE`）
- 支持读取自定义模板 `~/.agentgui/session-memory/config/template.md`
- 生成 update prompt，强调：并行发出所有 Edit 调用，不修改节头和斜体描述行
- `# Current State` 节最关键，compaction 时优先保留

**新增 `Services/AgentLoopHooks/SessionMemoryHook.swift`**：
```swift
/// postSamplingHook（willFinishRound）：检查阈值，满足则 fire-and-forget 更新 summary.md
struct SessionMemoryHook: AgentLoopHook {
    let id = "session-memory"
    let order = 85    // 在 MemoryExtractionHook(90) 之前
    let kind: AgentLoopHookKind = .observer
    
    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willFinishRound    // 每轮结束后检查，而非仅 willFinishRun
    }
}
```

**Session Memory 路径**：
```
{ConfigDirectoryManager.shared.agentGuiDir}/
    sessions/
        {sessionId}/
            session-memory/
                summary.md    ← 会话内 notes
```

**与现有系统的交互**：
- **Context Compaction**（若实现）：压缩时先 `waitForSessionMemoryExtraction()`，然后将 `summary.md` 作为压缩的基础上下文注入新消息链
- **RelevantMemoryRecallService**：**不**使用 `summary.md`（recall 只用持久记忆）
- **MemoryExtractionHook**：session 结束时提取的 forked agent 可**选择性读取** `summary.md` 作为本次提取的辅助附上下文（可选优化，非必须）

**完成标志**：长对话（超过 10k tokens）后，`sessions/{id}/session-memory/summary.md` 被自动创建并持续更新；每次更新后不阻塞主对话流程。

---

### Feature M-12：Away Summary（会话恢复摘要）

**目标**：用户离开再回到对话时，显示 1-3 句"离开期间进展"，基于 `summary.md` 和近期对话记录。

这是 agentGui 中完全缺失的 UX 特性，对应 Claude Code `awaySummary.ts`。

**新增 `Services/SessionMemory/AwaySummaryService.swift`**：
```swift
struct AwaySummaryService: Sendable {
    static let recentMessageWindow = 30    // 只取最近 30 条消息

    /// 生成离开摘要；若消息为空或生成失败则返回 nil
    func generate(
        messages: [MessageParameter.Message],
        sessionMemoryPath: URL?,   // summary.md 路径
        service: any AnthropicService
    ) async -> String?
}
```

**Prompt 模板**（对齐 Claude Code）：
```
[session memory block (if exists)]
The user stepped away and is coming back. Write exactly 1-3 short sentences. 
Start by stating the high-level task. Next: the concrete next step. 
Skip status reports and commit recaps.
```

**集成 `SessionListView` / `ChatView`**：
- 检测"用户回来"的时机：切换前台（`NSApplicationDelegate`/`scenePhase` 变化）且距上次活动超过阈值（如 5 分钟）
- 显示位置：对话顶部临时 banner 或 session list 的副标题

**完成标志**：后台超过 5 分钟后重新激活 app，chat 界面显示简短进展摘要。

---

### Session Memory vs 持久记忆的关系（总结）

```
Session Memory (M-11/M-12)                持久记忆 (M-01~M-10)
──────────────────────────────────────    ──────────────────────────────────────
生命周期：单个 session                      生命周期：跨 session 永久保留
存储：sessions/{id}/summary.md              存储：memory/*.md + MEMORY.md
更新时机：每 N 个 token 增量时              更新时机：session 结束时（extraction hook）
内容：当前任务进展、文件、命令、错误         内容：用户偏好、项目决策、feedback、references
注入：按需（compaction/away/skill）         注入：bootstrap 阶段注入系统提示
被 recall：否                              被 recall：是（side-query 选择相关 topic 文件）
```

---

## 执行优先级

| Feature | 依赖 | 优先级 | 预估影响行数 |
|---------|------|--------|------------|
| M-01 删除 RMS | 无 | P0 | -1,624 行 |
| M-02 删除 MemoryRecord/治理层 | M-01 | P0 | -800+ 行 |
| M-03 删除 Consolidation | 无 | P0 | -400+ 行 |
| M-04 修复 memory_write → 文件 | M-01、M-07 | P1 | 改写 ~150 行 |
| M-05 修复 Bootstrap → MEMORY.md | M-01 | P1 | 改写 ~80 行 |
| M-06 修复 Extraction → 文件 | M-01、M-04 | P1 | 改写 ~100 行 |
| M-07 Index 从文件系统构建 | M-02 | P1 | 改写 ~60 行 |
| M-08 Frontmatter 类型校验 | M-04 | P2 | 新增 ~80 行 |
| M-09 Memory Age 规范化 | 无 | P2 | 新增 ~60 行 |
| M-10 Settings 清理 + 测试 | M-01~M-07 | P2 | 零散清理 |
| M-11 Session Memory Notes | 无 | P1 | 新增 ~300 行 |
| M-12 Away Summary | M-11 | P2 | 新增 ~100 行 |

---

## 保留的组件（不变）

以下组件与 Claude Code 已良好对齐，重构后保留：

| 文件 | 说明 |
|------|------|
| `Memory/MemoryTopicScanner.swift` | 对齐 `memoryScan.ts` |
| `Memory/MemoryManifestFormatter.swift` | 对齐 `formatMemoryManifest()` |
| `Memory/RelevantMemoryRecallService.swift` | 对齐 `findRelevantMemories.ts` |
| `Memory/RelevantMemorySideQuery.swift` | 对齐 `selectRelevantMemories()` |
| `Memory/MemoryRecallSessionState.swift` | session 级去重（`alreadySurfaced`）|
| `Memory/MemoryIndexReader.swift` | 对齐 `truncateEntrypointContent()` |
| `Memory/MemoryTopicFilename.swift` | 文件名生成 |
| `Memory/MemoryIndexFileSystem.swift` | 保留，M-07 改造 |
| `Services/AgentLoopHooks/MemoryRecallHook.swift` | hook 接口不变 |
| `Services/AgentLoopHooks/MemoryExtractionHook.swift` | hook 接口不变 |
| `Services/AgentLoopHooks/MemoryBootstrapHook.swift` | hook 接口不变，内部改造 |
| `Models/MemoryRuntimeSnapshot.swift` | 执行运行时 snapshot，与 RMS 无关 |
| `Models/MemoryScope.swift` | 保留 `.session(id:)` 和 `.global`，删 `.user` 混用 |
