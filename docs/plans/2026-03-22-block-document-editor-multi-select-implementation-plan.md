# BlockDocumentEditor Multi-Select Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 BlockDocumentEditor 交付块级多选系统，支持拖拽框选、点击与范围扩选、块级上下文菜单、剪切复制导出，以及与 Undo/Redo 和快捷键一致联动。

**Architecture:** 以块级选区状态机作为唯一真相，先落纯模型与命令层，再把序列化、剪贴板、批量变更和菜单路由挂到统一命令入口，最后接入 SwiftUI/AppKit 交互表面。实现必须避免把逻辑继续堆进 BlockDocumentEditor 主文件，优先新增独立模块承载选区模型、命令路由、序列化器、框选叠层和菜单工厂。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Foundation、UniformTypeIdentifiers、Swift Testing、现有 BlockDocumentEditor / BlockRowView / BlockTextEditor / BlockMarkdownCodec / BlockEditorMutationDriver。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. 实施约束

- 严格 TDD。所有生产代码前必须先写失败测试。
- `InlineSelectionState` 与新的块级选区必须并列存在，不能互相覆盖为同一个字段。
- 命令必须经统一路由层进入，不允许右键菜单、快捷键、主菜单各自复制一套逻辑。
- 第一阶段优先正确性和可测试性，不做跨编辑器粘贴恢复、整组拖动重排或任意套索选择。
- 复制格式产出必须先通过纯序列化测试锁住，再接剪贴板写入。
- `BlockDocumentEditor.swift` 只做状态组装和事件转发，大部分新逻辑应新增到独立文件。

## 1. 代码锚点

本计划主要围绕以下文件展开：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockRowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorUndoModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorMutationDriver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockMarkdownCodec.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorUndoTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-22-block-document-editor-multi-select-requirements.md`

## 2. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorBlockSelectionModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorBlockSelectionCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionSerializer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionClipboardWriter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionCommandRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionMutationHandler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionKeyboardShortcuts.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionContextMenu.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionMarqueeOverlay.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorBlockSelectionCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorSelectionSerializerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorSelectionCommandRouterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorSelectionKeyboardShortcutTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorMultiSelectionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/BlockDocumentEditorMultiSelectionUITests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockRowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorUndoModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorMutationDriver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorUndoTests.swift`

## 3. 交付策略

按 7 个里程碑推进：

1. 纯块级选区状态机与命中计算。
2. 纯序列化与剪贴板负载定义。
3. 批量命令路由与 mutation handler。
4. 运行时快照扩展与 Undo/Redo 集成。
5. 编辑器表面接入点击选择、右键与快捷键。
6. 框选叠层与拖拽命中集成。
7. UI 回归与文档收尾。

不要先改 `BlockDocumentEditor` 再倒推模型。先让纯状态层和命令层变绿，再接交互表面。

## 4. 任务拆解

### Task 1: 新增块级选区模型与选择协调器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorBlockSelectionModels.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorBlockSelectionCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorModels.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorBlockSelectionCoordinatorTests.swift`

**Step 1: Write the failing test**

新增纯状态机测试，至少覆盖：

- 单击块时仅保留该块选择
- `Command` 切换时保留原集合并切换目标块
- `Shift` 点击按文档顺序建立连续范围
- 删除或重排后选区按 `blockID` 收敛与重映射
- 框选矩形命中时返回稳定有序块集合

示例：

```swift
@Test func shiftSelectionBuildsContiguousRangeFromAnchor() {
    let ids = [UUID(), UUID(), UUID(), UUID()]
    var state = BlockEditorBlockSelectionState.single(ids[1])
    state.anchorBlockID = ids[1]

    let result = BlockEditorBlockSelectionCoordinator.extendRange(
        state: state,
        orderedBlockIDs: ids,
        targetBlockID: ids[3]
    )

    #expect(result.selectedBlockIDs == Set([ids[1], ids[2], ids[3]]))
    #expect(result.primaryBlockID == ids[3])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockEditorBlockSelectionCoordinatorTests
```

Expected: FAIL，因为块级选区模型与协调器尚不存在。

**Step 3: Write minimal implementation**

实现最小版本：

