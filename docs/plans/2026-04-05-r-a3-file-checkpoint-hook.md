# R-A3 FileCheckpointHook Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 `ToolExecutionHookPipeline` 的 `preExecute` 阶段注入文件检查点钩子，在文件写入工具执行之前备份原始内容，并将备份条目积累到 `ActiveCheckpointAccumulator` 供 R-B1 (`ConversationCheckpointService`) 消费。

**Architecture:**
- `ActiveCheckpointAccumulator`（actor）：单次 agent loop 轮次的文件备份条目缓冲区，在 `ClaudeService` 中以 sessionID 为键存储，每轮 loop 被替换一次。
- `FileCheckpointHook`（struct: ToolExecutionHook）：实现 `preExecute`，对文件写入工具（`str_replace_based_edit_tool`、`str_replace_editor`）的写操作命令（`str_replace` / `create` / `write` / `insert`）调用 `FileBackupStore.createBackup`，幂等记录到当前轮次的 `ActiveCheckpointAccumulator`。
- 注册点：`AgentLoopToolExecutionCoordinatorBuilder.buildHookPipeline()`，优先级高于 `ChangeReviewHook`（先 preExecute 备份，后 postExecute 投影）。

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`), `FileBackupStore`（R-A2，已实现），`ToolExecutionHookPipeline`（已实现），`AgentLoopToolExecutionCoordinatorBuilder`（已实现）

---

## 依赖前置确认

在执行任意任务前运行以下命令，确认 `FileBackupStore` 编译通过：

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

期待输出：`BUILD SUCCEEDED`（或仅有警告）

---

## 参考文件速查

| 文件 | 用途 |
|------|------|
| `agentGui/Services/Rewind/FileBackupStore.swift` | R-A2 实现，hook 的核心依赖 |
| `agentGui/Models/ConversationCheckpoint.swift` | `FileBackupEntry` 类型定义 |
| `agentGui/Services/ToolGovernance/ToolExecutionHookPipeline.swift` | `ToolExecutionHook` 协议、`ToolCallPreview` 类型 |
| `agentGui/Services/ToolGovernance/Hooks/ChangeReviewHook.swift` | reference hook 实现（postExecute 模式） |
| `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift` | 注册点 `buildHookPipeline()` |
| `agentGui/Services/ClaudeService/ClaudeService.swift` | session 级状态，存储 `fileBackupStore` 的位置 |
| `agentGuiTests/ChangeReviewHookTests.swift` | hook 测试范式参考 |
| `agentGuiTests/FileBackupStoreTests.swift` | FileBackupStore 测试模式参考 |

---

## Task 1：定义 `ActiveCheckpointAccumulator` actor

**目标：** 提供一个并发安全的、单次 agent loop 轮次的条目缓冲区。

**Files:**
- Create: `agentGui/Services/Rewind/FileCheckpointHook.swift`
- Create: `agentGuiTests/FileCheckpointHookTests.swift`

---

### Step 1: 写失败测试（Task 1 - Accumulator 基础行为）

在 `agentGuiTests/FileCheckpointHookTests.swift` 中写：

```swift
// agentGuiTests/FileCheckpointHookTests.swift
import Foundation
import Testing
@testable import agentGui

@Suite("FileCheckpointHook Tests")
struct FileCheckpointHookTests {

    // MARK: - ActiveCheckpointAccumulator

    @Test
    func accumulator_record_storesEntry() async {
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: "/ws")
        let entry = FileBackupEntry(backupKey: "abc", version: 1, backupTime: Date(), originalRelativePath: "a.swift")

        await acc.record(relativePath: "a.swift", entry: entry)

