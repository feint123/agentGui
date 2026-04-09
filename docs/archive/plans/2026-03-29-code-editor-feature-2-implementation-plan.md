# Code Editor Feature 2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为专用 CodeEditor 主路径补上可增量维护的行索引与 offset/line/column 位置映射，淘汰编辑过程中的全文扫描换算，为后续 gutter、visible range、diagnostics 与 LSP 坐标转换提供稳定基础。

**Architecture:** 延续 Feature 1 的轻量 CodeEditor 架构，不引入新的文本缓冲后端；真实文本仍由 `String` 和 `NSTextView` 承载，`CodeEditorLineIndex` 作为独立服务维护 UTF-16 偏移到行列的映射。首轮采用“基线 `lineStartOffsets` + 受影响窗口重扫 + 后续偏移平移”的实现，而不是 piece tree 或 chunk tree；映射 API 先挂到 `CodeEditorDocument` 上，确保现有编辑器调用方统一通过文档层拿到位置数据。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Foundation、Swift Testing、现有 `CodeEditorDocument` / `CodeEditorTextView` / `FileLineRange`。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 当前执行状态（2026-03-29）

- Feature 2 主体实现已完成：新增 `CodeEditorLineIndex` 与 `CodeEditorTextLocation`，并以 UTF-16 语义提供 `offset <-> line/column`、`FileLineRange` 映射和增量编辑更新能力。
- `CodeEditorDocument` 现已持有 `lineIndex`，在 `applyUserEdit` 与 `replaceFromDisk` 中同步维护，并对外暴露统一的位置映射查询 API。
- `CodeEditorTextView.Coordinator.selectionSnapshot` 已移除 `newlineCount` 全文扫描路径，统一改由 `parent.document.lineRange(for:)` 生成选区行号结果。
- 已新增并通过聚焦测试：`CodeEditorLineIndexTests`、扩充后的 `CodeEditorDocumentTests`、`CodeEditorTextViewIntegrationTests`，以及回归 `CodeEditorViewIntegrationTests`。
- 已执行并通过的聚焦命令：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorLineIndexTests \
  -only-testing:agentGuiTests/CodeEditorDocumentTests \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

- 实际结果：4 个 suite、23 个测试全部通过；本轮未运行 UI 自动化测试，符合本 feature 范围约束。

## 0. 范围约束

- Feature 2 只解决位置映射与增量行索引，不提前引入 gutter、高亮调度、LSP 协调器或可见区缓存。
- Feature 2 不重写 `NSTextView` 文本存储，不引入 rope、piece table 或 chunk tree；真实文本仍继续以 `String` 为真相。
- Feature 2 的公开 API 以 UTF-16 offset 为基准，因为 `NSTextView`、`NSRange`、LSP 文档同步和现有 `CodeEditorDocument` 都已经建立在 UTF-16 语义上。
- Feature 2 的正确性优先于极限性能；首轮目标是淘汰“每次全量扫描全文”的路径，把普通编辑更新收敛到受影响窗口。
- Feature 2 必须保留现有 `EditorSelectionSnapshot` 对外契约，避免影响 `WorkspaceState` 与上下文引用 UI。
- 这个 Xcode 工程使用 `PBXFileSystemSynchronizedRootGroup`；在 `agentGui` 与 `agentGuiTests` 下新增文件通常不需要手改工程文件。

## 1. 方案结论

本 Feature 建议采用下面这条实现路线：

1. 新增独立的 `CodeEditorLineIndex` 值类型，内部维护：
   - `textLength`
   - `lineStartOffsets: [Int]`
   - 由此推导的 `lineCount`
2. 把索引更新入口设计成单一方法，例如：

```swift
mutating func applyEdit(replacedRange: NSRange, insertedText: String, in updatedText: String)
```

3. 索引提供最小但完整的查询面：
   - `lineNumber(containingUTF16Offset:)`
   - `columnNumber(atUTF16Offset:)`
   - `location(ofUTF16Offset:)`
   - `utf16Offset(line:column:)`
   - `lineRange(forUTF16Range:)`
   - `lineStartOffset(forLine:)`
4. `CodeEditorDocument` 保存一份行索引镜像，并在 `applyUserEdit` / `replaceFromDisk` 时同步维护它。
5. `CodeEditorTextView` 不再自己数换行，而是统一通过 `CodeEditorDocument` 导出的映射 API 生产 `EditorSelectionSnapshot`。