- `BlockEditorBlockSelectionState`
- `BlockEditorBlockSelectionSource`
- `BlockEditorMarqueeSelection`
- `BlockEditorBlockSelectionCoordinator`
- 只提供纯数据变换接口，不接 SwiftUI 手势

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorBlockSelectionModels.swift agentGui/Views/Editor/BlockEditorBlockSelectionCoordinator.swift agentGui/Views/Editor/BlockEditorModels.swift agentGuiTests/BlockEditorBlockSelectionCoordinatorTests.swift
git commit -m "feat: add block editor block selection core"
```

### Task 2: 新增多格式序列化器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionSerializer.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorSelectionSerializerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockMarkdownCodec.swift`

**Step 1: Write the failing test**

新增纯序列化测试，锁定以下行为：

- 多块导出 Markdown 时保留文档顺序与块间空行语义
- 纯文本导出对标题、列表、待办、引用、代码块、资源块做可读降级
- HTML 导出输出结构化片段，而不是整页 HTML
- 空选择返回空负载，不输出垃圾占位符

示例：

```swift
@Test func serializerBuildsMarkdownPlainTextAndHTMLForMixedBlocks() {
    let blocks = [
        DocumentBlock(kind: .heading1, text: "Title"),
        DocumentBlock(kind: .todo, text: "Ship it", metadata: .init(checked: true)),
        DocumentBlock(kind: .quote, text: "Quoted")
    ]

    let payload = BlockEditorSelectionSerializer.serialize(blocks: blocks, fileURL: nil)

    #expect(payload.markdown.contains("# Title"))
    #expect(payload.plainText.contains("[x] Ship it"))
    #expect(payload.html.contains("<h1>Title</h1>"))
    #expect(payload.html.contains("<blockquote>"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockEditorSelectionSerializerTests
```

Expected: FAIL，因为块级多格式序列化器尚不存在。

**Step 3: Write minimal implementation**

实现：

- `BlockEditorSelectionSerializedPayload`
- `BlockEditorSelectionSerializer.serialize(blocks:fileURL:)`
- Markdown 复用 `BlockMarkdownCodec`
- 纯文本与 HTML 先覆盖需求文档列出的基础块类型

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorSelectionSerializer.swift agentGui/Views/Editor/BlockMarkdownCodec.swift agentGuiTests/BlockEditorSelectionSerializerTests.swift
git commit -m "feat: add block editor selection serializer"
```

### Task 3: 新增命令路由、剪贴板写入与批量变更处理层

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionClipboardWriter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionCommandRouter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionMutationHandler.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorSelectionCommandRouterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorMutationDriver.swift`

**Step 1: Write the failing test**

新增命令层测试，至少覆盖：

- `copy` 生成多格式负载并调用剪贴板 writer
- `copyAsMarkdown/plainText/html` 只写指定主格式
- `cut` 在复制成功后删除块；复制失败时不删除
- `duplicate` 复制当前选区并在原位置后插入
- `delete` 删除当前选区并返回收敛后的选择结果
- `selectAllBlocks` 与 `clearSelection` 不触碰文档内容

示例：

```swift
@Test func cutDoesNotMutateDocumentWhenClipboardWriteFails() {
    var runtime = BlockEditorRuntimeState.fixture(texts: ["A", "B"])
    let selection = BlockEditorBlockSelectionState.single(runtime.document.blocks[0].id)
    let writer = FailingClipboardWriter()
    var handler = BlockEditorSelectionMutationHandler(clipboardWriter: writer)

    let result = handler.cut(selection: selection, runtime: &runtime)

    #expect(result == .failure(.clipboardWriteFailed))
    #expect(runtime.document.blocks.map(\.text) == ["A", "B"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockEditorSelectionCommandRouterTests
```

Expected: FAIL，因为命令路由、剪贴板 writer 与批量变更处理器尚不存在。

**Step 3: Write minimal implementation**

实现：

- `BlockEditorSelectionCommand`
- `BlockEditorSelectionCommandRouter`
- `BlockEditorSelectionClipboardWriter` 协议 + AppKit 实现
- `BlockEditorSelectionMutationHandler`
- 删除、重复、剪切先基于 `BlockEditorRuntimeState` 和 `BlockEditorMutationDriver` 工作

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorSelectionClipboardWriter.swift agentGui/Views/Editor/BlockEditorSelectionCommandRouter.swift agentGui/Views/Editor/BlockEditorSelectionMutationHandler.swift agentGui/Views/Editor/BlockEditorMutationDriver.swift agentGuiTests/BlockEditorSelectionCommandRouterTests.swift
git commit -m "feat: add block editor selection command pipeline"
```

### Task 4: 扩展运行时快照，把块级选区纳入 Undo/Redo

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorUndoModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorMutationDriver.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorUndoTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorUndoTests.swift`