        let entries = await acc.entries
        #expect(entries["a.swift"] != nil)
        #expect(entries["a.swift"]?.backupKey == "abc")
    }

    @Test
    func accumulator_record_idempotent_firstWriteWins() async {
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: "/ws")
        let e1 = FileBackupEntry(backupKey: "first", version: 1, backupTime: Date(), originalRelativePath: "a.swift")
        let e2 = FileBackupEntry(backupKey: "second", version: 2, backupTime: Date(), originalRelativePath: "a.swift")

        await acc.record(relativePath: "a.swift", entry: e1)
        await acc.record(relativePath: "a.swift", entry: e2)   // second call is no-op

        let entries = await acc.entries
        #expect(entries["a.swift"]?.backupKey == "first")
    }

    @Test
    func accumulator_snapshot_returnsAllEntries() async {
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: "/ws")
        let e1 = FileBackupEntry(backupKey: "k1", version: 1, backupTime: Date(), originalRelativePath: "a.swift")
        let e2 = FileBackupEntry(backupKey: "k2", version: 1, backupTime: Date(), originalRelativePath: "b.swift")

        await acc.record(relativePath: "a.swift", entry: e1)
        await acc.record(relativePath: "b.swift", entry: e2)

        let snap = await acc.snapshot()
        #expect(snap.count == 2)
        #expect(snap["a.swift"] != nil)
        #expect(snap["b.swift"] != nil)
    }

    @Test
    func accumulator_concurrentRecords_noDataRace() async {
        // 验证并发写入不丢条目（actor 隔离保证）
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: "/ws")

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let e = FileBackupEntry(
                        backupKey: "key\(i)",
                        version: 1,
                        backupTime: Date(),
                        originalRelativePath: "file\(i).swift"
                    )
                    await acc.record(relativePath: "file\(i).swift", entry: e)
                }
            }
        }

        let entries = await acc.entries
        #expect(entries.count == 20)
    }
}
```

### Step 2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a3-derived \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|PASSED|no such"
```

期望：编译错误（`ActiveCheckpointAccumulator` 未定义）

### Step 3: 实现 `ActiveCheckpointAccumulator`

创建 `agentGui/Services/Rewind/FileCheckpointHook.swift`，首先实现 accumulator：

```swift
// agentGui/Services/Rewind/FileCheckpointHook.swift
import Foundation

// MARK: - ActiveCheckpointAccumulator

/// 单次 agent loop 轮次内的文件备份条目缓冲区。
///
/// - 每次用户消息提交前由 `ConversationCheckpointService`（R-B1）创建并安装到
///   `ClaudeService.sessionCheckpointAccumulators[sessionID]`。
/// - `FileCheckpointHook.preExecute` 写入条目（idempotent：同一相对路径只记第一次）。
/// - R-B1 在 loop 结束后通过 `snapshot()` 读取全部条目，构建 `ConversationCheckpoint`。
actor ActiveCheckpointAccumulator: Sendable {
    /// key = 相对于 workspaceRoot 的文件路径。
    private(set) var entries: [String: FileBackupEntry] = [:]

    /// 触发此快照的用户消息 ID（由 ConversationCheckpointService 在构造时提供）。
    let messageID: UUID

    /// 快照时刻的工作目录（绝对路径）。
    let workspaceRoot: String

    init(messageID: UUID, workspaceRoot: String) {
        self.messageID = messageID
        self.workspaceRoot = workspaceRoot
    }

    /// 记录文件备份条目。同一 relativePath 的首次调用生效，后续调用幂等忽略。
    func record(relativePath: String, entry: FileBackupEntry) {
        guard entries[relativePath] == nil else { return }
        entries[relativePath] = entry
    }

    /// 返回当前所有条目的快照（不清空）。
    func snapshot() -> [String: FileBackupEntry] {
        entries
    }
}
```

> **注意：** `FileCheckpointHook` 结构体将在 Task 2 中继续添加到同一文件，暂时先加一个空的占位符以便编译：

```swift
// MARK: - FileCheckpointHook (stub — 在 Task 2 完成实现)

struct FileCheckpointHook: ToolExecutionHook, Sendable {
    let hookID = "file-checkpoint"

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision { .allow }
    func postExecute(record: ToolRunRecord) async -> PostExecuteAction { .passthrough }
    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction { .propagate }
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a3-derived \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test.*passed|Test.*failed|FAILED|PASSED"
```

期望：4 个测试全部 passed

### Step 5: Commit

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGui/Services/Rewind/FileCheckpointHook.swift \
        agentGuiTests/FileCheckpointHookTests.swift