这样做的原因：

- 保持 Feature 2 边界清晰，只解决映射基础设施，不把高亮或 LSP 一起卷进来。
- 让未来 Feature 3-6 可以直接依赖稳定的文档映射接口，而不是重复操作原始字符串。
- 把当前最明显的全文扫描热点先拔掉，同时不引入对 TextKit 过高风险的侵入。

## 2. 代码锚点

当前 Feature 2 相关的真实落点如下：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
  当前只保存 `text`、`persistedText`、`version` 和 `selectedRange`，还没有行索引或任何位置映射 API。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/EditorChangeSet.swift`
  当前变更模型已经具备 `replacedRange` 与 `insertedText`，适合作为索引增量更新输入。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
  当前 `selectionSnapshot` 内通过 `textBeforeSelection` 和 `newlineCount` 计算 `startLine/endLine`，这是直接的替换目标。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceFileContextFormatter.swift`
  当前定义了 `FileLineRange` 和 `EditorSelectionSnapshot`；Feature 2 不应复制这些展示层类型。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorDocumentTests.swift`
  这里已经覆盖了 Feature 1 的文档模型变更行为，Feature 2 需要扩充文档索引同步断言。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
  当前只校验文本变更和选区快照结果，没有约束这些结果必须来自统一索引服务。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
  这是 Feature 2 集成测试继续复用的 AppKit harness。

## 3. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorLineIndex.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLineIndexTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorDocumentTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

### Optional modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceFileContextFormatter.swift`
  只有在需要补充轻量位置类型或便捷格式化 helper 时才修改；否则保持不动。

## 4. 数据结构设计

### 4.1 `CodeEditorLineIndex`

建议实现为值类型：

```swift
struct CodeEditorLineIndex: Equatable {
    private(set) var textLength: Int
    private(set) var lineStartOffsets: [Int]

    init(text: String)
    var lineCount: Int { get }

    mutating func replaceAll(with text: String)
    mutating func applyEdit(replacedRange: NSRange, insertedText: String, in updatedText: String)

    func lineNumber(containingUTF16Offset offset: Int) -> Int
    func columnNumber(atUTF16Offset offset: Int) -> Int
    func location(ofUTF16Offset offset: Int) -> CodeEditorTextLocation
    func utf16Offset(line: Int, column: Int) -> Int
    func lineRange(forUTF16Range range: NSRange) -> FileLineRange
    func lineStartOffset(forLine line: Int) -> Int
}
```

如果需要一个查询返回值，建议只增加一个最小类型：

```swift
struct CodeEditorTextLocation: Equatable {
    let line: Int
    let column: Int
}
```

不要在 Feature 2 提前引入可见区对象、gutter 模型或 LSP 专用 wrapper。`line`、`column` 统一采用 1-based，内部偏移保留 UTF-16 0-based，避免和 `FileLineRange` 语义冲突。

### 4.2 初始化与全量重建

首轮初始化逻辑保持简单直接：

- `lineStartOffsets` 至少从 `[0]` 开始。
- 遍历全文 UTF-16 标量，遇到换行符就在下一字符位置记录新的行起点。
- 结尾不需要额外哨兵值；末行结束由 `textLength` 与下一行起点缺失共同表示。

这样可以避免“空文本是否有 0 行还是 1 行”的歧义：空文本仍视为 1 行，且唯一行起点为 0。

### 4.3 增量更新算法

`applyEdit` 的目标不是做到理论最优，而是做到可解释、可验证、可维护：

1. 基于旧的 `lineStartOffsets` 找到 `replacedRange.location` 与 `replacedRange.upperBound` 所在的旧起止行。
2. 计算受影响重扫窗口的旧文本范围：
   - 起点使用受影响首行的 `lineStartOffset`
   - 终点使用“受影响末行的下一行起点”，若不存在则使用旧 `textLength`
3. 在 `updatedText` 中取出对应的新窗口文本，只对这个窗口重扫换行并生成新的局部行起点。
4. 用新局部结果替换旧的受影响行段。
5. 计算本次编辑导致的 UTF-16 长度差值，对窗口之后的所有 `lineStartOffsets` 批量平移。
6. 更新 `textLength`。

实现时要特别锁住两个边界：