**Step 1: Write the failing test**

扩展现有 undo 测试，锁定以下行为：

- 删除多选块后 Undo/Redo 恢复正确文档与块级选区
- 重复选区后 Undo/Redo 恢复正确插入位置与主选中块
- 剪切作为单个事务进入历史栈，不拆成复制和删除两个 entry

示例：

```swift
@Test func deletingSelectedBlocksCanUndoAndRestoreBlockSelection() {
    let harness = BlockDocumentEditorSelectionUndoHarness(texts: ["A", "B", "C"])
    harness.select(idsAt: [0, 1], primary: 1)

    harness.deleteSelection()
    #expect(harness.texts == ["C"])

    harness.undo()
    #expect(harness.texts == ["A", "B", "C"])
    #expect(harness.selectedTexts == ["A", "B"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockDocumentEditorUndoTests
```

Expected: FAIL，因为 runtime snapshot 目前不保存块级选区。

**Step 3: Write minimal implementation**

实现：

- `BlockEditorBlockSelectionSnapshot`
- `BlockEditorPresentationSnapshot.blockSelection`
- `BlockEditorRuntimeState.blockSelection`
- `snapshot()` / `apply(snapshot:)` 同步块级选区

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorUndoModels.swift agentGui/Views/Editor/BlockEditorMutationDriver.swift agentGuiTests/BlockDocumentEditorUndoTests.swift
git commit -m "feat: persist block selection in editor undo snapshots"
```

### Task 5: 接入点击选择、右键菜单与键盘快捷键

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionKeyboardShortcuts.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionContextMenu.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockRowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockEditorSelectionKeyboardShortcutTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorMultiSelectionTests.swift`

**Step 1: Write the failing test**

新增编辑器集成测试，至少覆盖：

- 点击块外缘时进入单选
- `Command + 点击` 增减选区
- `Shift + 点击` 范围扩选
- 右键点击未选中块时先切换选区再弹菜单
- `Command + C`、`Command + X`、`Delete`、`Escape` 在块级选区激活时路由正确
- 内联文本选中激活后会清空块级多选

示例：

```swift
@Test func escapeClearsBlockSelectionWithoutMutatingDocument() {
    let harness = BlockDocumentEditorMultiSelectionHarness(texts: ["A", "B"])
    harness.clickSelectionHandle(at: 0)
    #expect(harness.selectedCount == 1)

    _ = BlockEditorSelectionKeyboardShortcuts.action(for: .escape, hasBlockSelection: true, textViewHasSelection: false)
    harness.clearSelection()

    #expect(harness.selectedCount == 0)
    #expect(harness.texts == ["A", "B"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockEditorSelectionKeyboardShortcutTests \
  -only-testing:agentGuiTests/BlockDocumentEditorMultiSelectionTests
```

Expected: FAIL，因为编辑器尚未暴露块级选择热区、菜单与快捷键路由。

**Step 3: Write minimal implementation**

实现要点：

- 给 `BlockRowView` 增加选择热区和右键触发入口
- `BlockDocumentEditor` 新增 `blockSelectionState`
- 右键菜单通过 `BlockEditorSelectionContextMenu` 构造
- `BlockTextEditor` 在块级选区激活时让 `Command+C/X/Delete/Escape` 可回流到命令路由，而不是永远被文本视图截断

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorSelectionKeyboardShortcuts.swift agentGui/Views/Editor/BlockEditorSelectionContextMenu.swift agentGui/Views/Editor/BlockRowView.swift agentGui/Views/Editor/BlockDocumentEditor.swift agentGui/Views/Editor/BlockTextEditor.swift agentGuiTests/BlockEditorSelectionKeyboardShortcutTests.swift agentGuiTests/BlockDocumentEditorMultiSelectionTests.swift
git commit -m "feat: add block selection click menu and keyboard routing"
```

### Task 6: 接入拖拽框选叠层与命中更新

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorSelectionMarqueeOverlay.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockRowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorMultiSelectionTests.swift`

**Step 1: Write the failing test**

扩展集成测试，锁定以下行为：

- 从选择带或留白区域拖拽可建立多选
- 从文本编辑正文区域拖拽不会进入块级框选
- `Command + 拖拽框选` 在现有集合上做并集
- 框选结束后主选中块稳定，临时命中态被清理

示例：