git commit -m "feat(rewind/r-a3): add ActiveCheckpointAccumulator actor + test"
```

---

## Task 2：实现 `FileCheckpointHook` 的文件路径提取与 write 命令过滤

**目标：** 给 hook 加上两个核心 private helper：
1. `isWriteOperation(toolName:input:) -> Bool` — 判断是否是文件写入操作（排除 view/read/open）
2. `resolveTargetFilePath(input:) -> String?` — 从 input 中提取目标文件绝对路径

---

### Step 1: 写失败测试（路径提取 + 命令过滤 helpers）

在 `FileCheckpointHookTests.swift` 中追加：

```swift
    // MARK: - isWriteOperation

    @Test
    func isWriteOperation_strReplaceTool_writeCommands_returnsTrue() {
        let writeCommands = ["str_replace", "create", "write", "insert"]
        for cmd in writeCommands {
            let result = FileCheckpointHook.isWriteOperation(
                toolName: "str_replace_based_edit_tool",
                input: ["command": .string(cmd), "path": .string("/f.swift")]
            )
            #expect(result == true, "Expected true for command: \(cmd)")
        }
    }

    @Test
    func isWriteOperation_strReplaceTool_readCommands_returnsFalse() {
        let readCommands = ["view", "read", "open"]
        for cmd in readCommands {
            let result = FileCheckpointHook.isWriteOperation(
                toolName: "str_replace_based_edit_tool",
                input: ["command": .string(cmd), "path": .string("/f.swift")]
            )
            #expect(result == false, "Expected false for command: \(cmd)")
        }
    }

    @Test
    func isWriteOperation_otherTool_returnsFalse() {
        let result = FileCheckpointHook.isWriteOperation(
            toolName: "bash",
            input: ["command": .string("command"), "cmd": .string("echo hi")]
        )
        #expect(result == false)
    }

    @Test
    func resolveTargetFilePath_absolutePath_returnsAsIs() {
        let path = FileCheckpointHook.resolveTargetFilePath(
            input: ["path": .string("/workspace/src/main.swift")],
            workspaceRoot: "/workspace"
        )
        #expect(path == "/workspace/src/main.swift")
    }

    @Test
    func resolveTargetFilePath_relativePath_joinsWithWorkspaceRoot() {
        let path = FileCheckpointHook.resolveTargetFilePath(
            input: ["path": .string("src/main.swift")],
            workspaceRoot: "/workspace"
        )
        #expect(path == "/workspace/src/main.swift")
    }

    @Test
    func resolveTargetFilePath_missingPath_returnsNil() {
        let path = FileCheckpointHook.resolveTargetFilePath(
            input: ["command": .string("str_replace")],
            workspaceRoot: "/workspace"
        )
        #expect(path == nil)
    }
```

> **注意：** 这些测试调用 `FileCheckpointHook.isWriteOperation(toolName:input:)` 和 `FileCheckpointHook.resolveTargetFilePath(input:workspaceRoot:)` 作为 `static` 函数。

### Step 2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a3-derived \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test.*passed|Test.*failed"
```

期望：编译错误（`isWriteOperation` 和 `resolveTargetFilePath` 未定义）

### Step 3: 实现两个 helper

在 `FileCheckpointHook.swift` 中，将 `FileCheckpointHook` stub 替换为包含 helpers 的完整结构（`preExecute` 仍为 `.allow`）：

```swift
// MARK: - FileCheckpointHook

/// 文件检查点 preExecute 钩子：在文件写入工具执行之前备份原始内容。
///
/// 触发工具：`str_replace_based_edit_tool`、`str_replace_editor`
/// 触发命令（command 字段）：`str_replace`、`create`、`write`、`insert`
/// 不触发：`view`、`read`、`open`（只读操作）、其他工具名
///
/// 并发安全：hook 为 struct（不可变），所有共享状态通过 actor 访问。
struct FileCheckpointHook: ToolExecutionHook, Sendable {

    let hookID = "file-checkpoint"

    private let fileBackupStore: FileBackupStore
    private let accumulator: ActiveCheckpointAccumulator
    private let workspaceRoot: String

    init(
        fileBackupStore: FileBackupStore,
        accumulator: ActiveCheckpointAccumulator,
        workspaceRoot: String
    ) {
        self.fileBackupStore = fileBackupStore
        self.accumulator = accumulator
        self.workspaceRoot = workspaceRoot
    }

    // MARK: - ToolExecutionHook conformance

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        // 在 Task 3 中完成实际备份逻辑；此处仅桩
        return .allow
    }

    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        .passthrough
    }

    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        .propagate
    }

    // MARK: - Internal helpers（internal 可见性便于单元测试）

    /// 返回此次工具调用是否为文件写入操作（需要备份）。
    static func isWriteOperation(
        toolName: String,
        input: MessageResponse.Content.Input
    ) -> Bool {
        guard writeToolNames.contains(toolName) else { return false }
        let command = input["command"]?.stringValue ?? ""
        return writeCommands.contains(command)
    }

    /// 从工具 input 中提取目标文件的绝对路径。
    /// 若 path 为相对路径，以 workspaceRoot 为基础联接。
    static func resolveTargetFilePath(
        input: MessageResponse.Content.Input,
        workspaceRoot: String
    ) -> String? {
        guard let rawPath = input["path"]?.stringValue, !rawPath.isEmpty else {
            return nil
        }
        if rawPath.hasPrefix("/") {
            return rawPath
        }
        return (workspaceRoot as NSString).appendingPathComponent(rawPath)
    }

    // MARK: - Private constants

    private static let writeToolNames: Set<String> = [
        "str_replace_based_edit_tool",
        "str_replace_editor"
    ]

    private static let writeCommands: Set<String> = [
        "str_replace", "create", "write", "insert"
    ]
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a3-derived \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test.*passed|Test.*failed|FAILED|PASSED"
```

