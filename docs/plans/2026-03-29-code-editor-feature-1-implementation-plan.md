# Code Editor Feature 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为文本文件建立独立的 CodeEditorView 主路径，使 FileEditorView 不再依赖 BlockDocumentEditor 承载源码编辑，同时保留现有的保存、焦点、选区、撤销与外部刷新能力。

**Architecture:** 第一阶段只建立“纯文本编辑壳”，不接入高亮、gutter 或新的 LSP 协调层。文件加载、保存、外部冲突与 dirty 判定仍由 FileEditorSessionController 负责；CodeEditorView 只负责原生 NSTextView 包装、编辑事件归一化、选区回传，以及把磁盘 reload / save clean anchor 正确映射到编辑器状态。

**Tech Stack:** Swift 6、SwiftUI、AppKit、TextKit、Foundation、Swift Testing、XCTest UI Testing、现有 FileEditorSessionController / WorkspaceState / ClaudeService。

## 当前执行状态（2026-03-29）

- Task 1 已完成：`EditorChangeSet`、`CodeEditorDocument` 与模型测试已落地。
- Task 2 已完成：原生 `CodeEditorTextView` 桥接层已落地；本轮补修了选区回传时序，非 UI 集成测试已通过。
- Task 3 已完成：`CodeEditorView` 外壳、reload / clean sync / focus 行为已落地并通过非 UI 集成测试。
- Task 4 已完成：`FileEditorView` 的文本分支已切到 `CodeEditorView`，相关 UI 测试文件也已存在。
- Task 5 部分完成：已完成非 UI 聚焦自动化验证；按当前执行要求，未运行 UI 测试，也未执行手工 smoke checklist。
- 最新非 UI 验证结果：`CodeEditorDocumentTests`、`CodeEditorTextViewIntegrationTests`、`CodeEditorViewIntegrationTests` 通过。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. 范围约束

- Feature 1 不改造 BlockDocumentEditor；它保留给 markdown / block 路径，文本文件改走新的 CodeEditorView。
- Feature 1 不引入 Highlightr、gutter、diagnostics、hover、definition，也不重写 LSP 同步策略。
- Feature 1 继续复用 FileEditorSessionController 作为文件真相来源：打开、保存、外部刷新、冲突提示、dirty 状态都不迁移到编辑器内部。
- Feature 1 的首要正确性是输入稳定性：IME、选区、撤销、first responder、外部 reload 后的文本一致性优先于任何新 UI。
- Feature 1 需要保留当前 FileEditorView 的测试镜像与保存按钮行为，避免破坏已有 UI 自动化入口。
- 这个 Xcode 工程使用 `PBXFileSystemSynchronizedRootGroup`；新文件只要放在 `agentGui`、`agentGuiTests`、`agentGuiUITests` 目录下，原则上不需要手改 `agentGui.xcodeproj/project.pbxproj`。

## 1. 代码锚点

当前实现的真实落点如下：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
  当前文本文件在 `fileContentView(for:)` 里直接走 `BlockDocumentEditor`，同时承担保存按钮、dirty 镜像、LSP bootstrap、`workspaceState.editorSelection` 回传。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/FileEditorSessionController.swift`
  管理 `textContent`、`persistedText`、`pendingConflict`、`save()`、外部刷新与 reload；这是 Feature 1 必须继续复用的文件状态层。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockDocumentEditor.swift`
  这是当前文本编辑路径，但它携带 block parsing、slash menu、table editor、marquee、markdown round-trip 等不属于源码编辑首轮范围的复杂度。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift`
  这里已经积累了一套 `NSViewRepresentable + NSTextViewDelegate + focus/selection callback` 组织方式，Feature 1 可以复用其桥接模式，但不要复用块级语义。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceFileContextFormatter.swift`
  这里定义了 `EditorSelectionSnapshot` 和 `FileLineRange`；新的代码编辑器应继续复用这个选区快照类型，避免上层调用点改动。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/BlockTableEditorSelectionUITests.swift`
  这提供了当前 UI 自动化风格参考：通过 launch arguments 选中文件，依赖稳定的 accessibility identifier 进行编辑器断言。

## 2. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/EditorChangeSet.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorDocumentTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/FileEditorCodeEditorUITests.swift`