```swift
@Test func marqueeSelectionUnionsWithExistingSelectionWhenCommandModifierIsActive() {
    let harness = BlockDocumentEditorMultiSelectionHarness(texts: ["A", "B", "C", "D"])
    harness.clickSelectionHandle(at: 0)

    harness.marqueeSelect(indices: [2, 3], additive: true)

    #expect(harness.selectedTexts == ["A", "C", "D"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockDocumentEditorMultiSelectionTests
```

Expected: FAIL，因为框选叠层与块矩形命中还未接入编辑器。

**Step 3: Write minimal implementation**

实现要点：

- `BlockEditorSelectionMarqueeOverlay` 只负责框选矩形与拖拽状态
- `BlockRowView` 暴露容器矩形测量与选择热区，不侵入文本编辑区域
- `BlockDocumentEditor` 维护块 frame 映射，并把命中判断委托给 `BlockEditorBlockSelectionCoordinator`

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorSelectionMarqueeOverlay.swift agentGui/Views/Editor/BlockRowView.swift agentGui/Views/Editor/BlockDocumentEditor.swift agentGuiTests/BlockDocumentEditorMultiSelectionTests.swift
git commit -m "feat: add block editor marquee multi-selection"
```

### Task 7: 补齐 UI 回归与集成验证

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/BlockDocumentEditorMultiSelectionUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockDocumentEditorUndoTests.swift`

**Step 1: Write the failing test**

新增 UI 或端到端回归，至少覆盖：

- 拖拽框选 2 个以上块
- 右键菜单出现“复制为 Markdown / 纯文本 / HTML”
- 多选删除后 Undo 能恢复
- 文本选区与块级多选不会同时呈现

示例 UI 断言：

```swift
func testContextMenuShowsCopyVariantsForMultipleBlocks() {
    let app = XCUIApplication()
    app.launch()

    // 打开带多个块的测试文档，执行多选
    // 右键后断言菜单项存在
    XCTAssertTrue(app.menuItems["复制为 Markdown"].exists)
    XCTAssertTrue(app.menuItems["复制为纯文本"].exists)
    XCTAssertTrue(app.menuItems["复制为 HTML"].exists)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiUITests/BlockDocumentEditorMultiSelectionUITests
```

Expected: FAIL，因为 UI 标识与多选交互还未完整接通。

**Step 3: Write minimal implementation**

补齐：

- 关键选择热区和菜单的 accessibility identifier
- UI 测试数据入口
- 若 UI 测试受本地签名环境影响，至少保证目标编译通过，并在 Xcode 本地手跑验证一次

**Step 4: Run test to verify it passes**

先运行 focused 单测和集成测试：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockEditorBlockSelectionCoordinatorTests \
  -only-testing:agentGuiTests/BlockEditorSelectionSerializerTests \
  -only-testing:agentGuiTests/BlockEditorSelectionCommandRouterTests \
  -only-testing:agentGuiTests/BlockEditorSelectionKeyboardShortcutTests \
  -only-testing:agentGuiTests/BlockDocumentEditorMultiSelectionTests \
  -only-testing:agentGuiTests/BlockDocumentEditorUndoTests
```

再在环境允许时运行 UI 测试命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGuiUITests/BlockDocumentEditorMultiSelectionUITests.swift agentGuiTests/BlockDocumentEditorUndoTests.swift
git commit -m "test: add block editor multi-selection regression coverage"
```

## 5. 质量门槛

- 块级选区、内联文本选区、光标态三者必须互斥。
- 所有块级命令必须走统一命令路由。
- 复制、剪切、删除、重复必须进入 Undo/Redo 历史。
- 框选不得劫持 `NSTextView` 正文区域的原生文本选中。
- 菜单可用性必须由当前选区与命令能力决定，不能全部常亮。
- 不允许把 Markdown、纯文本、HTML 导出逻辑直接散落在 SwiftUI menu callback 中。

## 6. 验证命令补充

如果本地 `xcodebuild test` 受 UI 签名问题阻塞，补充执行：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build-for-testing CODE_SIGNING_ALLOWED=NO
```

这只能验证编译健康，不能替代真实 UI 交互验证。

## 7. 收尾要求

- 实现完成后，更新 `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-22-block-document-editor-multi-select-requirements.md` 的状态标记或关联说明。
- 若 `BlockDocumentEditor.swift` 在实施后继续膨胀，单独开后续计划，把块级选择扩展拆到 extension 文件，但不要在本次主线中途做无关大拆分。
- 完成前至少执行一次 focused 单测全绿，一次编辑器手工冒烟，确认点击选择、右键菜单、框选、Undo/Redo 四条主链路闭环。