期望：之前 AccumulatorTests（4个）+ 新增 6个 helper tests = 全部 passed

### Step 5: Commit

```bash
git add agentGui/Services/Rewind/FileCheckpointHook.swift \
        agentGuiTests/FileCheckpointHookTests.swift
git commit -m "feat(rewind/r-a3): add isWriteOperation + resolveTargetFilePath helpers + tests"
```

---

## Task 3：实现 `FileCheckpointHook.preExecute` 的备份逻辑

**目标：** 完成 `preExecute`：提取目标路径 → 检查是否已追踪（幂等）→ 调用 `FileBackupStore.createBackup` → 写入 accumulator。备份失败时静默通过（不 block 工具执行）。

**已知：**
- `FileBackupStore.createBackup(filePath:sessionID:version:)` — 返回 `FileBackupEntry`（已测试）
- 同一 relativePath 的第二次 `accumulator.record` 幂等忽略（Task 1 保证）
- `preExecute` 必须 **总是返回 `.allow`**（备份失败不 block 工具）

---

### Step 1: 写失败测试（preExecute 集成）

在 `FileCheckpointHookTests.swift` 追加：

```swift
    // MARK: - preExecute integration

    /// 使用临时目录创建真实的 FileBackupStore，验证 preExecute 实际写入备份。
    private func makeTempStore() throws -> (FileBackupStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (FileBackupStore(baseURL: tmp.appendingPathComponent("checkpoints")), tmp)
    }

    @Test
    func preExecute_writeCommand_backupsFileAndRecordsEntry() async throws {
        let (store, tmp) = try makeTempStore()
        let wsRoot = tmp.path
        let targetFile = tmp.appendingPathComponent("src/main.swift")
        try FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "original content".write(to: targetFile, atomically: true, encoding: .utf8)

        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: wsRoot)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: wsRoot
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-1",
            toolName: "str_replace_based_edit_tool",
            input: [
                "command": .string("str_replace"),
                "path": .string(targetFile.path)
            ],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        let decision = await hook.preExecute(toolCall: preview)

        // 1. 总是 allow
        switch decision {
        case .allow: break
        default: Issue.record("Expected .allow, got \(decision)")
        }

        // 2. accumulator 中有条目
        let entries = await acc.entries
        #expect(entries.count == 1)

        // 3. 条目的 backupKey 非 nil（文件存在）
        let relativePath = "src/main.swift"
        let entry = try #require(entries[relativePath])
        #expect(entry.backupKey != nil)
    }

    @Test
    func preExecute_writeCommand_nonexistentFile_recordsNilBackupKey() async throws {
        let (store, tmp) = try makeTempStore()
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: tmp.path
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-2",
            toolName: "str_replace_based_edit_tool",
            input: [
                "command": .string("create"),
                "path": .string(tmp.appendingPathComponent("new.swift").path)
            ],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        let decision = await hook.preExecute(toolCall: preview)

        switch decision {
        case .allow: break
        default: Issue.record("Expected .allow")
        }

        let entries = await acc.entries
        #expect(entries.count == 1)
        // 文件不存在，backupKey 应为 nil
        let entry = try #require(entries["new.swift"])
        #expect(entry.backupKey == nil)
    }

    @Test
    func preExecute_sameFileTwice_idempotent_noDoubleBackup() async throws {
        let (store, tmp) = try makeTempStore()
        let targetFile = tmp.appendingPathComponent("dup.swift")
        try "v1".write(to: targetFile, atomically: true, encoding: .utf8)

        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: tmp.path
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-3",
            toolName: "str_replace_based_edit_tool",
            input: ["command": .string("str_replace"), "path": .string(targetFile.path)],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        // 假设工具调用了两次（不常见，但 hook 应幂等）
        _ = await hook.preExecute(toolCall: preview)
        try "v2 (modified)".write(to: targetFile, atomically: true, encoding: .utf8)
        _ = await hook.preExecute(toolCall: preview)

        let entries = await acc.entries
        // 只有 1 条条目（first-write-wins）
        #expect(entries.count == 1)
        // backupKey 对应 v1 内容
        let entry = try #require(entries["dup.swift"])
        #expect(entry.backupKey != nil)
    }

    @Test
    func preExecute_readCommand_skipped_noEntry() async throws {
        let (store, tmp) = try makeTempStore()
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: tmp.path
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-4",
            toolName: "str_replace_based_edit_tool",
            input: ["command": .string("view"), "path": .string("/tmp/some.swift")],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        _ = await hook.preExecute(toolCall: preview)

        let entries = await acc.entries
        #expect(entries.isEmpty)
    }

    @Test
    func preExecute_bashTool_skipped_noEntry() async throws {
        let (store, tmp) = try makeTempStore()
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: tmp.path
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-5",
            toolName: "bash",
            input: ["command": .string("echo hello")],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        _ = await hook.preExecute(toolCall: preview)

        let entries = await acc.entries
        #expect(entries.isEmpty)
    }
```