### New test support files

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceFileContextFormatter.swift`（仅当需要为行号转换补一个轻量 helper；否则不改）

## 3. 交付策略

按以下顺序推进，避免一上来就把 FileEditorView 改到不可回退：

1. 先把编辑事件模型和文档状态模型独立出来，让 CodeEditor 不直接依赖 FileEditorSessionController 的全部细节。
2. 再做最小可工作的 `CodeEditorTextView`，只负责纯文本输入、选区回传、撤销、焦点与外部文本回写。
3. 然后加 `CodeEditorView` 外壳，把 clean anchor、reload、selection snapshot 这些 UI 级联动封装在新路径内部。
4. 最后切换 `FileEditorView` 文本分支，并用 unit test + UI test 双门禁锁住“真的走了新路径且功能没退化”。

不要把“切到新路径”和“新增高亮/LSP 协调器”混在同一个提交里。Feature 1 的成功标准是替换宿主路径，而不是把后续 Feature 提前做一半。

## 4. 设计决策

### 4.1 文本真相边界

- `FileEditorSessionController.document.textContent` 仍然是文件当前文本真相。
- `CodeEditorDocument` 是编辑器内部的轻量镜像，用来记录本地版本号、选区、最近一次 `EditorChangeSet`、是否处于外部回写流程。
- `CodeEditorDocument` 不负责磁盘 I/O，不直接保存文件。

### 4.2 编辑事件模型

新增 `EditorChangeSet`，先只覆盖 Feature 1 需要的信息：

- `version`
- `replacedRange: NSRange`
- `insertedText: String`
- `selectedRange: NSRange`
- `origin`，至少区分 `.userEdit` 与 `.externalReload`

第一阶段不引入复杂 diff，也不做 line/column index。行范围快照在需要时可以按当前全文临时计算。

### 4.3 外部刷新与 clean anchor

- 当 `persistedText` 因保存成功而与当前文本对齐时，CodeEditor 只需要把当前撤销栈保留，并把“当前文本等于 persistedText”的 clean 状态重新同步给宿主 UI。
- 当 `persistedText` 因外部 reload 变化，且 `textContent` 一起被 session controller 重置时，CodeEditor 应接受一次“程序性全文替换”，并避免把它重新当作用户编辑发回宿主。
- 当存在 `pendingConflict` 时，仍由 `FileEditorView` 展示冲突 banner；CodeEditor 不处理冲突决策。

### 4.4 选区回传

- 继续沿用 `EditorSelectionSnapshot`，这样 `WorkspaceState`、`ChatView`、`WorkspaceTreeViewModel` 无需改接口。
- Feature 1 只要求文本选区能稳定回传选中文字和行范围；暂不要求 token 级语义信息。

## 5. 任务拆解

### Task 1: 新增 EditorChangeSet 与 CodeEditorDocument

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/EditorChangeSet.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorDocumentTests.swift`

**Step 1: Write the failing test**

新增纯模型测试，锁定以下行为：

- 初始版本号从 `0` 开始
- `applyUserEdit` 会递增版本号并返回正确的 `EditorChangeSet`
- `replaceFromDisk` 会更新文本与 persisted text，但不会把来源标记成用户编辑
- `markSelection` 会更新选区，不污染文本版本

示例：

```swift
@Test func applyUserEditEmitsChangeSetAndBumpsVersion() {
    var document = CodeEditorDocument(text: "hello", persistedText: "hello")

    let change = document.applyUserEdit(
        replacing: NSRange(location: 5, length: 0),
        insertedText: " world",
        updatedText: "hello world",
        selectedRange: NSRange(location: 11, length: 0)
    )

    #expect(document.version == 1)
    #expect(document.text == "hello world")
    #expect(change.insertedText == " world")
    #expect(change.origin == .userEdit)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorDocumentTests
```

