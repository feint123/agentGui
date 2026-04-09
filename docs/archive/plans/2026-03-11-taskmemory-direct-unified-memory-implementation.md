# TaskMemory Direct Unified Memory Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the legacy `TaskMemory` JSON + adapter pipeline with a direct unified-memory read/write path, migrate historical task-memory files into unified records, and remove adapter-based main-path code.

**Architecture:** Keep `MemoryRecord` as the runtime model and `UnifiedMemoryStoredRecord` as the persistence model. Introduce a small task-memory record builder plus a legacy importer, then move all `TaskMemoryService` call sites to `UnifiedMemoryFileStoreAdapter`, switch `MemoryRuntimeCoordinator` to a unified-only session read path, and finally delete the legacy service and adapter once migration and parity tests pass.

**Tech Stack:** Swift 6, Foundation file persistence, existing `UnifiedMemoryFileStoreAdapter`, existing memory runtime services, Swift Testing, `xcodebuild` test runs on macOS.

---

## Implementation Notes

- 这份计划只解决 `TaskMemory` 直接并入统一 Memory 架构，不扩大到 `StoryMemory` 重写。
- 主链路切换必须覆盖三类入口：上下文压缩写入、反思失败写入、启动 prompt 注入读取。
- 不要把新的主逻辑塞回 `TaskMemory.swift`；核心逻辑应该落在 unified record builder / importer / query 层。
- 迁移阶段允许保留 legacy reader，但只能用于导入和对账，不能继续参与日常主读写。
- 现有 `TaskMemoryStoreAdapterTests` 是旧架构契约，最终应被替换，不应继续作为正确性依据。
- 计划按 TDD 执行：先补 focused tests，再做最小实现，再跑窄测试，最后再做清理和文档更新。

## Proposed File Layout

**Create task-memory direct-unified helpers:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryRecordFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryPromptRenderer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryLegacyImporter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemoryMigrationReport.swift`

**Modify existing main-path files:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/README.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-10-agent-architecture.md`

**Delete after migration cutover:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryStoreAdapter.swift`

**Create or replace tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryRecordFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryPromptRendererTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryLegacyImporterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryUnifiedWritePathTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedMemoryStoreContractTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryStoreAdapterTests.swift` (delete or repurpose in final cleanup task)

**Reference docs:**
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-11-taskmemory-direct-unified-memory-requirements.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-memory-governance-operations-and-taskmemory-migration-requirements.md`

### Task 1: Define TaskMemory Unified Record Conventions

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryRecordFactory.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryRecordFactoryTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRecord.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryLayer.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryKind.swift`

**Step 1: Write the failing test**