- 在行首和行尾插入换行。
- 删除横跨多行的区间后，使多行合并成一行。

Feature 2 不需要 chunk tree，但允许在实现里保留私有 helper，把“定位行号”“重扫窗口”“平移后续偏移”拆成独立函数，避免一个方法过长。

## 5. 文档层集成策略

`CodeEditorDocument` 在 Feature 2 的职责应从“文本和版本容器”升级为“文本 + 位置映射门面”：

- 新增 `lineIndex` 存储属性，并在初始化时按 `text` 构建。
- `applyUserEdit` 内先更新 `text`，再把相同 edit 应用到 `lineIndex`。
- `replaceFromDisk` 直接重建整份 `lineIndex`。
- 补充文档查询 API，例如：

```swift
func lineRange(for range: NSRange) -> FileLineRange
func location(ofUTF16Offset offset: Int) -> CodeEditorTextLocation
func utf16Offset(line: Int, column: Int) -> Int
```

这里不要把 UI 事件对象塞回 `CodeEditorDocument`。文档层只暴露映射结果，不知道 `NSTextView`、popover 或 LSP 请求。

## 6. 编辑器层集成策略

`CodeEditorTextView.Coordinator.selectionSnapshot` 的改造应非常克制：

- 保留当前 `selectedText` 的构造方式，因为它依赖原始字符串切片。
- 删除 `newlineCount(in:)` 及相关全文扫描逻辑。
- 用 `parent.document.lineRange(for: safeRange)` 生成 `FileLineRange`。
- 如果后续需要展示光标位置，再直接复用 `parent.document.location(ofUTF16Offset:)`，不要重新实现另一套换算。

目标不是让 `CodeEditorTextView` 变复杂，而是让它变薄，只负责桥接原生输入事件。

## 7. 测试门禁

Feature 2 的测试要同时覆盖“静态正确性”和“编辑后的增量稳定性”。

### 7.1 `CodeEditorLineIndexTests`

至少覆盖以下场景：

- 空文本、单行文本、多行文本初始化。
- offset -> line/column 映射。
- line/column -> offset 映射。
- 范围到 `FileLineRange` 的换算。
- 单行内插入。
- 在行首/行尾插入换行。
- 删除换行使两行合并。
- 多行替换。
- 文本尾部追加内容。
- 随机替换回归：每次编辑后拿增量索引结果和“重新全量构建索引”的结果比对，保证完全一致。

### 7.2 `CodeEditorDocumentTests`

新增断言：

- 初始文档能正确导出行数与位置映射。
- `applyUserEdit` 后文档查询 API 使用的是更新后的索引，而不是旧文本。
- `replaceFromDisk` 会完整重建索引。

### 7.3 `CodeEditorTextViewIntegrationTests`

新增断言：

- 多行选区快照在编辑后仍能返回正确 `FileLineRange`。
- 连续编辑后选区行范围跟随最新索引变化。

Feature 2 不需要 UI 自动化测试；现有 UI 路径没有新增交互控件，单元与集成测试已经足够锁定行为。

## 8. 任务拆解

### Task 1: 为行索引定义失败测试与查询契约

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLineIndexTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorLineIndex.swift`

**Step 1: Write the failing test**

先定义初始化和查询契约，不要一开始就写增量更新：

```swift
@Test
func buildsLineStartsAndLocationsFromMultilineText() {
    let index = CodeEditorLineIndex(text: "alpha\nbeta\ngamma")

    #expect(index.lineCount == 3)
    #expect(index.lineStartOffset(forLine: 1) == 0)
    #expect(index.lineStartOffset(forLine: 2) == 6)
    #expect(index.location(ofUTF16Offset: 7) == CodeEditorTextLocation(line: 2, column: 2))
    #expect(index.lineRange(forUTF16Range: NSRange(location: 6, length: 4)) == FileLineRange(startLine: 2, endLine: 2))
}
```

补上空文本、尾部 offset、跨行 range 的失败测试。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorLineIndexTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `CodeEditorLineIndex` 与可能的 `CodeEditorTextLocation` 尚不存在。

**Step 3: Write minimal implementation**

先实现全量构建和查询 API，不写增量更新：

```swift
struct CodeEditorLineIndex: Equatable {
    private(set) var textLength: Int
    private(set) var lineStartOffsets: [Int]

    init(text: String) {
        self.textLength = text.utf16.count
        self.lineStartOffsets = Self.computeLineStarts(for: text)
    }

