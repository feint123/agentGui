# BlockDocumentEditor Undo/Redo Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 BlockDocumentEditor 落地一套统一、模块化、可扩展的 Undo/Redo 机制，覆盖块级结构编辑、文本输入、行内格式、slash 命令，以及与 FileEditor 保存/重载边界的正确联动。

**Architecture:** 以 BlockDocumentEditor 自有历史为唯一真相，先落纯状态机的快照历史控制器，再引入 mutation driver 把所有结构操作统一事务化，随后接入文本输入合并与宿主 clean anchor / external reload 边界，最后做平台快捷键与可选 UndoManager 桥接。第一阶段坚持快照式历史以保证正确性和可测试性，不直接上命令反演或持久化历史。

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, AppKit, Foundation, 现有 BlockDocumentEditor / BlockTextEditor / FileEditorSessionController / BlockMarkdownCodec。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. 设计约束

- 严格 TDD。任何生产代码之前必须先有失败测试。
- `BlockDocumentEditor` 必须成为唯一撤销真相来源，不能保留 `NSTextView` 私有 undo 作为并行历史源。
- 所有可编辑行为必须先归一到事务层，再进入历史栈，不允许继续散落式直接改写 `document.blocks`。
- 第一阶段优先快照正确性，不引入复杂 diff 存储或历史持久化。
- Undo/Redo 不只回滚 `BlockDocument`，还要恢复必要的编辑上下文：当前块、焦点、光标/选区。
- 文件保存成功后不清空历史，只标记 clean anchor；外部 reload / 切换文件必须重置历史。

## 1. 代码锚点

以下文件是本计划的主要落点：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockMarkdownCodec.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/FileEditorSessionController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-17-block-document-editor-undo-redo-design.md`

## 2. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorUndoModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorHistoryController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorMutationDriver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorTextEditSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorHistoryControllerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorMutationDriverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorUndoTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorUndoIntegrationTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/FileEditorSessionController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorLoadedTextStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorExternalConflictCoordinatorTests.swift`

## 3. 交付策略

按 6 个里程碑垂直切入：

1. 纯历史模型与状态机。
2. 事务驱动层与运行时快照。
3. 结构操作接入 Undo/Redo。
4. 文本输入会话合并与键盘命令接入。
5. FileEditor clean anchor / reload / conflict 边界。
6. 平台桥接与回归补强。

不要一开始就在 `BlockDocumentEditor` 里零散塞 `history.record(...)`。先让纯状态机和 mutation driver 变绿，再迁移调用点。

## 4. 任务拆解

### Task 1: 新增 Undo 快照与历史控制器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorUndoModels.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorHistoryController.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorHistoryControllerTests.swift`

**Step 1: Write the failing test**

新增纯状态机测试，锁定以下行为：

- `record` 后 `past` 增长且 `future` 清空
- `undo` 返回前一快照并把 entry 推入 `future`
- `redo` 返回后一快照并把 entry 推回 `past`
- 新 entry 写入时，如果 merge policy 可合并，则覆写最后一条 entry 的 `after`
- `markClean` 后可以判断当前历史位置是否 clean

示例：

```swift
@Test func undoReturnsEntryBeforeSnapshotAndMovesEntryToFuture() {
    var history = BlockEditorHistoryController()
    let before = BlockEditorUndoSnapshot.fixture(text: "hello")
    let after = BlockEditorUndoSnapshot.fixture(text: "hello world")
    history.record(.fixture(before: before, after: after, kind: .blockStructure))

    let restored = history.undo(current: after)

    #expect(restored == before)
    #expect(history.past.isEmpty)
    #expect(history.future.count == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockEditorHistoryControllerTests
```

Expected: FAIL because undo snapshot / history controller types do not exist.

**Step 3: Write minimal implementation**

实现最小版本：

- `BlockEditorUndoSnapshot`
- `BlockEditorPresentationSnapshot`
- `BlockEditorHistoryEntry`
- `BlockEditorHistoryController`
- 简单 `fixture` helper（仅测试内可见）

先不要接入 SwiftUI 或 `BlockDocumentEditor`。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorUndoModels.swift agentGui/Views/Editor/BlockEditorHistoryController.swift agentGuiTests/BlockEditorHistoryControllerTests.swift
git commit -m "feat: add block editor undo history core"
```

### Task 2: 新增 mutation driver 与运行时快照恢复层

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorMutationDriver.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorUndoModels.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorMutationDriverTests.swift`

**Step 1: Write the failing test**

新增纯事务层测试，锁定以下行为：

- `applyMutation` 在闭包前后抓取快照并生成 entry
- 如果 mutation 没有造成状态变化，则不入栈
- `applyMutation` 会清空 `future`
- `applyMutation` 会返回应用后的 runtime state