Expected: FAIL because `EditorChangeSet` and `CodeEditorDocument` do not exist.

**Step 3: Write minimal implementation**

实现最小版本：

```swift
enum EditorChangeOrigin: Equatable {
    case userEdit
    case externalReload
}

struct EditorChangeSet: Equatable {
    let version: Int
    let replacedRange: NSRange
    let insertedText: String
    let selectedRange: NSRange
    let origin: EditorChangeOrigin
}

struct CodeEditorDocument: Equatable {
    var text: String
    var persistedText: String
    var version: Int = 0
    var selectedRange: NSRange = NSRange(location: 0, length: 0)

    mutating func applyUserEdit(...) -> EditorChangeSet { ... }
    mutating func replaceFromDisk(...) -> EditorChangeSet { ... }
    mutating func markSelection(_ range: NSRange) { ... }
}
```

注意：这里不要提前塞入行索引、语言类型或高亮状态，保持 Feature 1 最小化。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/EditorChangeSet.swift agentGui/Models/CodeEditorDocument.swift agentGuiTests/CodeEditorDocumentTests.swift
git commit -m "feat: add code editor document model"
```

### Task 2: 新增原生 CodeEditorTextView 桥接层

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

**Step 1: Write the failing test**

新增 AppKit 桥接测试，锁定以下行为：

- 用户输入会更新绑定文本，并通过回调产出 `EditorChangeSet`
- 选区变化会回传 `EditorSelectionSnapshot`
- 程序性 `text` 更新不会再回触一次用户编辑回调
- 文本视图开启原生撤销，且 accessibility identifier 稳定为 `codeEditor.textView`

示例：

```swift
@MainActor
@Test func userEditUpdatesBindingAndEmitsChangeSet() throws {
    let harness = CodeEditorTextViewHarness(text: "hello")

    harness.replaceCharacters(in: NSRange(location: 5, length: 0), with: " world")

    #expect(harness.boundText == "hello world")
    #expect(harness.lastChangeSet?.replacedRange == NSRange(location: 5, length: 0))
    #expect(harness.lastChangeSet?.insertedText == " world")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests
```

Expected: FAIL because the new text view bridge and harness do not exist.

**Step 3: Write minimal implementation**

实现一个最小的 `NSViewRepresentable` 包装，不做样式野心，只做正确桥接：

```swift
struct CodeEditorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var document: CodeEditorDocument
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)?
    var onChangeSet: ((EditorChangeSet) -> Void)?

    func makeNSView(context: Context) -> NSScrollView { ... }
    func updateNSView(_ view: NSScrollView, context: Context) { ... }
}
```

实现要求：

- 使用原生 `NSTextView` / TextKit
- `allowsUndo = true`
- 用 coordinator 区分“用户编辑回调”和“程序性全文回写”
- 在 `textViewDidChangeSelection` 中把选中文字和行范围转成 `EditorSelectionSnapshot`
- 先不引入语法高亮属性回写

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "feat: add native code editor text view bridge"
```

### Task 3: 新增 CodeEditorView 外壳并处理 clean/reload 联动

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing test**

新增集成测试，锁定以下行为：

- 当 `persistedText` 与当前文本重新一致时，视图不会再次触发用户编辑回调
- 当宿主把文本从磁盘 reload 为新内容时，编辑器内容会切换到新文本
- 选区变化仍能通过闭包传回宿主
- 焦点请求可以把 `NSTextView` 设为 first responder

示例：

