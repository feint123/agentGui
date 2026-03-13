# 移除 StoryMemory 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 从 agentGui 中移除 StoryMemory 相关运行时、工具、SwiftData 模型、界面入口与测试覆盖，同时保证普通对话、统一记忆运行时、备份恢复与工作流能力不因残留依赖而崩溃。

**Architecture:** 采用“先切断入口，再删除实现，最后做兼容收尾”的顺序。优先让主链不再构造、注入、展示或读取 StoryMemory，再删除底层模型和专用服务，最后清理测试、备份字段和文档，避免一次性删文件导致编译链路与持久化链路同时失稳。

**Tech Stack:** Swift 6、SwiftUI、SwiftData、XCTest/Swift Testing、Xcode project

---

## 范围与假设

- 本计划默认“移除 StoryMemory 功能”包含以下内容：运行时注入、工具定义与执行、StoryMemory SwiftData 模型、写作项目 UI、设置项、审计展示、测试夹具。
- 本计划默认不强制清理历史文档 `docs/spec` / `docs/technical-spec` / 旧计划中的 StoryMemory 讨论；这些可以作为最后的文档收尾项处理，而不是阻塞代码删除。
- 对已有本地持久化数据，目标是“应用不再依赖或写入 StoryMemory”，而不是保证旧 StoryMemory 数据仍可继续使用。
- 对 unified memory / backup archive 中已经落盘的旧字段，优先保证读取兼容或安全忽略，不为保留 StoryMemory 能力继续保留整条功能链。

## 受影响主链

### 入口与运行时

- `agentGui/Models/AppSettings.swift`
- `agentGui/Services/ClaudeService+AgenticLoop.swift`
- `agentGui/Services/ClaudeService+ToolBuilder.swift`
- `agentGui/Services/ToolRegistry.swift`
- `agentGui/Services/ToolsetResolver.swift`
- `agentGui/Services/MemoryRuntimeCoordinator.swift`
- `agentGui/Services/AgentLoopHookDependencyFactory.swift`
- `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `agentGui/Models/AgentRuntimeDefinition.swift`
- `agentGui/Models/WorkflowRoleDefinition.swift`

### StoryMemory 专用实现

- `agentGui/Services/ClaudeService+StoryMemoryTools.swift`
- `agentGui/Services/StoryMemoryService.swift`
- `agentGui/Services/StoryMemoryRetrievalService.swift`
- `agentGui/Services/StoryMemoryPromptAssembler.swift`
- `agentGui/Services/StoryMemoryDelegationService.swift`
- `agentGui/Services/StoryMemorySubagentPromptBuilder.swift`
- `agentGui/Services/StoryMemoryStoreAdapter.swift`
- `agentGui/Services/StoryMemoryExtractionService.swift`
- `agentGui/Models/StoryMemoryDelegation.swift`

### StoryMemory SwiftData 模型与会话绑定

- `agentGui/Models/WritingProject.swift`
- `agentGui/Models/StoryCharacterProfile.swift`
- `agentGui/Models/StoryTimelineEvent.swift`
- `agentGui/Models/StoryChapterRecord.swift`
- `agentGui/Models/StorySceneRecord.swift`
- `agentGui/Models/StoryWorldRule.swift`
- `agentGui/Models/StoryLocationProfile.swift`
- `agentGui/Models/StoryForeshadowItem.swift`
- `agentGui/Models/StoryStyleProfile.swift`
- `agentGui/Models/StoryContinuityIssue.swift`
- `agentGui/Models/Session.swift`
- `agentGui/Models/BackupArchiveManifest.swift`
- `agentGui/Services/BackupArchiveService.swift`

### 展示与视图模型

- `agentGui/ContentView.swift`
- `agentGui/Views/ChatView.swift`
- `agentGui/Views/ChatView+Toolbar.swift`
- `agentGui/Views/SubagentTaskCardView.swift`
- `agentGui/ViewModels/ToolCallRowPresentation.swift`
- `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- `agentGui/Models/ToolCall.swift`
- `agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift`
- `agentGui/Views/StoryMemory/StoryProjectListView.swift`
- `agentGui/Views/StoryMemory/StoryProjectInspectorView.swift`
- `agentGui/Views/StoryMemory/StoryProjectPresentation.swift`
- `agentGui/Views/StoryMemory/StoryTimelineView.swift`