    var lineCount: Int { lineStartOffsets.count }

    func location(ofUTF16Offset offset: Int) -> CodeEditorTextLocation { ... }
    func lineRange(forUTF16Range range: NSRange) -> FileLineRange { ... }
}
```

这里允许内部先用二分查找定位某个 offset 所属行；不要用每次顺序扫描整份 `lineStartOffsets`。

**Step 4: Run test to verify it passes**

运行同一条命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorLineIndex.swift agentGuiTests/CodeEditorLineIndexTests.swift
git commit -m "feat: add code editor line index queries"
```

### Task 2: 为增量编辑路径补上索引更新算法

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorLineIndex.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLineIndexTests.swift`

**Step 1: Write the failing test**

新增编辑场景测试，重点验证索引不会退回全量 rebuild 语义错误：

```swift
@Test
func applyEditUpdatesOnlyAffectedMappingSemantics() {
    var index = CodeEditorLineIndex(text: "alpha\nbeta\ngamma")
    let updatedText = "alpha\nbe\nta\ngamma"

    index.applyEdit(
        replacedRange: NSRange(location: 8, length: 0),
        insertedText: "\n",
        in: updatedText
    )

    #expect(index.lineCount == 4)
    #expect(index.location(ofUTF16Offset: 9) == CodeEditorTextLocation(line: 3, column: 1))
}
```

再加一组随机回归测试：生成一批随机替换操作，每次都把增量索引与 `CodeEditorLineIndex(text: updatedText)` 的结果逐项比对。

**Step 2: Run test to verify it fails**

运行：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorLineIndexTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `applyEdit` 尚未实现或实现不正确。

**Step 3: Write minimal implementation**

在 `CodeEditorLineIndex` 中加入：

- 旧行段定位 helper
- 受影响窗口重扫 helper
- 后续偏移平移 helper
- `replaceAll(with:)` 作为兜底路径，供整份 reload 复用

如果实现过程中发现某些边界难以一步到位，优先保证正确性：在极端异常输入下允许退回 `replaceAll(with:)`，但普通编辑路径必须走增量更新。

**Step 4: Run test to verify it passes**

运行同一条命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorLineIndex.swift agentGuiTests/CodeEditorLineIndexTests.swift
git commit -m "feat: support incremental code editor line indexing"
```

### Task 3: 把索引接入 CodeEditorDocument

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorDocumentTests.swift`

**Step 1: Write the failing test**

扩充文档测试，锁定以下行为：

```swift
@Test
func applyUserEditKeepsLineIndexInSync() {
    var document = CodeEditorDocument(text: "alpha\nbeta", persistedText: "alpha\nbeta")

    _ = document.applyUserEdit(
        replacing: NSRange(location: 5, length: 0),
        insertedText: "\n",
        updatedText: "alpha\n\nbeta",
        selectedRange: NSRange(location: 6, length: 0)
    )

    #expect(document.lineRange(for: NSRange(location: 6, length: 0)) == FileLineRange(startLine: 2, endLine: 2))
    #expect(document.location(ofUTF16Offset: 7) == CodeEditorTextLocation(line: 3, column: 1))
}
```

同时覆盖 `replaceFromDisk` 后索引整体重建。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorDocumentTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为文档尚未维护行索引或没有导出映射 API。

**Step 3: Write minimal implementation**

在 `CodeEditorDocument` 中加入：

```swift
var lineIndex: CodeEditorLineIndex

init(text: String, persistedText: String, version: Int = 0, selectedRange: NSRange = NSRange(location: 0, length: 0)) {
    self.text = text
    self.persistedText = persistedText
    self.version = version
    self.selectedRange = selectedRange
    self.lineIndex = CodeEditorLineIndex(text: text)
}

func lineRange(for range: NSRange) -> FileLineRange { ... }
func location(ofUTF16Offset offset: Int) -> CodeEditorTextLocation { ... }
func utf16Offset(line: Int, column: Int) -> Int { ... }
```

然后在 `applyUserEdit` 与 `replaceFromDisk` 内同步维护 `lineIndex`。

**Step 4: Run test to verify it passes**

运行同一条命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/CodeEditorDocument.swift agentGuiTests/CodeEditorDocumentTests.swift
git commit -m "feat: expose code editor position mapping from document"
```