### Step 2: 运行确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a3-derived \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test.*passed|Test.*failed"
```

期望：`preExecute_writeCommand_backupsFileAndRecordsEntry` 等 preExecute 测试失败（entries 为空，因为 preExecute 桩只返回 `.allow`）

### Step 3: 实现 `preExecute` 完整逻辑

将 `FileCheckpointHook.preExecute` 替换为：

```swift
    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        // 1. 过滤：非写入操作则跳过
        guard Self.isWriteOperation(toolName: toolCall.toolName, input: toolCall.input) else {
            return .allow
        }

        // 2. 提取目标文件绝对路径
        guard let absolutePath = Self.resolveTargetFilePath(
            input: toolCall.input,
            workspaceRoot: workspaceRoot
        ) else {
            return .allow
        }

        // 3. 计算相对路径（accumulator key 和 FileBackupEntry.originalRelativePath）
        let relativePath: String
        if absolutePath.hasPrefix(workspaceRoot + "/") {
            relativePath = String(absolutePath.dropFirst(workspaceRoot.count + 1))
        } else {
            relativePath = absolutePath  // 路径在 workspaceRoot 外；使用绝对路径作 key
        }

        // 4. 幂等检查：若此 relativePath 已在 accumulator 中，无需重复备份
        let existingEntries = await accumulator.entries
        guard existingEntries[relativePath] == nil else {
            return .allow
        }

        // 5. 备份原始内容（修改前）；失败时静默通过，不 block 工具执行
        do {
            let entry = try await fileBackupStore.createBackup(
                filePath: absolutePath,
                sessionID: toolCall.sessionID,
                version: 1
            )
            let fullEntry = FileBackupEntry(
                backupKey: entry.backupKey,
                version: entry.version,
                backupTime: entry.backupTime,
                originalRelativePath: relativePath
            )
            await accumulator.record(relativePath: relativePath, entry: fullEntry)
        } catch {
            // 备份失败不阻止工具执行（容错）
        }

        return .allow
    }
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a3-derived \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test.*passed|Test.*failed|FAILED|PASSED"
```

期望：所有测试（10+ 个）全部 passed

### Step 5: Commit

```bash
git add agentGui/Services/Rewind/FileCheckpointHook.swift \
        agentGuiTests/FileCheckpointHookTests.swift