### 测试与夹具

- `agentGuiTests/StoryMemoryModelTests.swift`
- `agentGuiTests/StoryMemoryRetrievalServiceTests.swift`
- `agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- `agentGuiTests/StoryMemoryDelegationServiceTests.swift`
- `agentGuiTests/StoryMemoryStoreAdapterTests.swift`
- `agentGuiTests/StoryMemorySubagentContractTests.swift`
- `agentGuiTests/ReleaseScenarioTests.swift`
- `agentGuiTests/AgentMessageFlowPresentationTests.swift`
- `agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`
- `agentGuiTests/TestSupport/InMemoryAppHarness.swift`

## 实施策略

### 任务 1：先冻结行为边界，补一组“移除后存在性”测试

**Files:**
- Modify: `agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- Modify: `agentGuiTests/StoryMemoryModelTests.swift`
- Modify: `agentGuiTests/ReleaseScenarioTests.swift`
- Modify: `agentGuiTests/AgentMessageFlowPresentationTests.swift`

**Step 1: 写失败测试，定义移除后的目标行为**

- 将现有依赖 StoryMemory 的“正向能力测试”改写为“能力不存在”断言。
- 目标最少包括：
  - 主 Agent / Subagent 不再暴露 `story_memory_*` 工具。
  - 设置默认值中不再出现 `enableStoryMemory` / `storyMemoryPromptBudget` 等字段。
  - 消息展示不再渲染 story memory 审计摘要。
  - release scenario 不再依赖 `makeStoryMemoryScenario()`。

**Step 2: 跑最小测试集，确认当前必然失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/StoryMemoryModelTests \
  -only-testing:agentGuiTests/ReleaseScenarioTests \
  -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: 现有 StoryMemory 断言与新“功能已移除”断言冲突，测试失败。

**Step 3: 提交测试基线变更**

```bash
git add agentGuiTests/StoryMemoryPromptAssemblerTests.swift agentGuiTests/StoryMemoryModelTests.swift agentGuiTests/ReleaseScenarioTests.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "test: define removal expectations for story memory"
```

### 任务 2：切断入口与工具注册，先让主链不再触发 StoryMemory

**Files:**
- Modify: `agentGui/Models/AppSettings.swift`
- Modify: `agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `agentGui/Services/ClaudeService+ToolBuilder.swift`
- Modify: `agentGui/Services/ToolRegistry.swift`
- Modify: `agentGui/Services/ToolsetResolver.swift`
- Modify: `agentGui/Models/AgentRuntimeDefinition.swift`
- Modify: `agentGui/Models/WorkflowRoleDefinition.swift`

**Step 1: 删除设置和角色层的 StoryMemory 开关**

- 移除 `enableStoryMemory`、`storyMemoryAutoExtract`、`storyMemoryPromptBudget`、`storyMemoryProjectMode`。
- 移除 `WorkflowRoleDefinition.enableStoryMemoryTools` 和 `ToolGrant.storyMemory` 的投影逻辑。
- 如果 `ToolGrant.storyMemory` 仍被其它功能引用，先把引用点清零，再删除枚举 case。

**Step 2: 删除运行时入口**

- 删除 `buildStoryMemoryBootstrap(...)` 及其调用链。
- `buildUnifiedMemoryBootstrap(...)` 里的 `creativeWriting` 判定不再依赖 `settings.enableStoryMemory`。
- `ClaudeService+ToolBuilder.swift` 不再向 subagent 注入任何 `story_memory_*` ephemeral tools。
- `ToolRegistry.swift` 不再注册 `story_memory_upsert_character`、`story_memory_query`、`story_memory_verify_continuity`。
- `ToolsetResolver.swift` 删除 `.storyMemory` 分组解析。

**Step 3: 跑入口相关测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/BashToolSchemaTests \
  -only-testing:agentGuiTests/ToolsetResolverTests \
  -only-testing:agentGuiTests/WorkflowRoleToolGrantTests
```