```swift
@MainActor
@Test func reloadFromDiskReplacesEditorContentWithoutEchoingUserChange() throws {
    let harness = CodeEditorViewHarness(initialText: "old", persistedText: "old")

    harness.updateFromHost(text: "fresh", persistedText: "fresh")

    #expect(harness.visibleText == "fresh")
    #expect(harness.changeSetCount == 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests
```

Expected: FAIL because `CodeEditorView` and its host harness do not exist.

**Step 3: Write minimal implementation**

实现：

- `CodeEditorView` 作为 SwiftUI 外壳，内部持有 `@State private var editorDocument`
- 对外只暴露最少接口：`text`、`persistedText`、`fileURL`、`onTextChange`、`onSelectionChange`
- 当 `text`/`persistedText` 由宿主变化时，判断是 save clean 还是 disk reload，并更新 `editorDocument`
- 把 `CodeEditorTextView` 的 change set 回调透传给宿主，但要过滤程序性回写

建议骨架：

```swift
struct CodeEditorView: View {
    @Binding var text: String
    let persistedText: String
    let fileURL: URL
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)?
    var onTextChange: ((String, EditorChangeSet) -> Void)?

    @State private var document: CodeEditorDocument
}
```

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorView.swift agentGui/Models/CodeEditorDocument.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "feat: add code editor shell view"
```

### Task 4: 把 FileEditorView 文本文件切到 CodeEditorView

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/FileEditorCodeEditorUITests.swift`

**Step 1: Write the failing test**

先补两层回归：

1. 单元/集成测试：`FileEditorView` 的文本分支改走 `CodeEditorView` 后，`workspaceState.editorSelection` 仍能收到选区快照，`syncOpenDocumentToLSPIfNeeded` 仍随文本变化触发。
2. UI 测试：打开文本文件后，界面存在 `codeEditor.textView`，不存在 `blockEditor.textView`；输入文字后 dirty 状态从 `clean` 变 `dirty`，点击保存后回到 `clean`。

UI 示例：

```swift
func testTextFileUsesDedicatedCodeEditorPath() throws {
    app.launchArguments += [
        "-com.agentgui.test.mode", "true",
        "-com.agentgui.test.preloadApiKey", "true",
        "-com.agentgui.test.selectedFilePath", "/Volumes/T7/文稿/Projects/agentGui/tmp/code-editor-feature1.txt"
    ]

    app.launch()

    XCTAssertTrue(app.textViews["codeEditor.textView"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.textViews["blockEditor.textView"].exists)
}
```

**Step 2: Run test to verify it fails**

Run unit/integration test:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests
```

Run UI test:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiUITests/FileEditorCodeEditorUITests
```

Expected: FAIL because FileEditorView still renders `BlockDocumentEditor` for text files.

**Step 3: Write minimal implementation**

把 `FileEditorView.fileContentView(for:)` 的 `.text` 分支替换为：

```swift
CodeEditorView(
    text: Binding(
        get: { sessionController.document.textContent },
        set: { newValue in
            sessionController.updateText(newValue)
        }
    ),
    persistedText: sessionController.document.persistedText,
    fileURL: url,
    onSelectionChange: { snapshot in
        workspaceState.editorSelection = snapshot
    },
    onTextChange: { newValue, _ in
        syncOpenDocumentToLSPIfNeeded(text: newValue)
    }
)
```

同时保留：

- 顶部 breadcrumb / save button / dirty mirror
- 图片和 PDF 分支不变
- `triggerWorkspaceLSPBootstrap(for:)` 逻辑不变
- 外部冲突 banner 不变

**Step 4: Run test to verify it passes**

先跑 unit/integration，再跑 UI test，两个命令都应 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/FileEditorView.swift agentGuiUITests/FileEditorCodeEditorUITests.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "feat: route text files through code editor shell"
```

### Task 5: 做 Feature 1 验收与回归门禁

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-29-code-editor-feature-1-implementation-plan.md`（如需补记实际测试结果）