新增测试，锁定四类 TaskMemory 语义如何直接映射成统一 `MemoryRecord`。

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct TaskMemoryRecordFactoryTests {
    @Test func factoryBuildsSessionScopedRecordsForConfirmedFactsAndFailures() async throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let records = TaskMemoryRecordFactory().makeRecords(
            sessionId: "session-1",
            confirmedFacts: ["Build uses xcodebuild"],
            attemptedActions: ["Ran xcodebuild test"],
            failedAttempts: [.init(action: "Run tests", reason: "Scheme missing")],
            pendingQuestions: ["Which scheme should run?"],
            verificationEntries: [.init(item: "CI command", status: "verified")],
            timestamp: timestamp
        )

        #expect(records.count == 5)
        #expect(records.allSatisfy { $0.scope == .session(id: "session-1") })
        #expect(records.contains { $0.tags.contains("confirmed-fact") && $0.verificationStatus == .verified })
        #expect(records.contains { $0.tags.contains("failed-attempt") && $0.verificationStatus == .failed })
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TaskMemoryRecordFactoryTests
```

Expected: FAIL because `TaskMemoryRecordFactory` does not exist.

**Step 3: Write minimal implementation**

实现一个纯函数型工厂：

- 输入 `sessionId`、confirmed facts、attempted actions、failed attempts、pending questions、verification entries 和时间戳
- 输出 `[MemoryRecord]`
- 所有记录都使用 `.session(id: sessionId)` scope
- 默认 `domainProfile = "coding-task"`
- 默认 `source = .taskMemory`
- 用 tags 区分 `confirmed-fact`、`attempt`、`failed-attempt`、`pending`、`verification-entry`

```swift
struct TaskMemoryRecordFactory {
    func makeRecords(
        sessionId: String,
        confirmedFacts: [String],
        attemptedActions: [String],
        failedAttempts: [FailedAttempt],
        pendingQuestions: [String],
        verificationEntries: [VerificationEntry],
        timestamp: Date
    ) -> [MemoryRecord] {
        let scope = MemoryScope.session(id: sessionId)
        return makeConfirmedFactRecords(scope: scope, facts: confirmedFacts, timestamp: timestamp)
            + makeAttemptRecords(scope: scope, attempts: attemptedActions, timestamp: timestamp)
            + makeFailureRecords(scope: scope, failures: failedAttempts, timestamp: timestamp)
            + makePendingQuestionRecords(scope: scope, questions: pendingQuestions, timestamp: timestamp)
            + makeVerificationRecords(scope: scope, entries: verificationEntries, timestamp: timestamp)
    }
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/TaskMemoryRecordFactory.swift agentGuiTests/TaskMemoryRecordFactoryTests.swift
git commit -m "feat: define task memory unified record mapping"
```

### Task 2: Replace TaskMemory Prompt Rendering With Unified Records

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryPromptRenderer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryPromptRendererTests.swift`

**Step 1: Write the failing test**

为 prompt 渲染补测试，确保从统一 records 仍能得到原来类似的任务记忆文本结构。

```swift
import Foundation
import Testing
@testable import agentGui

struct TaskMemoryPromptRendererTests {
    @Test func rendererGroupsTaskRecordsIntoTaskMemorySections() async throws {
        let records = [
            MemoryRecord.fixture(scope: .session(id: "s1"), layer: .task, kind: .working, title: "Build uses xcodebuild", summary: "Build uses xcodebuild", tags: ["confirmed-fact"]),
            MemoryRecord.fixture(scope: .session(id: "s1"), layer: .task, kind: .working, title: "Run tests", summary: "Scheme missing", payload: .structured(["action": "Run tests", "reason": "Scheme missing"]), verificationStatus: .failed, tags: ["failed-attempt"])
        ]

        let text = TaskMemoryPromptRenderer().render(records: records)

        #expect(text.contains("## Confirmed Facts"))
        #expect(text.contains("## Failed Attempts"))
        #expect(text.contains("Build uses xcodebuild"))
        #expect(text.contains("Scheme missing"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TaskMemoryPromptRendererTests
```

Expected: FAIL because renderer does not exist.

**Step 3: Write minimal implementation**

实现 `TaskMemoryPromptRenderer`：

- 输入 `[MemoryRecord]`
- 仅消费 session-scope task-memory 相关 records
- 按 tags / verification status 分组到 `Confirmed Facts`、`Attempted Actions`、`Failed Attempts`、`Pending Questions`、`Verification Status`
- 替换 `buildCombinedMemoryText(contextMemory:taskMemory:)` 中对 `TaskMemory.toPromptText()` 的依赖

```swift
struct TaskMemoryPromptRenderer {
    func render(records: [MemoryRecord]) -> String {
        let confirmed = records.filter { $0.tags.contains("confirmed-fact") }
        let attempts = records.filter { $0.tags.contains("attempt") }
        let failures = records.filter { $0.tags.contains("failed-attempt") }
        let pending = records.filter { $0.tags.contains("pending") }
        let verification = records.filter { $0.tags.contains("verification-entry") }
        // build markdown text sections here
    }
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/TaskMemoryPromptRenderer.swift agentGui/Services/ClaudeService+ContextCompression.swift agentGuiTests/TaskMemoryPromptRendererTests.swift
git commit -m "feat: render task memory prompt from unified records"
```

### Task 3: Move Context Compression Writes To Unified Store

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryRecordFactory.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryUnifiedWritePathTests.swift`

**Step 1: Write the failing test**

先锁定：上下文压缩拿到 task-memory 提取结果后，应直接把 records 写入 unified store，而不是 `TaskMemoryService`。

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct TaskMemoryUnifiedWritePathTests {
    @Test func taskExtractionPersistsSessionRecordsIntoUnifiedStore() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let records = TaskMemoryRecordFactory().makeRecords(
            sessionId: "session-1",
            confirmedFacts: ["Build uses xcodebuild"],
            attemptedActions: [],
            failedAttempts: [],
            pendingQuestions: [],
            verificationEntries: [],
            timestamp: Date(timeIntervalSince1970: 100)
        )

        for record in records {
            _ = try store.persist(record: record)
        }

        let persisted = try store.records(for: .session(id: "session-1"), includeArchived: true)
        #expect(persisted.contains { $0.title == "Build uses xcodebuild" })
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TaskMemoryUnifiedWritePathTests
```

Expected: FAIL until the new helper file and target membership are in place.

**Step 3: Write minimal implementation**

在 `ClaudeService+ContextCompression.swift` 中完成三处替换：

- 删除 `existingTaskMemory = TaskMemoryService.shared.load(...)` 这种主读路径依赖
- `buildTaskMemory(...)` 仍可暂时输出提取 DTO，但持久化时改为 `TaskMemoryRecordFactory + UnifiedMemoryFileStoreAdapter`
- `buildCombinedMemoryText(...)` 读取 unified store 中 `.session(id: sessionId)` 的相关 records，再交给 `TaskMemoryPromptRenderer`

建议新增一个窄 helper：

```swift
private func persistTaskExtraction(
    sessionId: String,
    extraction: TaskMemoryExtraction,
    store: UnifiedMemoryFileStoreAdapter,
    timestamp: Date = Date()
) throws {
    let records = TaskMemoryRecordFactory().makeRecords(
        sessionId: sessionId,
        confirmedFacts: extraction.confirmedFacts,
        attemptedActions: extraction.attemptedActions,
        failedAttempts: extraction.failedAttempts,
        pendingQuestions: extraction.pendingQuestions,
        verificationEntries: extraction.verificationStatus,
        timestamp: timestamp
    )

    for record in records {
        _ = try store.persist(record: record)
    }
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ContextCompression.swift agentGui/Services/UnifiedMemoryFileStoreAdapter.swift agentGuiTests/TaskMemoryUnifiedWritePathTests.swift
git commit -m "feat: persist extracted task memory into unified store"
```

### Task 4: Move Reflection And Legacy Bootstrap Reads To Unified Task Records

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryUnifiedWritePathTests.swift`

**Step 1: Write the failing test**

补一个 focused test，锁定“失败反思写入”和“启动 fallback prompt”都来自 unified store。

```swift
    @Test func failedReflectionEntriesCanBeRenderedFromUnifiedStore() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let record = MemoryRecord.fixture(
            id: "failure-1",
            layer: .task,
            kind: .working,
            scope: .session(id: "s1"),
            title: "Run tests",
            summary: "Scheme missing",
            payload: .structured(["action": "Run tests", "reason": "Scheme missing"]),
            source: .taskMemory,
            verificationStatus: .failed,
            tags: ["failed-attempt"]
        )
        _ = try store.persist(record: record)

        let text = TaskMemoryPromptRenderer().render(records: try store.records(for: .session(id: "s1"), includeArchived: true))
        #expect(text.contains("Scheme missing"))
    }
```

**Step 2: Run test to verify it fails**

Run the same `TaskMemoryUnifiedWritePathTests` target command.

Expected: FAIL until the code paths are no longer using `TaskMemoryService`.

**Step 3: Write minimal implementation**

在 `ClaudeService+AgenticLoop.swift` 中：

- 把反思失败写入从 `TaskMemoryService.shared.load/save` 改成直接构造一个 failed-attempt record 和若干 attempt records
- 通过 `UnifiedMemoryFileStoreAdapter.persist(record:)` 写入 session scope

在 fallback prompt 注入路径中：

- 若 unified runtime 未启用，也不要回退到 legacy JSON
- 改为直接读取 `.session(id: sessionId)` 的 unified records，并用 `TaskMemoryPromptRenderer` 输出 prompt text

**Step 4: Run test to verify it passes**

Run the same `TaskMemoryUnifiedWritePathTests` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+ContextCompression.swift agentGuiTests/TaskMemoryUnifiedWritePathTests.swift
git commit -m "feat: route reflection and bootstrap task memory through unified store"
```

### Task 5: Make MemoryRuntimeCoordinator Unified-Only For Session Task Reads

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedMemoryStoreContractTests.swift`

**Step 1: Write the failing test**

把 Coordinator 测试收紧到“session task records 来自 unified store”，不再从单独注入的 task provider 读取。

```swift
    @Test func coordinatorReadsSessionTaskRecordsFromUnifiedStore() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        _ = try store.persist(record: MemoryRecord.fixture(
            id: "task-1",
            layer: .task,
            kind: .working,
            scope: .session(id: "s1"),
            title: "Known failure",
            source: .taskMemory,
            tags: ["failed-attempt"]
        ))

        let coordinator = MemoryRuntimeCoordinator(
            storyRecordsProvider: { _ in [] },
            unifiedRecordsProvider: { request in
                (try? store.records(for: request)) ?? []
            },
            unifiedStoreBaseDirectory: baseDirectory
        )

        let context = try await coordinator.prepareContext(for: .init(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        ))

        #expect(context.records.contains { $0.id == "task-1" })
    }
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests
```

Expected: FAIL because `MemoryRuntimeCoordinator` still has a dedicated `taskRecordsProvider` and convenience init builds a `TaskMemoryStoreAdapter`.

**Step 3: Write minimal implementation**

改造 `MemoryRuntimeCoordinator`：

- 删除 `taskRecordsProvider`
- `prepareContext(for:)` 不再手动 append task-provider 结果
- 统一通过 `unifiedRecordsProvider(request)` 获取 `.session(id: sessionId)` 下的 task records
- 保留 `storyRecordsProvider`，因为本次不重写 `StoryMemory`
- 更新 `makeForTests(...)` 帮助器，改成接受 `unifiedRecords` 而不是 `taskRecords`

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryRuntimeCoordinator.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift agentGuiTests/UnifiedMemoryStoreContractTests.swift
git commit -m "refactor: read session task memory from unified store only"
```