Expected: StoryMemory 相关测试应转为通过；若其它测试仍引用旧布尔字段，会在这一轮暴露。

**Step 4: 提交主链入口裁剪**

```bash
git add agentGui/Models/AppSettings.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ToolRegistry.swift agentGui/Services/ToolsetResolver.swift agentGui/Models/AgentRuntimeDefinition.swift agentGui/Models/WorkflowRoleDefinition.swift
git commit -m "refactor: remove story memory runtime entry points"
```

### 任务 3：移除执行协调与消息审计中的 StoryMemory 特殊分支

**Files:**
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- Modify: `agentGui/Models/ToolCall.swift`
- Modify: `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Modify: `agentGui/ViewModels/ToolCallRowPresentation.swift`
- Modify: `agentGui/Views/SubagentTaskCardView.swift`
- Modify: `agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`
- Modify: `agentGuiTests/AgentMessageFlowPresentationTests.swift`

**Step 1: 删除 ToolCall 上的 StoryMemory 审计字段**

- 删除 `storyMemoryTaskType`、`storyMemoryStatus`、`storyMemoryRiskSummary`、`storyMemoryFallbackNote`。
- 同步删除 snapshot builder、presentation builder、card view 中的衍生展示逻辑。

**Step 2: 简化 coordinator 依赖**

- 从 `AgentLoopToolExecutionCoordinator.Dependencies` 中删除 `populateStoryMemoryAuditFields`。
- 更新 builder、生产代码、测试 stub，避免留下空回调占位。

**Step 3: 跑展示与协调器测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests \
  -only-testing:agentGuiTests/AgentMessageFlowPresentationTests \
  -only-testing:agentGuiTests/ChatMessageListSnapshotBuilderTests
```

Expected: 不再有任何 presentation/test 对 StoryMemory 审计字段的编译依赖。

**Step 4: 提交执行链清理**

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinator.swift agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift agentGui/Models/ToolCall.swift agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift agentGui/ViewModels/ToolCallRowPresentation.swift agentGui/Views/SubagentTaskCardView.swift agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "refactor: remove story memory audit handling"
```

### 任务 4：删除 StoryMemory 专用服务与模型，处理 SwiftData 关系和会话绑定

**Files:**
- Delete: `agentGui/Services/ClaudeService+StoryMemoryTools.swift`
- Delete: `agentGui/Services/StoryMemoryService.swift`
- Delete: `agentGui/Services/StoryMemoryRetrievalService.swift`
- Delete: `agentGui/Services/StoryMemoryPromptAssembler.swift`
- Delete: `agentGui/Services/StoryMemoryDelegationService.swift`
- Delete: `agentGui/Services/StoryMemorySubagentPromptBuilder.swift`
- Delete: `agentGui/Services/StoryMemoryStoreAdapter.swift`
- Delete: `agentGui/Services/StoryMemoryExtractionService.swift`
- Delete: `agentGui/Models/StoryMemoryDelegation.swift`
- Delete: `agentGui/Models/WritingProject.swift`
- Delete: `agentGui/Models/StoryCharacterProfile.swift`
- Delete: `agentGui/Models/StoryTimelineEvent.swift`
- Delete: `agentGui/Models/StoryChapterRecord.swift`
- Delete: `agentGui/Models/StorySceneRecord.swift`
- Delete: `agentGui/Models/StoryWorldRule.swift`
- Delete: `agentGui/Models/StoryLocationProfile.swift`
- Delete: `agentGui/Models/StoryForeshadowItem.swift`
- Delete: `agentGui/Models/StoryStyleProfile.swift`
- Delete: `agentGui/Models/StoryContinuityIssue.swift`
- Modify: `agentGui/Models/Session.swift`
- Modify: `agentGui/Models/BackupArchiveManifest.swift`
- Modify: `agentGui/Services/BackupArchiveService.swift`

**Step 1: 删除会话与备份中的写作项目绑定**

- 移除 `Session.activeWritingProjectId`。
- 移除 `BackupArchiveManifest.activeWritingProjectId` 及备份读写映射。
- 检查任何恢复逻辑，确保旧 archive 解码时不会因缺少字段崩溃；必要时保留可选解码字段，但不再写出。

**Step 2: 删除 StoryMemory SwiftData 实体与服务**

- 删除所有 StoryMemory 模型文件及其 service / adapter / prompt assembler。
- 任何引用 `WritingProject` 或 story profile 实体的查询、关系、工具执行都必须先断开，再删文件。

**Step 3: 清理工程引用**

- 如果 `agentGui.xcodeproj/project.pbxproj` 仍显式引用这些文件，删除对应 PBX 引用。
- 如果工程使用文件系统同步分组，也要至少验证删除文件后工程可正常索引与编译。

**Step 4: 跑模型与备份相关测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BackupArchiveServiceTests \
  -only-testing:agentGuiTests/agentGuiTests
```