**Step 1: Run focused automated tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorDocumentTests \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  -only-testing:agentGuiUITests/FileEditorCodeEditorUITests
```

Expected: PASS.

**Step 2: Run manual smoke checklist**

手工验证以下场景：

- 打开 `.txt`、`.swift`、`.md` 文本文件时都走 `codeEditor.textView`
- 中文输入法组合输入不丢字、不重复触发保存
- `⌘S` 保存后 dirty 状态回到 clean
- `⌘Z` / `⇧⌘Z` 能正确撤销和重做本地文本编辑
- 外部修改文件且当前无未保存修改时，编辑器内容自动刷新
- 外部修改文件且当前有未保存修改时，仍显示现有冲突 banner
- 切换到图片/PDF 文件时不受影响

**Step 3: If a regression appears, fix before moving to Feature 2**

修复优先级：

1. 输入法 / first responder / 选区丢失
2. 撤销栈失效
3. 外部 reload 回声写回
4. 保存或 dirty 状态错误

**Step 4: Commit**

```bash
git add docs/plans/2026-03-29-code-editor-feature-1-implementation-plan.md
git commit -m "docs: finalize code editor feature 1 verification plan"
```

## 6. 风险与应对

### 风险 1: 程序性全文回写被误识别为用户编辑

这会导致外部 reload 之后又触发一次 `updateText` / LSP sync，甚至把磁盘内容重新标记为 dirty。

**应对：**

- `CodeEditorTextView.Coordinator` 必须有明确的 `isApplyingProgrammaticUpdate` 标记。
- 只有 `textDidChange` 且不在程序性更新窗口内时，才生成 `.userEdit` 的 `EditorChangeSet`。

### 风险 2: 保存成功后 clean anchor 不更新

这会表现为文本已写盘，但 UI 仍旧显示 dirty。

**应对：**

- `CodeEditorView` 需要监听 `persistedText` 变化，并在当前全文与 persisted text 相等时刷新内部 clean 状态。
- 不要尝试在 Feature 1 自己维护一套独立 dirty 判定，继续以 `FileEditorSessionController.document.hasUnsavedChanges` 为 UI 真相。

### 风险 3: first responder / 选区在 SwiftUI 更新后丢失

这是 `NSViewRepresentable` 最容易踩的坑。

**应对：**

- `updateNSView` 中只在文本真的不同的时候替换 `textView.string`
- 程序性替换前后保存并恢复 `selectedRanges`
- 焦点请求必须带 token，避免重复抢焦点

### 风险 4: 过早把 LSP 逻辑塞进 CodeEditorView

会把 Feature 1 和 Feature 5 绑死，导致首轮实现复杂度暴涨。

**应对：**

- Feature 1 只透传文本变化给 `FileEditorView`
- `syncOpenDocumentToLSPIfNeeded(text:)` 暂时继续留在宿主层

## 7. 完成定义

满足以下条件后，Feature 1 可以视为完成：

- 文本文件打开后不再实例化 `BlockDocumentEditor`，而是走 `CodeEditorView` / `CodeEditorTextView`
- 纯文本输入、中文输入法、选区、焦点、撤销、保存都稳定可用
- `workspaceState.editorSelection` 继续能拿到选中文本与行范围
- `FileEditorSessionController` 的保存、外部刷新、冲突提示行为不退化
- UI 测试能稳定断言文本文件走的是新编辑器路径
- 没有把高亮、gutter、LSP 协调器提前耦合进 Feature 1

## 8. 后续衔接

Feature 1 合并后，Feature 2 可以直接建立在 `CodeEditorDocument + CodeEditorTextView + CodeEditorView` 之上，把 offset/line 映射、visible range 和 gutter 数据源接进来，而不必再考虑 BlockDocumentEditor 的块级模型。

Plan complete and saved to `docs/plans/2026-03-29-code-editor-feature-1-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按 Task 顺序逐个实现、逐个验证

**2. Parallel Session (separate)** - 新开会话按 executing-plans skill 执行

**Which approach?**