###  

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryLegacyImporter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemoryMigrationReport.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemory.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryLegacyImporterTests.swift`

**Step 1: Write the failing test**

为历史 JSON 导入补测试，锁定迁移报告与转换结果。

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct TaskMemoryLegacyImporterTests {
    @Test func importerConvertsLegacyTaskMemoryFileIntoUnifiedRecords() async throws {
        let legacy = TaskMemory(sessionId: "session-1")
        let baseDirectory = try makeTemporaryDirectory()
        let importer = TaskMemoryLegacyImporter(
            recordFactory: TaskMemoryRecordFactory(),
            unifiedStore: UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        )

        let report = try importer.importMemory(legacy)

        #expect(report.sessionID == "session-1")
        #expect(report.generatedRecordCount >= 0)
        let persisted = try UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
            .records(for: .session(id: "session-1"), includeArchived: true)
        #expect(persisted.count == report.generatedRecordCount)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TaskMemoryLegacyImporterTests
```

Expected: FAIL because importer and report types do not exist.

**Step 3: Write minimal implementation**

实现：

- `TaskMemoryMigrationReport`：记录 `sessionID`、`generatedRecordCount`、`succeeded`、`failureReason`
- `TaskMemoryLegacyImporter.importMemory(_:)`：把 legacy `TaskMemory` 内容转成 records 并写入 unified store
- 可选再补 `importAll(from directoryURL:)`，用于批量扫描 `~/.agentgui/task-memories/`