Expected: SwiftData schema、备份恢复与基础会话流程不再依赖 StoryMemory 模型。

**Step 5: 提交底层删除**

```bash
git add agentGui/Models agentGui/Services agentGui.xcodeproj/project.pbxproj
git commit -m "refactor: delete story memory models and services"
```

### 任务 5：从统一记忆和主界面中移除 StoryMemory 残留引用

**Files:**
- Modify: `agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `agentGui/Models/MemoryRecord.swift`
- Modify: `agentGui/Models/MemoryRuntimeSnapshot.swift`
- Modify: `agentGui/Models/UnifiedMemoryStoredRecord.swift`
- Modify: `agentGui/Services/MemoryGovernanceService.swift`
- Modify: `agentGui/ContentView.swift`
- Modify: `agentGui/Views/ChatView.swift`
- Modify: `agentGui/Views/ChatView+Toolbar.swift`
- Delete: `agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift`
- Delete: `agentGui/Views/StoryMemory/StoryProjectListView.swift`
- Delete: `agentGui/Views/StoryMemory/StoryProjectInspectorView.swift`
- Delete: `agentGui/Views/StoryMemory/StoryProjectPresentation.swift`
- Delete: `agentGui/Views/StoryMemory/StoryTimelineView.swift`

**Step 1: 删除统一记忆中的 StoryMemory 注入路径**

- `MemoryRuntimeCoordinator` 删除 `storyRecordsProvider` 及 `StoryMemoryStoreAdapter` 注入。
- 重新审视 `MemoryRecord.Source` / `UnifiedMemoryStoredRecord.SourceKind` 中的 `.storyMemory`：
  - 若只用于历史数据兼容，保留解码 case，但从生产写路径与选择逻辑中移除。
  - 若没有落盘兼容要求，则连同枚举 case 一并删除。

**Step 2: 删除 UI 中的 StoryMemory 入口**

- `ContentView` 不再展示 StoryMemory 设置区。
- `ChatView` / `ChatView+Toolbar` 不再以 active writing project 或 story memory enabled 为条件展示入口。
- 删除整个 `Views/StoryMemory` 目录下的 UI 文件。

**Step 3: 跑界面与记忆运行时测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests \
  -only-testing:agentGuiTests/ChatMessageListSnapshotBuilderTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapHookTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapComposerTests
```

Expected: 主界面和统一记忆运行时不再引用 StoryMemory provider、字段或 UI 入口。

**Step 4: 提交 UI 与记忆收尾**

```bash
git add agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Models/MemoryRecord.swift agentGui/Models/MemoryRuntimeSnapshot.swift agentGui/Models/UnifiedMemoryStoredRecord.swift agentGui/Services/MemoryGovernanceService.swift agentGui/ContentView.swift agentGui/Views agentGuiTests
git commit -m "refactor: remove story memory from memory runtime and ui"
```

### 任务 6：清理 StoryMemory 专项测试夹具，替换为通用场景