git commit -m "feat(rewind/r-a3): implement FileCheckpointHook.preExecute with backup + accumulator integration"
```

---

## Task 4：注册 hook + 向 `ClaudeService` 暴露当前 accumulator

**目标：**
1. 在 `ClaudeService` 上添加 `var sessionCheckpointAccumulators: [String: ActiveCheckpointAccumulator]` 字典（供 R-B1 消费）。
2. 在 `AgentLoopToolExecutionCoordinatorBuilder.buildHookPipeline()` 中每轮 loop 创建 fresh accumulator，注册 `FileCheckpointHook`，并存入 `claudeService.sessionCheckpointAccumulators[sessionId]`。

---

### 4a: 读取 `ClaudeService.swift` 中现有的 session 级状态区域

开始修改前先确认 `ClaudeService.swift` 中 `fileBackupStore` 所在行的完整上下文（搜索 `fileBackupStore`）：

```bash
grep -n "fileBackupStore\|sessionVerifications\|sessionExecutionEvidence" \
  agentGui/Services/ClaudeService/ClaudeService.swift
```

期望看到类似：
```
87:    var sessionVerifications: [String: CompletionVerification] = [:]
90:    var sessionExecutionEvidence: [String: Set<ExecutionEvidenceKind>] = [:]
108:    let fileBackupStore: FileBackupStore = FileBackupStore()
```

### 4b: 在 `ClaudeService.swift` 中添加 `sessionCheckpointAccumulators`

找到 `var sessionExecutionEvidence` 所在行，在其紧后面添加（用 replace_string_in_file 工具修改）：

```swift
    // R-A3: 当前 loop 轮次的文件检查点 accumulator（key = sessionID）
    // 每次 buildHookPipeline() 在 loop 开始前替换；由 R-B1 ConversationCheckpointService 消费。
    var sessionCheckpointAccumulators: [String: ActiveCheckpointAccumulator] = [:]
```

### 4c: 修改 `AgentLoopToolExecutionCoordinatorBuilder.buildHookPipeline()`

读取 `buildHookPipeline()` 函数现有实现：

```bash
grep -n "" agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift | \
  sed -n '239,260p'
```

当前实现（约 15 行）：
```swift
private func buildHookPipeline() -> ToolExecutionHookPipeline {
    var hooks: [any ToolExecutionHook] = []

    if let projectionStore = claudeService.changeReviewProjectionStore {
        hooks.append(ChangeReviewHook(projectionStore: projectionStore))
    }

    // F-C4: VerificationEvidenceHook ...
    let evidenceStore = claudeService.verificationEvidenceStore(for: sessionId)
    hooks.append(VerificationEvidenceHook(sessionID: sessionId, evidenceStore: evidenceStore))

    // F-C5: PayloadBudgetHook ...
    hooks.append(PayloadBudgetHook(payloadStore: claudeService.toolPayloadStore))

    return ToolExecutionHookPipeline(hooks: hooks)
}
```

使用 replace_string_in_file，将函数体替换为（在 ChangeReviewHook 之前插入 FileCheckpointHook）：

```swift
private func buildHookPipeline() -> ToolExecutionHookPipeline {
    var hooks: [any ToolExecutionHook] = []

    // R-A3: FileCheckpointHook — 必须在 ChangeReviewHook 之前（preExecute 备份原始内容）
    let workspaceRoot = session?.workingDirectory
        ?? (settings.workingDirectory.isEmpty ? nil : settings.workingDirectory)
        ?? FileManager.default.currentDirectoryPath
    let messageID = UUID()   // R-B1 makeSnapshot 会用真实 messageID 覆盖；此处仅作占位
    let acc = ActiveCheckpointAccumulator(messageID: messageID, workspaceRoot: workspaceRoot)
    claudeService.sessionCheckpointAccumulators[sessionId] = acc
    hooks.append(FileCheckpointHook(
        fileBackupStore: claudeService.fileBackupStore,
        accumulator: acc,
        workspaceRoot: workspaceRoot
    ))

    if let projectionStore = claudeService.changeReviewProjectionStore {
        hooks.append(ChangeReviewHook(projectionStore: projectionStore))
    }

    // F-C4: VerificationEvidenceHook — records bash test runs + nudges on todo completion
    let evidenceStore = claudeService.verificationEvidenceStore(for: sessionId)
    hooks.append(VerificationEvidenceHook(sessionID: sessionId, evidenceStore: evidenceStore))

    // F-C5: PayloadBudgetHook — persists oversized tool results to ToolPayloadStore
    hooks.append(PayloadBudgetHook(payloadStore: claudeService.toolPayloadStore))

    return ToolExecutionHookPipeline(hooks: hooks)
}
```

> **说明：** `messageID` 在此处用 `UUID()` 占位——R-B1 `ConversationCheckpointService.makeSnapshot` 调用时会传入真实的用户 Message.id，accumulator 上的 `messageID` 字段仅供 R-B1 用于调试关联；快照创建时 R-B1 用自身知道的 messageID，不依赖 accumulator 上的值。

> **注意：** `session?.workingDirectory` 中的 `Session.workingDirectory` 字段需要确认存在于模型中；如不存在则仅用 `settings.workingDirectory`。运行前检查：
> ```bash
> grep -n "workingDirectory" agentGui/Models/Session.swift | head -5
> ```

### 4d: 运行编译检查

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

期望：`BUILD SUCCEEDED`

### 4e: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService.swift \
        agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
git commit -m "feat(rewind/r-a3): register FileCheckpointHook in buildHookPipeline, expose accumulator on ClaudeService"
```