说明：

- 此时 `TaskMemory.swift` 仍可保留，只作为 legacy import DTO
- 给文件头注释加上明确标识：legacy import only，不再作为主持久化模型

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/TaskMemoryLegacyImporter.swift agentGui/Models/TaskMemoryMigrationReport.swift agentGui/Models/TaskMemory.swift agentGuiTests/TaskMemoryLegacyImporterTests.swift
git commit -m "feat: add legacy task memory importer"
```

### Task 7: Remove Legacy TaskMemory Main-Path Code

**Files:**
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryService.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryStoreAdapter.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryStoreAdapterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`

**Step 1: Write the failing test**

在删除前先跑受影响的回归测试，确认主链路已经不依赖 legacy 类。

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TaskMemoryRecordFactoryTests \
  -only-testing:agentGuiTests/TaskMemoryPromptRendererTests \
  -only-testing:agentGuiTests/TaskMemoryUnifiedWritePathTests \
  -only-testing:agentGuiTests/TaskMemoryLegacyImporterTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests
```

Expected: PASS before deleting the old files.

**Step 2: Delete legacy implementation**

删除：

- `TaskMemoryService.swift`
- `TaskMemoryStoreAdapter.swift`
- `TaskMemoryStoreAdapterTests.swift`

同时清理所有 import / call site 残留，尤其是：

- `ClaudeService+ContextCompression.swift`
- `ClaudeService+AgenticLoop.swift`
- `MemoryRuntimeCoordinator.swift`

**Step 3: Run targeted suite again**

Run the same `xcodebuild` command.

Expected: PASS with no references to `TaskMemoryService` or `TaskMemoryStoreAdapter`.

**Step 4: Commit**

```bash
git add -A
git commit -m "refactor: remove legacy task memory service and adapter"
```

### Task 8: Update Docs And Architecture References

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-10-agent-architecture.md`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-11-taskmemory-direct-unified-memory-requirements.md`

**Step 1: Update README**

把这段表述改掉：

- `TaskMemory/StoryMemory 读侧 adapter`
- `TaskMemoryService ... 仍保留原有持久化实现`

替换为：

- TaskMemory 已直接并入 unified store
- StoryMemory 仍为 adapter-based

**Step 2: Update technical architecture doc**

调整 architecture 图和文字说明：

- 移除 `TaskMemoryStoreAdapter` 作为主链路节点
- 标明 session task memory 由 `UnifiedMemoryFileStoreAdapter` 直接承载
- 保留 legacy importer 仅作迁移工具的说明

**Step 3: Verify docs by search**

Run:

```bash
rg -n "TaskMemoryStoreAdapter|TaskMemoryService|adapter-based" README.md docs
```

Expected: 只剩 migration/import 语义，不再出现它们是主链路的描述。

**Step 4: Commit**

```bash
git add README.md docs/technical-spec/2026-03-10-agent-architecture.md
git commit -m "docs: update task memory architecture after unified cutover"
```

### Task 9: Run Final Verification Suite

**Files:**
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryRecordFactoryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryPromptRendererTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryUnifiedWritePathTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryLegacyImporterTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedMemoryStoreContractTests.swift`