**Files:**
- Delete: `agentGuiTests/StoryMemoryModelTests.swift`
- Delete: `agentGuiTests/StoryMemoryRetrievalServiceTests.swift`
- Delete: `agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- Delete: `agentGuiTests/StoryMemoryDelegationServiceTests.swift`
- Delete: `agentGuiTests/StoryMemoryStoreAdapterTests.swift`
- Delete: `agentGuiTests/StoryMemorySubagentContractTests.swift`
- Modify: `agentGuiTests/TestSupport/InMemoryAppHarness.swift`
- Modify: `agentGuiTests/ReleaseScenarioTests.swift`

**Step 1: 删除专属测试文件**

- 直接删除纯 StoryMemory 功能测试。
- 如果其中有对通用能力的有效覆盖，例如“工具只在特定上下文出现”，把这部分转移到非 StoryMemory 专用测试文件中。

**Step 2: 重写测试夹具**

- 删除 `InMemoryAppHarness.makeStoryMemoryScenario()`。
- `ReleaseScenarioTests` 改为使用 coding / workflow / unified memory 的通用场景，避免回归测试出现空洞。

**Step 3: 跑 smoke 测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test
```

如果全量单测耗时过长，则补跑仓库已有 smoke 任务：

```bash
./scripts/run_quality_smoke.sh
```

Expected: 项目在无 StoryMemory 代码的前提下仍能全量通过或只剩与本次改动无关的既有失败。

**Step 4: 提交测试面收尾**

```bash
git add agentGuiTests scripts docs
git commit -m "test: remove story memory test fixtures"
```

### 任务 7：文档与回归核对

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: 仍然描述 StoryMemory 为现行能力的文档

**Step 1: 更新对外说明**

- 删掉 README、设置说明、测试说明中把 StoryMemory 视为现行功能的文字。
- 若保留历史 spec，明确标记为“历史设计，不代表当前实现”。

**Step 2: 最终回归检查**

Run:

```bash
rg "StoryMemory|story memory|story_memory|enableStoryMemory|activeWritingProjectId|storyMemory" agentGui agentGuiTests README.md CLAUDE.md docs
```

Expected: 代码目录中不再残留 StoryMemory 生产引用；文档目录只保留明确的历史记录或迁移说明。

**Step 3: 最终提交**

```bash
git add README.md CLAUDE.md docs
git commit -m "docs: remove story memory references"
```

## 风险与检查点

### 风险 1：SwiftData 模型删除导致旧本地库迁移失败

- 优先在测试或本地干净数据目录验证启动。
- 如果当前 schema 删除会触发迁移异常，需要补一层兼容策略：保留最小模型壳用于读旧库，先停止引用，再在后续版本做数据迁移。

### 风险 2：统一记忆仍隐式依赖 `.storyMemory` source kind

- `MemoryRuntimeCoordinator`、`MemoryRecord`、`UnifiedMemoryStoredRecord` 必须一起检查，不能只删 adapter。
- 如果旧 unified records 已持久化为 `.storyMemory`，至少要做到“能读旧值但不再生成新值”。

### 风险 3：写作项目 UI 删除后出现悬空入口

- `ContentView`、`ChatView`、toolbar、inspector 入口要一起删。
- 回归时手动检查设置页、聊天页、消息卡片页是否还有空白区块或不可点击入口。

### 风险 4：测试覆盖被整体删空

- 删除 StoryMemory 专属测试前，先把通用行为断言迁移到其它测试文件。
- 至少保留以下非 StoryMemory 价值的覆盖：工具上下文可见性、消息展示、统一记忆启动、备份恢复。

## 建议执行顺序

1. 先做任务 1 和任务 2，确保主链停止暴露 StoryMemory。
2. 再做任务 3 和任务 4，删除执行链和底层模型。
3. 然后做任务 5 和任务 6，清空 UI、统一记忆残留与测试夹具。
4. 最后做任务 7，处理文档和全局残留扫描。

## 完成定义

- `agentGui` 生产代码中不再存在 StoryMemory 运行时、工具、模型、UI、设置项。
- `Session` / 备份恢复 / 统一记忆路径不再依赖 `activeWritingProjectId` 或 StoryMemory source。
- StoryMemory 专项测试被删除或被通用测试替代。
- `xcodebuild test` 或仓库 smoke 测试可以完成，且不存在由 StoryMemory 残留导致的编译错误。