---

## Task 5：回归测试 + 最终烟雾测试

**目标：** 确认新 hook 不破坏现有 ChangeReviewHook、ToolExecutionHookPipeline 测试，且全部 R-A3 测试继续通过。

### Step 1: 运行 FileCheckpointHookTests

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a3-final-derived \
  -only-testing:agentGuiTests/FileCheckpointHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|FAILED|PASSED"
```

期望：全部 passed

### Step 2: 运行相关回归测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a3-final-derived \
  -only-testing:agentGuiTests/ChangeReviewHookTests \
  -only-testing:agentGuiTests/ToolExecutionHookPipelineTests \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|FAILED|PASSED"
```

期望：所有已有测试继续 passed

### Step 3: Final commit

如有任何修复：
```bash
git add -A
git commit -m "fix(rewind/r-a3): post-review cleanup"
```

---

## 实现完成核查清单

- [ ] `ActiveCheckpointAccumulator` actor 已定义（`messageID`、`workspaceRoot`、`record()`、`snapshot()`）
- [ ] `ActiveCheckpointAccumulator.record` 对同一 relativePath 的第二次调用幂等忽略
- [ ] `FileCheckpointHook` struct 实现 `ToolExecutionHook`，`hookID = "file-checkpoint"`
- [ ] `preExecute` 对非写入工具 / 非写入命令（view/read/open）返回 `.allow` 不做任何操作
- [ ] `preExecute` 在 FileBackupStore 调用失败时仍返回 `.allow`（不 block 工具）
- [ ] `preExecute` 用 `relativePath` 作 accumulator key（不含 workspaceRoot 前缀）
- [ ] `FileBackupEntry.originalRelativePath` 存储相对路径
- [ ] `ClaudeService.sessionCheckpointAccumulators` 字段存在
- [ ] hook 在 buildHookPipeline 中排在 `ChangeReviewHook` 之前
- [ ] 所有 FileCheckpointHookTests 通过，ChangeReviewHookTests 无回归

---

## 已知限制（Bash 工具暂缓）

bash 工具的文件追踪（写文件场景）**不在 R-A3 范围内**。Claude Code 的 BashTool.tsx 中 `fileHistoryTrackEdit` 是针对特定 `sed` 子命令调用的，通过 command postprocess 识别修改的文件路径。agentGui 的 bash 工具（`executeBashTool`）目前没有结构化的修改文件路径输出。bash 文件追踪需要单独的机制（postExecute + bash output 解析），作为后续任务。

---

## 参考：Claude Code 对应实现

| Claude Code | agentGui R-A3 |
|-------------|---------------|
| `fileHistoryTrackEdit(updateFileHistoryState, filePath, messageId)` in `FileEditTool.ts` line 435 | `FileCheckpointHook.preExecute(toolCall:)` |
| React state updater `updateFileHistoryState` | `ActiveCheckpointAccumulator.record(relativePath:entry:)` |
| `mostRecentSnapshot.trackedFileBackups[trackingPath]`（幂等检查） | `accumulator.entries[relativePath] == nil` 检查 |
| `createBackup(filePath, 1)` | `FileBackupStore.createBackup(filePath:sessionID:version:1)` |
| 调用位置：`fileHistoryEnabled() && parentMessage` 守卫 | `isWriteOperation(toolName:input:)` 守卫 |