示例：

```swift
@Test func mutationDriverRecordsBeforeAndAfterSnapshots() {
    var runtime = BlockEditorRuntimeState.fixture(text: "hello")
    var history = BlockEditorHistoryController()
    var driver = BlockEditorMutationDriver(history: history)

    driver.applyMutation(kind: .blockStructure, title: "Delete Block", editor: &runtime) {
        runtime.document.blocks.removeAll()
        runtime.document.blocks = [.empty(.paragraph)]
    }

    #expect(driver.history.past.count == 1)
    #expect(driver.history.past.last?.before.document.blocks.first?.text == "hello")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockEditorMutationDriverTests
```

Expected: FAIL because runtime state / mutation driver do not exist.

**Step 3: Write minimal implementation**

实现：

- `BlockEditorRuntimeState`
- `BlockEditorMutationDriver`
- `snapshot()` / `apply(snapshot:)` 纯接口

此时仍然不要迁移 `BlockDocumentEditor` 现有调用点。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorUndoModels.swift agentGui/Views/Editor/BlockEditorMutationDriver.swift agentGuiTests/BlockEditorMutationDriverTests.swift
git commit -m "feat: add block editor mutation driver"
```

### Task 3: 让结构操作进入统一 Undo/Redo 事务链路

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorModels.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorUndoTests.swift`

**Step 1: Write the failing test**

新增编辑器级测试，锁定以下结构操作都可 undo/redo：

- `convertBlock`
- `splitBlock`
- `mergeBlockBackward`
- `deleteBlock`
- `adjustIndentation`
- `clearFormatting`
- `createTablePreset`

示例：

```swift
@Test func deleteBlockCanUndoAndRestorePreviousDocumentShape() {
    let harness = BlockDocumentEditorUndoHarness(text: "hello\n\nworld")

    harness.deleteBlock(at: 1)
    #expect(harness.blockCount == 1)

    harness.undo()
    #expect(harness.blockCount == 2)

    harness.redo()
    #expect(harness.blockCount == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockDocumentEditorUndoTests
```

Expected: FAIL because BlockDocumentEditor has no editor-owned undo runtime or undo/redo commands.

**Step 3: Write minimal implementation**

在 `BlockDocumentEditor` 中引入：

- `historyController`
- `mutationDriver`
- `undo()` / `redo()`
- `applyStructuralEdit(...)`
- `applyHistorySnapshot(...)`

并把上述结构操作逐步改走统一事务入口。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockDocumentEditor.swift agentGui/Views/Editor/BlockEditorModels.swift agentGuiTests/BlockDocumentEditorUndoTests.swift
git commit -m "feat: route structural block edits through undo history"
```

### Task 4: 接入文本输入合并与键盘 Undo/Redo 命令

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorTextEditSession.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorUndoTests.swift`

**Step 1: Write the failing test**

扩展编辑器级测试，锁定以下行为：

- 同一块连续输入字符只生成一条历史记录
- 跨块切换或结构操作会结束当前 text edit session
- `Command+Z` 撤销最近文本输入
- `Shift+Command+Z` 重做最近文本输入

示例：

```swift
@Test func continuousTypingCoalescesIntoSingleUndoStep() {
    let harness = BlockDocumentEditorUndoHarness(text: "")

    harness.typeText("h")
    harness.typeText("e")
    harness.typeText("l")
    harness.typeText("l")
    harness.typeText("o")

    #expect(harness.undoStepCount == 1)
    harness.undo()
    #expect(harness.currentText == "")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockDocumentEditorUndoTests
```

Expected: FAIL because text input still relies on `NSTextView` private undo and has no coalescing session.

**Step 3: Write minimal implementation**

实现：

- `BlockEditorTextEditSession`
- 在 `BlockDocumentEditor` 中维护 typing session 生命周期
- 在 `BlockTextEditor` 关闭 `allowsUndo`，新增 `.undo` / `.redo` 命令路由
- 在合适边界 flush typing session：失焦、块切换、结构编辑、保存前、reload 前

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorTextEditSession.swift agentGui/Views/Editor/BlockTextEditor.swift agentGui/Views/Editor/BlockDocumentEditor.swift agentGuiTests/BlockDocumentEditorUndoTests.swift
git commit -m "feat: add coalesced text input undo sessions"
```

### Task 5: 接入 FileEditor clean anchor、保存与外部 reload 边界

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/FileEditorSessionController.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorUndoIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorLoadedTextStateTests.swift`

**Step 1: Write the failing test**

新增宿主集成测试，锁定以下行为：