### Task 4: 让 CodeEditorTextView 全部通过索引服务生成选区行号

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

**Step 1: Write the failing test**

把当前选区测试扩成“编辑后再选区”的场景，防止旧的全文扫描逻辑残留：

```swift
@Test
func selectionSnapshotUsesUpdatedLineIndexAfterEdit() {
    let harness = CodeEditorTextViewHarness(text: "alpha\nbeta")

    harness.replaceCharacters(in: NSRange(location: 5, length: 0), with: "\n")
    harness.select(range: NSRange(location: 6, length: 0))

    #expect(harness.document.lineRange(for: NSRange(location: 6, length: 0)) == FileLineRange(startLine: 2, endLine: 2))
}
```

再保留原有“选中 `beta` 应返回第 2 行”的回归测试，防止行为倒退。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，或者测试暂时无法证明统一走索引服务。

**Step 3: Write minimal implementation**

在 `selectionSnapshot` 内改成：

```swift
let lineRange = parent.document.lineRange(for: safeRange)
return EditorSelectionSnapshot(
    text: selectedText,
    lineRange: lineRange
)
```

删除 `newlineCount(in:)` 和依赖全文扫描的辅助逻辑。保持 `selectedText` 提取、程序性更新保护、选区 observer 机制不变。

**Step 4: Run test to verify it passes**

运行同一条命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "refactor: use line index for code editor selection mapping"
```

### Task 5: 跑完整聚焦测试并记录 Feature 2 验收

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-29-code-editor-feature-2-implementation-plan.md`

**Step 1: Run focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorLineIndexTests \
  -only-testing:agentGuiTests/CodeEditorDocumentTests \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

**Step 2: Optional broader regression**

如果本轮改动碰到 `FileEditorView` 或 selection downstream，可补跑：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeEditorDocumentTests \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

**Step 3: Update plan status notes**

把已完成的任务、实际运行的测试命令和任何剩余风险补记到本计划文档顶部状态区。

**Step 4: Commit**

```bash
git add docs/plans/2026-03-29-code-editor-feature-2-implementation-plan.md
git commit -m "docs: record code editor feature 2 execution status"
```

## 9. 风险与决策点

### 风险 1: UTF-16 与 Character 边界混用

当前编辑器、`NSRange` 和 LSP 都以 UTF-16 为主；如果实现里某处改用 `String.Index` 的字符语义，很容易出现多字节字符位置错位。

**应对：** 所有偏移、列号和测试样例都明确按 UTF-16 语义编写；必要时在测试里加入 emoji 或中文样例，确认 offset 映射不会错位。

### 风险 2: 增量更新窗口选择不正确

如果受影响窗口取太窄，跨行删除或插入换行后会导致后续行号错位。

**应对：** 用“受影响首行起点到受影响末行下一行起点”的窗口规则，并用随机替换回归测试与全量重建结果比对。

### 风险 3: 文档层与文本视图层各自维护一套映射

如果 `CodeEditorTextView` 保留旧的 `newlineCount` 逻辑，就会出现一边增量索引、一边全文扫描的双轨状态。

**应对：** Feature 2 明确要求删除视图层自己的换行计数路径，所有行号结果统一从 `CodeEditorDocument` 导出。

## 10. 完成定义

达到以下条件时，可以认为 Feature 2 完成：

- 已存在独立的 `CodeEditorLineIndex`，并覆盖初始化、查询、增量编辑与随机回归测试。
- `CodeEditorDocument` 能在用户编辑和磁盘 reload 后维护正确的行索引。
- `CodeEditorTextView` 不再通过全文扫描构建 `EditorSelectionSnapshot.lineRange`。
- 现有 CodeEditor focused tests 全部通过。
- 普通编辑场景下的行列映射结果与全量重建完全一致。

## 11. 最终建议

Feature 2 的关键不是把数据结构做得多激进，而是尽快把“位置映射的唯一真相来源”立住。最务实的执行顺序就是：先锁测试契约，再做 `CodeEditorLineIndex`，然后把 `CodeEditorDocument` 和 `CodeEditorTextView` 统一接过去。

Plan complete and saved to `docs/plans/2026-03-29-code-editor-feature-2-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按任务顺序逐个实现、逐个验证

**2. Parallel Session (separate)** - 新开会话按 executing-plans skill 并行执行

**Which approach?**