**Step 1: Run focused final suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TaskMemoryRecordFactoryTests \
  -only-testing:agentGuiTests/TaskMemoryPromptRendererTests \
  -only-testing:agentGuiTests/TaskMemoryUnifiedWritePathTests \
  -only-testing:agentGuiTests/TaskMemoryLegacyImporterTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/UnifiedMemoryStoreContractTests
```

Expected: PASS.

**Step 2: Run repository-wide grep sanity check**

Run:

```bash
rg -n "TaskMemoryService|TaskMemoryStoreAdapter" agentGui agentGuiTests README.md docs
```

Expected: 没有主链路引用；如果仍有结果，只允许出现在 migration/import 文档或历史说明中。

**Step 3: Commit verification sweep**

```bash
git add -A
git commit -m "test: verify task memory direct unified migration"
```

## Rollout Notes

- 如果你担心一次性切掉 fallback 风险过高，可以在 Task 6 和 Task 7 之间短暂停留一个提交周期，只保留 legacy importer，不保留 legacy 主读写。
- 不建议引入长期 feature flag。这个改造的目标是消除双轨，不是把双轨产品化。
- 如果在 Task 5 前发现 `MemoryKind` 不足以表达 verification-entry，可先继续用 `.working + tags`，不要为了本轮目标额外扩大 schema 重构范围。

## Done Criteria

- 新的任务记忆数据全部通过 unified store 写入和读取。
- `ClaudeService+ContextCompression`、`ClaudeService+AgenticLoop`、`MemoryRuntimeCoordinator` 都不再依赖 `TaskMemoryService`。
- 历史 `TaskMemory` JSON 可以通过 importer 导入 unified store，并产出迁移报告。
- `TaskMemoryService`、`TaskMemoryStoreAdapter`、`TaskMemoryStoreAdapterTests` 已删除。
- README 与技术架构文档已经更新，不再把 TaskMemory 描述为 adapter-based 主链路。

Plan complete and saved to `docs/plans/2026-03-11-taskmemory-direct-unified-memory-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?