- 保存成功后标记 clean anchor，而不是清空历史
- undo 到保存前状态时 `hasUnsavedChanges == true`
- redo 回到 clean anchor 时 `hasUnsavedChanges == false`
- 打开新文件或 reload 磁盘版本会重置历史

示例：

```swift
@Test func saveMarksCleanAnchorWithoutClearingUndoHistory() async throws {
    let harness = try await FileEditorUndoHarness.openTextFile("hello")
    harness.typeText(" world")
    try await harness.save()

    #expect(harness.hasUndoHistory == true)
    #expect(harness.hasUnsavedChanges == false)

    harness.undo()
    #expect(harness.hasUnsavedChanges == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileEditorUndoIntegrationTests
```

Expected: FAIL because FileEditor currently does not know editor clean anchor / history reset semantics.

**Step 3: Write minimal implementation**

实现：

- `BlockDocumentEditor` 对外暴露 clean-state / history reset hooks（用最小接口，不直接泄露内部结构）
- `FileEditorView` 在保存成功、打开文件、reload 后正确调用这些 hooks
- `FileEditorSessionController` 保持文本真相和 dirty 计算不变，只消费 editor 写回结果

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/FileEditorView.swift agentGui/Utilities/FileEditorSessionController.swift agentGui/Views/Editor/BlockDocumentEditor.swift agentGuiTests/FileEditorUndoIntegrationTests.swift agentGuiTests/FileEditorLoadedTextStateTests.swift
git commit -m "feat: integrate block editor undo with file editor lifecycle"
```

### Task 6: 做平台快捷键与可选 UndoManager 桥接补强

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorUndoTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorUndoIntegrationTests.swift`

**Step 1: Write the failing test**

补最后一批行为测试，锁定：

- `Command+Z` / `Shift+Command+Z` 会被当前活动 block editor 消费
- 非文本 viewer 不误消费 Undo/Redo
- 若接入 `UndoManager` 桥接，菜单 title / 可用态至少不与自定义历史冲突

示例：

```swift
@Test func commandZRoutesToEditorOwnedUndoInsteadOfNSTextViewUndo() {
    let harness = BlockDocumentEditorUndoHarness(text: "hello")
    harness.typeText(" world")

    let handled = harness.sendKeyCommand(.undo)

    #expect(handled == true)
    #expect(harness.currentText == "hello")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockDocumentEditorUndoTests \
  -only-testing:agentGuiTests/FileEditorUndoIntegrationTests
```

Expected: FAIL because command routing or bridge behavior is still incomplete.

**Step 3: Write minimal implementation**

补齐：

- `BlockTextEditor.keyDown` 中对 `Command+Z` / `Shift+Command+Z` 的统一路由
- 如有必要，增加一个轻量 `BlockEditorUndoBridge`
- 确保不会重新启用 `NSTextView` 自有 undo 链路

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockTextEditor.swift agentGui/Views/FileEditorView.swift agentGui/Views/Editor/BlockDocumentEditor.swift agentGuiTests/BlockDocumentEditorUndoTests.swift agentGuiTests/FileEditorUndoIntegrationTests.swift
git commit -m "feat: finalize block editor undo command routing"
```

## 5. 最终回归清单

完成全部任务后，至少跑以下测试：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockEditorHistoryControllerTests \
  -only-testing:agentGuiTests/BlockEditorMutationDriverTests \
  -only-testing:agentGuiTests/BlockDocumentEditorUndoTests \
  -only-testing:agentGuiTests/FileEditorUndoIntegrationTests
```

如果宿主文件编辑相关行为改动较大，再补跑：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileEditorLoadedTextStateTests \
  -only-testing:agentGuiTests/FileEditorExternalConflictCoordinatorTests
```

## 6. 实施备注

- 优先让纯状态机和 mutation driver 变绿，再做 UI 接入。
- 在 Task 3 之前，不要提前改 `BlockTextEditor` 的 `allowsUndo`，否则会在结构 undo 还没就绪时破坏现有输入体验。
- `BlockDocumentEditorUndoTests` 如需复杂交互，应优先通过 harness 或抽出的 runtime state 测，而不是直接堆 UI 层快照测试。
- `FileEditorSessionController` 仍然是文件加载/保存真相，不要把 editor 历史上移到 controller。

## 7. 完成定义

满足以下条件才算完成：

- 结构编辑与文本编辑共享同一套历史真相。
- `Command+Z` / `Shift+Command+Z` 在 block editor 中稳定工作。
- 连续输入字符会合并为合理撤销步。
- 保存成功后历史仍保留，但 clean anchor 正确。
- 文件切换与外部 reload 不会把旧历史带入新文档基线。
- 目标测试全部通过。