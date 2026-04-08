# FT-R8：内联编辑（新建文件/文件夹、重命名）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在文件树中实现行内编辑功能：用户可通过 `Cmd+N`（新建文件）、`Cmd+Shift+N`（新建文件夹）、`Return`（重命名选中条目）触发；占位行即时出现在正确位置，`NSTextField` 子类接收键盘输入；`Return` 提交（通过 `WorkspaceFileTreeOperations` 写入磁盘，刷新 Store）；`Esc` 或失焦时草稿为空则取消并移除占位行；输入验证（空名/重复名/非法字符）以行内错误提示展示，不阻塞 UI。

**Architecture:**
- `InlineEditSession` — `Sendable` 值类型，持有当前编辑会话的全部状态（`kind`、`parentDirectoryID`、`targetEntryID`、`placeholderIndex`、`draftName`），存于 `FileTreeViewModel`（`@MainActor`），**不**放入 `FileTreeStore` actor（纯 UI 状态，不跨 actor 共享）。
- 占位行 — `VisibleEntry` 新增 `isEditPlaceholder: Bool`（默认 `false`）；`beginCreate()` 在 `visibleEntries` 的正确位置插入一个以 `EntryID.placeholderSentinel` 为键的占位行。
- `FileTreeInlineTextField` — `NSTextField` 子类，处理 Return/Esc/blur 三分支，每次 `textDidChange` 实时调用 `onValidate` 显示错误提示。
- `FileTreeCellView` — 检测两种情况切换到文本框模式：`entry.isEditPlaceholder`（新建）或 `viewModel.inlineEdit?.targetEntryID == entry.id`（重命名）；两种情况下隐藏 nameLabel、显示 `FileTreeInlineTextField`。
- 提交路径：`commitEdit()` → 校验 → `WorkspaceFileTreeOperations.createFile/createDirectory/renameItem` → `store.refreshDirectory(parentURL)` → `store.computeVisibleEntries()` → `visibleEntries` 刷新。
- 旧代码 `WorkspaceTreeInlineEdit.swift` 在 Task 5 删除。

**Tech Stack:** Swift 6.0+, AppKit（`NSTextField` + `NSTextFieldDelegate`），XCTest

**参考来源：**
- **VSCode** [`explorerViewer.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/views/explorerViewer.ts)
  - `FilesRenderer.renderElement()` — `this.explorerService.getEditableData(stat)` 返回非 nil 时，隐藏 label element、调用 `renderInputBox(container, stat, editableData)` 渲染内联输入框；对应本计划的 `FileTreeCellView` 检测 `entry.isEditPlaceholder` / `inlineEdit?.targetEntryID == entry.id` 分支。
  - `renderInputBox()` — 创建 `InputBox`，自动选中文件名主干（`lastDot > 0 && !stat.isDirectory ? lastDot : value.length`）；`KeyCode.Enter` → 若 `inputBox.validate()` 通过则 `done(true, true)`；`KeyCode.Escape` → `done(false, true)`；失焦 blur → 异步等待 context-view 隐藏后 `done(inputBox.isInputValid(), true)`（合法则提交，否则取消）；对应本计划的 `FileTreeInlineTextField` 的 Return/Esc/`controlTextDidEndEditing` 三分支。
  - `editableData.validationMessage(value)` — 返回 `IFileOperationResult?`（ERROR/WARNING/INFO），供 `InputBox.showMessage()` 展示；对应本计划的 `InlineEditSession.validateDraftName(siblingNames:)` 返回 `EditValidationError?`。
- **Zed** [`project_panel.rs`](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs)
  - `EditState` struct — 字段 `entry_id`, `is_dir`, `leaf_entry_id: Option<ProjectEntryId>`, `processing_filename: Option<Arc<RelPath>>`, `validation_state: ValidationState`；`is_new_entry() → self.leaf_entry_id.is_none()`；对应本计划 `InlineEditSession.Kind`（`.createFile`/`.createFolder` 为新建，`.rename` 时 `targetEntryID` 非 nil）。
  - `add_entry(is_dir, cx)` — 设 `edit_state = Some(EditState { entry_id: directory_id, leaf_entry_id: None, ... })` 后以 `NEW_ENTRY_ID = ProjectEntryId::MAX` sentinel 调用 `update_visible_entries`；对应本计划 `beginCreate()` 中插入以 `EntryID.placeholderSentinel` 为 id 的占位行。
  - `rename_impl(selection, cx)` — `leaf_entry_id = Some(entry_id)`，`filename_editor` 文字设为 `file_name`，范围选中 `0..stem_len`；对应 `beginRename(_ id:)`：`inlineEdit.targetEntryID = id`，`draftName = entry.name`，`FileTreeInlineTextField.beginEditing(selectStem: !isDirectory)`。
  - `confirm_edit(refocus, cx)` — 读 `filename_editor.text()`，空名时 early return，调 `project.create_entry / rename_entry`，成功后 `edit_state = None` 并 `update_visible_entries`；对应 `commitEdit()`。
  - `discard_edit_state(cx)` — `edit_state.take()` 后重新 `update_visible_entries(previously_focused, ...)`；对应 `cancelEdit()`：移除占位行，`inlineEdit = nil`。
  - `populate_validation_error(cx)` — 订阅 `BufferEdited` 实时校验：空名、首尾空格、`already_exists`（大小写不敏感）→ `ValidationState::Error/Warning/None`；对应 `validateDraftName(siblingNames:)` 在 `controlTextDidChange` 中实时调用。
  - `filename_editor` 订阅 `EditorEvent::Blurred` → `confirm_edit(false, cx)`；对应 `FileTreeInlineTextField.controlTextDidEndEditing(_:)` 失焦分支。
- 设计文档 `docs/plans/2026-07-15-filetree-rewrite-design.md` §FT-R8

---

## 前置条件

- 已完成 FT-R0 ✅（`VisibleEntry: Identifiable & Equatable`、`EntryID`、`FileEntry`、`FileTreeStore` actor 骨架）
- 已完成 FT-R1 ✅（`FSEventObserver` 集成）
- 已完成 FT-R2 ✅（`FileTreeTableView`、`Coordinator`、`FileTreeCellView`）
- 已完成 FT-R3 ✅（`VisibleEntry.loadState`、loading spinner、错误回退）
- 已完成 FT-R4 ✅（`FileTreeDiff.compute`、增量行动画）
- 已完成 FT-R5 ✅（Auto-fold 单子目录链）
- 已完成 FT-R7 ✅（Git 状态 badge）

当前实现缺口：

| 文件 | 现状 | FT-R8 目标 |
|------|------|-----------|
| `agentGui/Models/VisibleEntry.swift` | 无 `isEditPlaceholder` 字段；`VisibleEntry` 无占位行工厂 | 新增 `var isEditPlaceholder: Bool = false`；`static func placeholder(depth:parentID:)` |
| `agentGui/Models/InlineEditSession.swift` | 不存在 | 新建：`Kind`、`parentDirectoryID`、`targetEntryID`、`draftName`、`validateDraftName(siblingNames:)` |
| `agentGui/Models/EditValidationError.swift` | 不存在 | 新建（或合并入 `InlineEditSession.swift`）：`emptyName`、`duplicateName`、`illegalCharacter` |
| `agentGui/Views/FileTree/FileTreeInlineTextField.swift` | 不存在 | 新建：`NSTextField` 子类，Return/Esc/blur/实时校验 |
| `agentGui/ViewModels/FileTreeViewModel.swift` | 无内联编辑字段/方法 | 新增 `inlineEdit`、`validationError`、`rootDirectory`、`beginCreate`、`beginRename`、`commitEdit`、`cancelEdit` |
| `agentGui/Views/FileTree/FileTreeCellView.swift` | 只有 label 正常态渲染 | 编辑态检测：隐藏 label，显示 `FileTreeInlineTextField` |
| `agentGui/Views/FileTree/FileTreeTableView.swift` | 无键盘快捷键回调；使用 `NSTableView()` | 替换为 `FileTreeKeyboardTableView` 子类；新增 `inlineEditSession`、`onNewFile`、`onNewFolder`、`onRenameSelected`、`onCommitEdit`、`onCancelEdit` props |
| `agentGui/Views/FileTree/FileTreeContainerView.swift` | 未绑定内联编辑回调 | 将 ViewModel 方法绑定到 TableView 回调 |
| `agentGui/Services/FileTreeStore.swift` | `refreshDirectory` 为 `private`；无 `siblingNames` | 改为 `internal`；新增 `siblingNames(of:) -> [String]` |
| `agentGui/Views/WorkspaceTree/WorkspaceTreeInlineEdit.swift` | 旧树形递归实现（112 行） | Task 5 删除 |
| `agentGuiTests/FileTreeInlineEditTests.swift` | 不存在 | 新建，覆盖 11 个测试场景 |

---

## Task 1：`InlineEditSession` 数据模型 + `VisibleEntry.isEditPlaceholder`

**Files:**
- Create: `agentGui/Models/InlineEditSession.swift`
- Modify: `agentGui/Models/VisibleEntry.swift`
- Create: `agentGuiTests/FileTreeInlineEditTests.swift`

这是 FT-R8 的模型层，后续所有 Task 依赖此处的类型定义。目标：
1. 定义 `InlineEditSession: Sendable & Equatable`（`Kind`、各字段、`isNewEntry`、`validateDraftName`）。
2. 定义 `EditValidationError: LocalizedError & Equatable`（`emptyName`、`duplicateName`、`illegalCharacter`）。
3. `VisibleEntry` 新增 `var isEditPlaceholder: Bool`（默认 `false`）+ 静态工厂 `placeholder(depth:parentID:)` + sentinel `EntryID.placeholderSentinel`。
4. 初始测试：校验逻辑 + 占位行标志位。

### Step 1：编写预期失败的测试

**新建** `agentGuiTests/FileTreeInlineEditTests.swift`：

```swift
// agentGuiTests/FileTreeInlineEditTests.swift
import XCTest
@testable import agentGui

/// FT-R8 内联编辑测试。
///
/// 对标：
/// - VSCode `editableData.validationMessage()` 的 ERROR/WARNING 分类
/// - Zed `populate_validation_error(cx)` 的 empty / whitespace / already_exists 检测
final class FileTreeInlineEditTests: XCTestCase {

    // MARK: - 校验：EditValidationError

    func testValidation_emptyName_returnsEmptyNameError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: ""
        )
        XCTAssertEqual(session.validateDraftName(siblingNames: []), .emptyName)
    }

    func testValidation_whitespaceOnly_returnsEmptyNameError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "   "
        )
        XCTAssertEqual(session.validateDraftName(siblingNames: []), .emptyName)
    }

    func testValidation_duplicateName_returnsDuplicateError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "main.swift"
        )
        let error = session.validateDraftName(siblingNames: ["main.swift", "utils.swift"])
        XCTAssertEqual(error, .duplicateName("main.swift"))
    }

    func testValidation_duplicateName_caseInsensitive_returnsError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "MAIN.SWIFT"
        )
        let error = session.validateDraftName(siblingNames: ["main.swift"])
        XCTAssertEqual(error, .duplicateName("MAIN.SWIFT"))
    }

    func testValidation_illegalCharacter_slash_returnsError() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "foo/bar"
        )
        XCTAssertEqual(session.validateDraftName(siblingNames: []), .illegalCharacter("/"))
    }

    func testValidation_validName_returnsNil() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "NewFile.swift"
        )
        XCTAssertNil(session.validateDraftName(siblingNames: ["main.swift"]))
    }

    // MARK: - VisibleEntry 占位行

    func testPlaceholderEntry_isEditPlaceholder_isTrue() {
        let parentID = EntryID(url: URL(fileURLWithPath: "/tmp/root"))
        let placeholder = VisibleEntry.placeholder(depth: 1, parentID: parentID)
        XCTAssertTrue(placeholder.isEditPlaceholder)
        XCTAssertEqual(placeholder.id, .placeholderSentinel)
    }

    func testNormalEntry_isEditPlaceholder_isFalse() {
        let id = EntryID(url: URL(fileURLWithPath: "/tmp/root/main.swift"))
        let entry = VisibleEntry(
            id: id, name: "main.swift", isDirectory: false,
            depth: 1, isExpanded: false, loadState: .loaded,
            foldedAncestors: nil, gitSummary: nil,
            diagnosticSeverity: nil, isIgnored: false,
            isEditPlaceholder: false
        )
        XCTAssertFalse(entry.isEditPlaceholder)
    }

    // MARK: - InlineEditSession.isNewEntry

    func testIsNewEntry_createFile_isTrue() {
        let session = InlineEditSession(
            kind: .createFile,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: nil,
            placeholderIndex: 0,
            draftName: "new.txt"
        )
        XCTAssertTrue(session.isNewEntry)
    }

    func testIsNewEntry_rename_isFalse() {
        let targetID = EntryID(url: URL(fileURLWithPath: "/tmp/root/old.txt"))
        let session = InlineEditSession(
            kind: .rename,
            parentDirectoryID: EntryID(url: URL(fileURLWithPath: "/tmp/root")),
            targetEntryID: targetID,
            placeholderIndex: -1,
            draftName: "old.txt"
        )
        XCTAssertFalse(session.isNewEntry)
    }
}
```

### Step 2：运行测试（应失败）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeInlineEditTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed"
```

期望：编译失败（`InlineEditSession`、`EditValidationError`、`VisibleEntry.placeholder`、`VisibleEntry.isEditPlaceholder`、`.placeholderSentinel` 均未定义）。

### Step 3：实现 `InlineEditSession` + `EditValidationError`

**新建** `agentGui/Models/InlineEditSession.swift`：

```swift
// agentGui/Models/InlineEditSession.swift
import Foundation

/// 单次内联编辑会话的状态快照。
///
/// 设计对标 Zed `EditState`（project_panel.rs）：
/// 一个 optional 的 `edit_state: Option<EditState>` 持有当前会话，nil = 非编辑态。
/// 本计划将会话存于 `FileTreeViewModel`（@MainActor），而非 `FileTreeStore` actor，
/// 因为它是纯 UI 状态——不影响磁盘，也无需跨 actor 共享。
struct InlineEditSession: Sendable, Equatable {

    enum Kind: Sendable, Equatable {
        /// 新建文件：提交时调 `WorkspaceFileTreeOperations.createFile`。
        case createFile
        /// 新建文件夹：提交时调 `WorkspaceFileTreeOperations.createDirectory`。
        case createFolder
        /// 重命名：`targetEntryID` 为被重命名条目；提交时调 `WorkspaceFileTreeOperations.renameItem`。
        case rename
    }

    let kind: Kind
    /// 新建时：新条目所在父目录 ID。重命名时：被重命名条目的父目录 ID。
    let parentDirectoryID: EntryID
    /// nil → 新建（create）；非 nil → 重命名目标。
    /// 对标 Zed `EditState.leaf_entry_id: Option<ProjectEntryId>`。
    let targetEntryID: EntryID?
    /// 占位行在 `visibleEntries` 中的插入索引（重命名时无意义，设 -1）。
    let placeholderIndex: Int
    /// 用户当前输入的草稿名称（实时更新）。
    var draftName: String

    /// 是否为新建操作（对标 Zed `EditState.is_new_entry()`）。
    var isNewEntry: Bool { targetEntryID == nil }

    // MARK: - 校验

    /// 对 `draftName` 进行校验，返回第一个发现的错误。
    ///
    /// 设计对标：
    /// - VSCode `editableData.validationMessage(value)` — 返回 `IFileOperationResult?`
    /// - Zed `populate_validation_error(cx)` — 检查 empty / whitespace / already_exists
    ///
    /// 调用时机：`FileTreeInlineTextField.controlTextDidChange` 实时调用（显示提示），
    /// 以及 `FileTreeViewModel.commitEdit()` 中再次调用（最终守卫）。
    ///
    /// - Parameter siblingNames: 父目录的直接子条目名称列表（用于重复名检测）。
    func validateDraftName(siblingNames: [String]) -> EditValidationError? {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)

        // 1. 空名（Zed: "Name cannot be empty"）
        if trimmed.isEmpty { return .emptyName }

        // 2. 非法字符（VSCode 拒绝 '/' '\0'；macOS 文件名同样不允许）
        for char in ["/", "\0"] where draftName.contains(char) {
            return .illegalCharacter(char)
        }

        // 3. 重复名（大小写不敏感，对标 Zed `already_exists` 检测）
        let lower = trimmed.lowercased()
        if siblingNames.contains(where: { $0.lowercased() == lower }) {
            return .duplicateName(trimmed)
        }

        return nil
    }
}

/// 内联编辑校验错误。
///
/// 对标 VSCode `MessageType.ERROR/WARNING` 分类
/// 及 Zed `ValidationState::Error(SharedString) / Warning` 枚举。
enum EditValidationError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case illegalCharacter(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "名称不能为空。"
        case .duplicateName(let name):
            return ""\(name)" 已存在，请使用其他名称。"
        case .illegalCharacter(let char):
            return "名称不能包含字符 "\(char)"。"
        }
    }
}
```

### Step 4：修改 `VisibleEntry` — 新增 `isEditPlaceholder` + 静态工厂 + `EntryID.placeholderSentinel`

**修改** `agentGui/Models/VisibleEntry.swift`：

1. 在 `struct VisibleEntry` 末尾（`isIgnored` 后）新增字段：

```swift
    /// 是否为内联编辑占位行（FT-R8）。
    ///
    /// 对标 Zed `NEW_ENTRY_ID = ProjectEntryId::MAX` sentinel：
    /// Zed 用最大值 ID 标记占位条目；本实现在结构体中加显式布尔字段，更类型安全。
    /// 正常构造函数传 false；`VisibleEntry.placeholder(depth:parentID:)` 工厂传 true。
    var isEditPlaceholder: Bool = false
```

> **注意**：Swift 不允许存储属性带运行时默认表达式并自动出现在 memberwise initializer 的末尾——需在所有现有 `VisibleEntry(...)` 调用处补充 `isEditPlaceholder: false`，或将字段改为带显式默认值的 `var`（Swift 5.9+ 支持在结构体中为 stored property 提供默认值，不影响 memberwise init 的已有调用——**实际上 Swift 会自动为带默认值的尾部字段生成可选的 memberwise param**，因此现有调用无需修改）。

2. 在文件末尾新增扩展：

```swift
// MARK: - FT-R8 占位行工厂

extension VisibleEntry {
    /// 创建一个内联编辑占位行（`isEditPlaceholder = true`）。
    ///
    /// 对标 Zed `add_entry(is_dir, cx)` 中以 `NEW_ENTRY_ID` sentinel 插入的条目。
    ///
    /// - Parameters:
    ///   - depth:    缩进层级（与同级条目相同）
    ///   - parentID: 父目录 EntryID（上下文用，不作为占位行自身的真实 ID）
    static func placeholder(depth: Int, parentID: EntryID) -> VisibleEntry {
        VisibleEntry(
            id: .placeholderSentinel,
            name: "",
            isDirectory: false,
            depth: depth,
            isExpanded: false,
            loadState: .loaded,
            foldedAncestors: nil,
            gitSummary: nil,
            diagnosticSeverity: nil,
            isIgnored: false,
            isEditPlaceholder: true
        )
    }
}

extension EntryID {
    /// FT-R8 占位行专用 sentinel（对标 Zed `NEW_ENTRY_ID = ProjectEntryId::MAX`）。
    /// 不会出现在 `FileTreeStore.entries` 中，仅在 `visibleEntries` 临时存在。
    static let placeholderSentinel = EntryID(url: URL(string: "about:new-entry-placeholder")!)
}
```

### Step 5：运行测试（应通过）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeInlineEditTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed"
```

期望：9 个测试全部通过，无编译错误。

### Step 6：提交

```
feat(ft-r8): add InlineEditSession, EditValidationError, VisibleEntry.isEditPlaceholder
```

---

## Task 2：`FileTreeInlineTextField`（NSTextField 子类）

**Files:**
- Create: `agentGui/Views/FileTree/FileTreeInlineTextField.swift`

`FileTreeInlineTextField` 封装内联编辑的文本输入行为。对标 VSCode `renderInputBox()` 中 `InputBox` 的 Return/Esc/blur 三分支，以及 Zed `filename_editor` 的 `EditorEvent::Blurred` 回调。

此 Task 无需专门写单元测试（行为在 Task 4 的集成测试中覆盖）；但需确认编译通过才能继续。

### Step 1：实现 `FileTreeInlineTextField`

**新建** `agentGui/Views/FileTree/FileTreeInlineTextField.swift`：

```swift
// agentGui/Views/FileTree/FileTreeInlineTextField.swift
import AppKit

/// 文件树内联编辑文本框（NSTextField 子类）。
///
/// 行为对标：
/// - VSCode `renderInputBox()` (explorerViewer.ts)：
///   Enter → done(true)，Escape → done(false)，blur → done(isInputValid)
/// - Zed `filename_editor` 订阅 `EditorEvent::Blurred`：失焦时调 `confirm_edit(false, cx)`
///
/// 使用者（`FileTreeCellView`）设置 `onCommit`、`onCancel`、`onValidate` 回调，
/// 并在适当时机调用 `beginEditing(initialText:selectStem:)` 聚焦。
final class FileTreeInlineTextField: NSTextField {

    /// 用户按 Return 且校验通过时调用（携带已 trim 的草稿名称）。
    var onCommit: (String) -> Void = { _ in }
    /// 用户按 Escape，或失焦时草稿为空/校验失败时调用。
    var onCancel: () -> Void = {}
    /// 每次文字变更时调用。返回 nil 表示合法；返回错误则显示行内提示。
    var onValidate: (String) -> EditValidationError? = { _ in nil }

    // 防止 controlTextDidEndEditing 被递归调用
    private var isHandlingEnd = false

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        focusRingType = .none
        font = .systemFont(ofSize: NSFont.systemFontSize)
        controlSize = .small
        translatesAutoresizingMaskIntoConstraints = false
        delegate = self
    }

    // MARK: - 开始编辑

    /// 聚焦并设置初始文本，可选择性地只选中文件名主干（不含扩展名）。
    ///
    /// 对标 VSCode `renderInputBox()` 中：
    /// `inputBox.select({ start: 0, end: lastDot > 0 && !stat.isDirectory ? lastDot : value.length })`
    /// 以及 Zed `rename_impl` 中 `editor.select(0..stem_len, cx)`。
    func beginEditing(initialText: String, selectStem: Bool) {
        stringValue = initialText
        window?.makeFirstResponder(self)
        guard selectStem, let fieldEditor = currentEditor() as? NSTextView else { return }
        let stemEnd: Int
        if let dotRange = initialText.range(of: ".", options: .backwards),
           !initialText.hasPrefix(".") {
            stemEnd = initialText.distance(from: initialText.startIndex, to: dotRange.lowerBound)
        } else {
            stemEnd = initialText.utf16.count
        }
        fieldEditor.selectedRange = NSRange(location: 0, length: stemEnd)
    }

    // MARK: - 键盘处理

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return
            attemptCommit()
        case 53: // Escape
            onCancel()
        default:
            super.keyDown(with: event)
        }
    }

    private func attemptCommit() {
        let text = stringValue.trimmingCharacters(in: .whitespaces)
        if let error = onValidate(text) {
            showValidationError(error.localizedDescription ?? error.errorDescription ?? "")
        } else {
            hideValidationError()
            onCommit(text)
        }
    }

    // MARK: - 行内校验错误提示

    private var errorLabel: NSTextField?

    private func showValidationError(_ message: String) {
        if errorLabel == nil {
            let label = NSTextField(labelWithString: "")
            label.textColor = .systemRed
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.translatesAutoresizingMaskIntoConstraints = false
            superview?.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: bottomAnchor, constant: 2),
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: superview!.trailingAnchor, constant: -4),
            ])
            errorLabel = label
        }
        errorLabel?.stringValue = message
        errorLabel?.isHidden = false
    }

    private func hideValidationError() {
        errorLabel?.isHidden = true
    }
}

// MARK: - NSTextFieldDelegate

extension FileTreeInlineTextField: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        let text = (obj.object as? NSTextField)?.stringValue ?? ""
        if let error = onValidate(text) {
            showValidationError(error.localizedDescription ?? error.errorDescription ?? "")
        } else {
            hideValidationError()
        }
    }

    /// 失焦时行为（对标 VSCode `done(inputBox.isInputValid(), true)` / Zed `confirm_edit(false, cx)`）：
    /// - 文本合法 → 提交
    /// - 文本非法（空或校验失败）→ 取消
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isHandlingEnd else { return }
        isHandlingEnd = true
        defer { isHandlingEnd = false }

        let text = stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, onValidate(text) == nil {
            onCommit(text)
        } else {
            onCancel()
        }
    }
}
```

### Step 2：确认编译通过

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

期望：`BUILD SUCCEEDED`，无编译错误。

### Step 3：提交

```
feat(ft-r8): add FileTreeInlineTextField with Return/Esc/blur handling
```

---

## Task 3：`FileTreeCellView` 编辑态渲染 + `FileTreeTableView` 新增回调

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`
- Modify: `agentGui/Views/FileTree/FileTreeCellView.swift`

目标：
1. `FileTreeTableView` 新增 `inlineEditSession: InlineEditSession?` prop 和五个回调（`onNewFile`、`onNewFolder`、`onRenameSelected`、`onCommitEdit`、`onCancelEdit`），并将其传递给 `Coordinator` 和每个 Cell。
2. `FileTreeCellView` 新增编辑态与正常态的切换：检测到 `entry.isEditPlaceholder` 或 `inlineEditSession?.targetEntryID == entry.id` 时，隐藏 nameLabel，显示 `FileTreeInlineTextField` 并聚焦。

对标：
- VSCode `FilesRenderer.renderElement()` 中 `if (editableData) { ... renderInputBox(...) }` 切换分支。
- Zed `render_entry()` 中 `show_editor = details.is_editing && !details.is_processing`，用 `filename_editor.view()` 代替 label。

### Step 1：修改 `FileTreeTableView` — 新增 props 和回调

在 `struct FileTreeTableView` 的 `// MARK: - 回调` 块中新增：

```swift
/// 当前内联编辑会话（nil = 非编辑态）。传入 Cell 决定渲染模式。
var inlineEditSession: InlineEditSession? = nil

/// 用户在内联文本框按 Return（或失焦时草稿合法）→ 携带已 trim 的草稿名称。
var onCommitEdit: (String) -> Void = { _ in }

/// 用户按 Escape 或失焦时草稿为空/非法 → 取消。
var onCancelEdit: () -> Void = {}

/// Cmd+N — 新建文件。
var onNewFile: () -> Void = {}

/// Cmd+Shift+N — 新建文件夹。
var onNewFolder: () -> Void = {}

/// Return（非编辑态，已选中一个条目）→ 重命名。
var onRenameSelected: () -> Void = {}
```

在 `makeNSView` 中，将 `NSTableView()` 替换为 `FileTreeKeyboardTableView()`（见 Task 5 Step 1）；在 `updateNSView` 中同步所有新 props 到 Coordinator。

### Step 2：修改 `FileTreeCellView` — 编辑态切换

在 Cell 的 `configure(entry:...)` 方法中增加编辑态逻辑（在正常渲染之后）：

```swift
// 编辑态检测（对标 VSCode renderElement → getEditableData 分支）
let isEditing = entry.isEditPlaceholder
    || (inlineEditSession?.targetEntryID == entry.id)

if isEditing {
    nameLabel.isHidden = true
    inlineTextField.isHidden = false
    inlineTextField.onCommit = onCommitEdit
    inlineTextField.onCancel = onCancelEdit
    inlineTextField.onValidate = onValidate

    // 重命名填当前文件名；新建留空（对标 VSCode renderInputBox 初始 value 逻辑）
    let initialText = (inlineEditSession?.targetEntryID != nil) ? entry.name : ""
    // 文件选主干，目录选全名（对标 VSCode lastDot > 0 && !stat.isDirectory 分支）
    inlineTextField.beginEditing(initialText: initialText, selectStem: !entry.isDirectory)
} else {
    nameLabel.isHidden = false
    inlineTextField.isHidden = true
}
```

同时在 Cell 初始化时，创建 `FileTreeInlineTextField` 并添加到视图层级（隐藏状态）：

```swift
private let inlineTextField = FileTreeInlineTextField(frame: .zero)

// 在 setupViews() 中：
inlineTextField.isHidden = true
addSubview(inlineTextField)
// 布局与 nameLabel 相同位置（覆盖）
```

### Step 3：确认编译通过

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

期望：`BUILD SUCCEEDED`。

### Step 4：提交

```
feat(ft-r8): FileTreeCellView switches to inline text field when editing
```

---

## Task 4：`FileTreeViewModel` 内联编辑操作 + `FileTreeStore` 调整

**Files:**
- Modify: `agentGui/Services/FileTreeStore.swift`
- Modify: `agentGui/ViewModels/FileTreeViewModel.swift`
- Modify: `agentGuiTests/FileTreeInlineEditTests.swift`（追加 5 个测试）

这是 FT-R8 的核心逻辑层。目标：
1. `FileTreeStore` 改动：`refreshDirectory` 从 `private` → `internal`；新增 `siblingNames(of:) -> [String]`；暴露 `currentRootURL: URL?` 计算属性。
2. `FileTreeViewModel` 新增：`rootDirectory: URL?`、`inlineEdit: InlineEditSession?`、`validationError: EditValidationError?`，以及五个操作方法。

### Step 1：编写预期失败的测试（追加到 `FileTreeInlineEditTests.swift`）

```swift
// MARK: - FileTreeViewModel 集成测试（末尾追加到 FileTreeInlineEditTests）

extension FileTreeInlineEditTests {

    // MARK: 辅助

    /// 快速构造 VisibleEntry（非占位行）
    func entry(name: String, depth: Int = 0, isDirectory: Bool = false,
               urlPath: String? = nil) -> VisibleEntry {
        let path = urlPath ?? "/tmp/\(name)"
        return VisibleEntry(
            id: EntryID(url: URL(fileURLWithPath: path)),
            name: name,
            isDirectory: isDirectory,
            depth: depth,
            isExpanded: false,
            loadState: .loaded,
            foldedAncestors: nil,
            gitSummary: nil,
            diagnosticSeverity: nil,
            isIgnored: false,
            isEditPlaceholder: false
        )
    }

    // MARK: - beginCreate / cancelEdit

    /// beginCreate 应在 visibleEntries 中插入占位行，并设置 inlineEdit。
    @MainActor
    func testBeginCreate_insertsPlaceholder() async {
        let vm = FileTreeViewModel()
        let srcEntry = entry(name: "src", isDirectory: true)
        let mainEntry = entry(name: "main.swift")
        vm.visibleEntries = [srcEntry, mainEntry]

        await vm.beginCreate(.createFile, near: mainEntry.id)

        XCTAssertNotNil(vm.inlineEdit)
        XCTAssertEqual(vm.inlineEdit?.kind, .createFile)
        let placeholder = vm.visibleEntries.first(where: { $0.isEditPlaceholder })
        XCTAssertNotNil(placeholder, "应插入占位行")
        XCTAssertEqual(vm.visibleEntries.count, 3, "原 2 条目 + 1 占位行 = 3")
    }

    /// cancelEdit 应移除占位行并清空 inlineEdit。
    @MainActor
    func testCancelEdit_removesPlaceholder() async {
        let vm = FileTreeViewModel()
        let srcEntry = entry(name: "src", isDirectory: true)
        vm.visibleEntries = [srcEntry]

        await vm.beginCreate(.createFile, near: srcEntry.id)
        XCTAssertEqual(vm.visibleEntries.count, 2)

        vm.cancelEdit()

        XCTAssertNil(vm.inlineEdit)
        XCTAssertFalse(vm.visibleEntries.contains(where: { $0.isEditPlaceholder }),
                       "cancelEdit 后应移除占位行")
        XCTAssertEqual(vm.visibleEntries.count, 1)
    }

    // MARK: - beginRename

    /// beginRename 设置 inlineEdit（kind=.rename，targetEntryID 非 nil），不插入占位行。
    @MainActor
    func testBeginRename_showsCurrentName() async {
        let vm = FileTreeViewModel()
        let mainEntry = entry(name: "main.swift")
        vm.visibleEntries = [mainEntry]

        await vm.beginRename(mainEntry.id)

        XCTAssertNotNil(vm.inlineEdit)
        XCTAssertEqual(vm.inlineEdit?.kind, .rename)
        XCTAssertEqual(vm.inlineEdit?.targetEntryID, mainEntry.id)
        XCTAssertEqual(vm.inlineEdit?.draftName, "main.swift")
        XCTAssertFalse(vm.visibleEntries.contains(where: { $0.isEditPlaceholder }),
                       "重命名不插入占位行")
        XCTAssertEqual(vm.visibleEntries.count, 1)
    }

    // MARK: - commitEdit 校验守卫

    /// commitEdit 空名时：不执行写磁盘，保留占位行，设 validationError。
    @MainActor
    func testCommitCreate_emptyName_showsError() async {
        let vm = FileTreeViewModel()
        let srcEntry = entry(name: "src", isDirectory: true)
        vm.visibleEntries = [srcEntry]

        await vm.beginCreate(.createFile, near: srcEntry.id)
        vm.inlineEdit?.draftName = ""

        await vm.commitEdit()

        XCTAssertNotNil(vm.inlineEdit, "空名时不提交，inlineEdit 保留")
        XCTAssertEqual(vm.validationError, .emptyName)
        XCTAssertTrue(vm.visibleEntries.contains(where: { $0.isEditPlaceholder }),
                      "占位行应保留")
    }

    // MARK: - 端到端：写磁盘

    /// commitEdit（新建文件）：文件写入临时目录，占位行消失，inlineEdit 清空。
    @MainActor
    func testCommitCreate_createsFileAndRefreshes() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let vm = FileTreeViewModel()
        await vm.setDirectory(tmpDir)
        try await Task.sleep(for: .milliseconds(300))

        let initialCount = vm.visibleEntries.count
        await vm.beginCreate(.createFile, near: nil)
        vm.inlineEdit?.draftName = "hello.txt"

        await vm.commitEdit()

        let newFile = tmpDir.appendingPathComponent("hello.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path), "hello.txt 应写入磁盘")
        XCTAssertNil(vm.inlineEdit)
        XCTAssertNil(vm.validationError)
        XCTAssertFalse(vm.visibleEntries.contains(where: { $0.isEditPlaceholder }))
        XCTAssertEqual(vm.visibleEntries.count, initialCount + 1)
    }

    /// commitEdit（重命名）：磁盘文件名更新，条目名称在 visibleEntries 中变更。
    @MainActor
    func testCommitRename_renamesAndRefreshes() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let originalFile = tmpDir.appendingPathComponent("old.txt")
        FileManager.default.createFile(atPath: originalFile.path, contents: nil)

        let vm = FileTreeViewModel()
        await vm.setDirectory(tmpDir)
        try await Task.sleep(for: .milliseconds(300))

        guard let oldEntry = vm.visibleEntries.first(where: { $0.name == "old.txt" }) else {
            XCTFail("应能找到 old.txt 条目"); return
        }

        await vm.beginRename(oldEntry.id)
        vm.inlineEdit?.draftName = "new.txt"
        await vm.commitEdit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalFile.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("new.txt").path))
        XCTAssertNil(vm.inlineEdit)
        XCTAssertFalse(vm.visibleEntries.contains(where: { $0.name == "old.txt" }))
        XCTAssertTrue(vm.visibleEntries.contains(where: { $0.name == "new.txt" }))
    }
}
```

### Step 2：运行测试（应失败）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeInlineEditTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed"
```

期望：编译错误（`FileTreeViewModel.beginCreate/beginRename/commitEdit/cancelEdit/inlineEdit/validationError` 未定义）。

### Step 3：修改 `FileTreeStore` — 暴露三个 API

**修改** `agentGui/Services/FileTreeStore.swift`：

1. `private func refreshDirectory(_ url: URL) async` → 去掉 `private`，改为 `func refreshDirectory(_ url: URL) async`（注释中说明调用方为 `FileTreeViewModel.commitEdit()`）。

2. 在适当位置（例如 `// MARK: - 公开访问` 区段）新增：

```swift
/// 父目录的直接子条目名称列表（用于内联编辑重复名检测）。
/// 对标 Zed `populate_validation_error` 中的 `already_exists` 检测数据来源。
func siblingNames(of parentID: EntryID) -> [String] {
    (children[parentID] ?? []).compactMap { entries[$0]?.name }
}

/// 当前根目录 URL（供 `FileTreeViewModel.beginCreate(near:nil)` 使用）。
var currentRootURL: URL? { rootURL }
```

### Step 4：修改 `FileTreeViewModel` — 实现内联编辑操作

**修改** `agentGui/ViewModels/FileTreeViewModel.swift`：

1. 在初始化区段新增存储属性：

```swift
// MARK: - 内联编辑（FT-R8）

/// 当前根目录（setDirectory 时更新，供 beginCreate 回退到根插入位置使用）。
private(set) var rootDirectory: URL? = nil

/// 当前内联编辑会话（nil = 非编辑态）。
/// 对标 Zed `ProjectPanel.edit_state: Option<EditState>`（project_panel.rs）。
var inlineEdit: InlineEditSession? = nil

/// 最近一次实时校验错误（供 FileTreeCellView 读取以高亮显示）。
var validationError: EditValidationError? = nil
```

2. 在 `setDirectory(_ url: URL?)` 中，于 `await store.setRoot(url)` 之前加：

```swift
rootDirectory = url
```

3. 在 `// MARK: - Auto-fold（FT-R5）` 之后新增区段：

```swift
// MARK: - 内联编辑：开始

/// 开始新建文件 / 新建文件夹，在 selectedID 之后插入占位行。
///
/// 插入位置规则（对标 Zed `add_entry(is_dir, cx)` 的 parent directory 确定逻辑）：
/// - 选中已展开目录：新建在其第一子条目之前（depth + 1，parentID = selectedID）
/// - 选中文件或折叠目录：新建在其之后（同 depth，parentID = 父目录）
/// - 无选中：插入末尾，parentID = root
///
/// - Parameters:
///   - kind:       `.createFile` 或 `.createFolder`，不传 `.rename`
///   - selectedID: 参考条目 ID（可为 nil）
func beginCreate(_ kind: InlineEditSession.Kind, near selectedID: EntryID?) async {
    guard kind == .createFile || kind == .createFolder else { return }
    cancelEdit()  // 先取消已有会话

    let (parentID, insertIndex, depth) = computeInsertPosition(near: selectedID)

    let session = InlineEditSession(
        kind: kind,
        parentDirectoryID: parentID,
        targetEntryID: nil,
        placeholderIndex: insertIndex,
        draftName: ""
    )
    let placeholder = VisibleEntry.placeholder(depth: depth, parentID: parentID)
    visibleEntries.insert(placeholder, at: insertIndex)
    inlineEdit = session
    validationError = nil
}

/// 开始重命名指定条目（不插入占位行，直接切换 Cell 渲染）。
///
/// 对标 Zed `rename_impl(selection, cx)`：设 `leaf_entry_id = Some(entry_id)`,
/// editor text = `file_name`（当前文件名作为 draftName 初始值）。
func beginRename(_ id: EntryID) async {
    cancelEdit()
    guard let targetEntry = visibleEntries.first(where: { $0.id == id }) else { return }

    let parentURL = id.url.deletingLastPathComponent()
    let parentID = EntryID(url: parentURL.standardizedFileURL)

    inlineEdit = InlineEditSession(
        kind: .rename,
        parentDirectoryID: parentID,
        targetEntryID: id,
        placeholderIndex: -1,   // 重命名无占位行
        draftName: targetEntry.name
    )
    validationError = nil
}

// MARK: - 内联编辑：提交 / 取消

/// 提交当前编辑会话。
///
/// 流程（对标 Zed `confirm_edit(refocus, cx)`）：
/// 1. 校验 draftName → 失败则 validationError，early return（占位行保留）
/// 2. 调 WorkspaceFileTreeOperations 写磁盘
/// 3. store.refreshDirectory(parentURL) 刷新 actor 状态
/// 4. visibleEntries = await store.computeVisibleEntries()
/// 5. inlineEdit = nil
func commitEdit() async {
    guard let session = inlineEdit else { return }
    let draft = session.draftName.trimmingCharacters(in: .whitespaces)

    // 校验（对标 Zed `populate_validation_error` 最终守卫）
    let siblings = await store.siblingNames(of: session.parentDirectoryID)
    if let error = session.validateDraftName(siblingNames: siblings) {
        validationError = error
        return
    }
    validationError = nil

    let parentURL = session.parentDirectoryID.url
    do {
        switch session.kind {
        case .createFile:
            _ = try WorkspaceFileTreeOperations.createFile(named: draft, in: parentURL)
        case .createFolder:
            _ = try WorkspaceFileTreeOperations.createDirectory(named: draft, in: parentURL)
        case .rename:
            guard let targetURL = session.targetEntryID?.url else { return }
            _ = try WorkspaceFileTreeOperations.renameItem(at: targetURL, to: draft)
        }
    } catch {
        validationError = .duplicateName(draft)  // 写入失败，展示错误
        return
    }

    // 刷新（对标 Zed `update_visible_entries` 在 confirm_edit 结束后调用）
    await store.refreshDirectory(parentURL)
    visibleEntries = await store.computeVisibleEntries()
    inlineEdit = nil
}

/// 取消当前编辑会话，移除占位行，清空状态。
///
/// 对标 Zed `discard_edit_state(cx)`：`edit_state.take()` 后 `update_visible_entries`。
func cancelEdit() {
    guard let session = inlineEdit else { return }
    if session.isNewEntry {
        visibleEntries.removeAll(where: { $0.id == .placeholderSentinel })
    }
    inlineEdit = nil
    validationError = nil
}

// MARK: - 内部辅助

/// 根据选中条目计算占位行的插入位置、父目录 ID 和缩进深度。
private func computeInsertPosition(
    near selectedID: EntryID?
) -> (parentID: EntryID, index: Int, depth: Int) {
    guard let selectedID,
          let idx = visibleEntries.firstIndex(where: { $0.id == selectedID })
    else {
        // 无选中：插入末尾，父目录 = root
        let rootURL = rootDirectory ?? URL(fileURLWithPath: "/")
        return (EntryID(url: rootURL.standardizedFileURL),
                visibleEntries.endIndex, 0)
    }
    let selected = visibleEntries[idx]
    if selected.isDirectory && selected.isExpanded {
        // 展开目录：子级插入（depth + 1，parentID = selected.id）
        return (selected.id, idx + 1, selected.depth + 1)
    } else {
        // 文件或折叠目录：同级插入（parentID = 其父目录）
        let parentURL = selected.id.url.deletingLastPathComponent()
        let parentID = EntryID(url: parentURL.standardizedFileURL)
        return (parentID, idx + 1, selected.depth)
    }
}
```

### Step 5：运行测试（应通过）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeInlineEditTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed"
```

期望：14 个测试（9 个 Task 1 + 5 个 Task 4）全部通过。

### Step 6：提交

```
feat(ft-r8): FileTreeViewModel inline edit ops (beginCreate/beginRename/commitEdit/cancelEdit)
```

---

## Task 5：键盘触发 + 集成 + 删除旧代码

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`（新增 `FileTreeKeyboardTableView` 子类）
- Modify: `agentGui/Views/FileTree/FileTreeContainerView.swift`（绑定回调）
- Delete: ⚠️ **需用户确认** `agentGui/Views/WorkspaceTree/WorkspaceTreeInlineEdit.swift`

目标：
1. `FileTreeKeyboardTableView: NSTableView` — 覆盖 `keyDown(with:)` 分发 `Cmd+N`、`Cmd+Shift+N`、`Return`（非编辑态）、`Esc`（编辑态）。
2. `FileTreeContainerView` 将 ViewModel 方法绑定到 TableView 回调（单向数据流，ViewModel 持有真相）。
3. 确认 `WorkspaceTreeViewModel` 等调用方不再引用 `WorkspaceTreeInlineEdit`，然后删除该文件。
4. 运行全量集成测试确认无回归。

### Step 1：创建 `FileTreeKeyboardTableView` 子类

在 `agentGui/Views/FileTree/FileTreeTableView.swift` 末尾新增（或独立新建 `FileTreeKeyboardTableView.swift`）：

```swift
/// NSTableView 子类，负责将 Cmd+N / Cmd+Shift+N / Return / Esc 键盘事件
/// 分发给 `FileTreeTableView` 的回调，而非走系统默认响应链。
///
/// 对标 VSCode `WorkbenchCompressibleAsyncDataTree` 中注册的 `KeyCode.Enter/Escape`
/// 键盘事件（由 `ExplorerView._onKeyDown` 处理）。
final class FileTreeKeyboardTableView: NSTableView {

    var onNewFile: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onRenameSelected: (() -> Void)?
    var onCancelEdit: (() -> Void)?

    /// 当前是否处于编辑态（由 Coordinator 在 updateNSView 时同步）。
    var isInlineEditing: Bool = false

    override func keyDown(with event: NSEvent) {
        let cmd   = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        switch (event.keyCode, cmd, shift, isInlineEditing) {
        case (45, true, false, false):  // Cmd+N — 新建文件
            onNewFile?()
        case (45, true, true,  false):  // Cmd+Shift+N — 新建文件夹
            onNewFolder?()
        case (36, false, false, false): // Return（非编辑态）— 重命名
            onRenameSelected?()
        case (53, _, _, true):          // Esc（编辑态）— 保险回退（优先由 TextField 拦截）
            onCancelEdit?()
        default:
            super.keyDown(with: event)
        }
    }
}
```

在 `FileTreeTableView.makeNSView` 中将 `let tableView = NSTableView()` 替换为：

```swift
let tableView = FileTreeKeyboardTableView()
context.coordinator.keyboardTableView = tableView
```

在 `Coordinator` 中新增 `weak var keyboardTableView: FileTreeKeyboardTableView?`，并在 `updateNSView` 中同步各回调和 `isInlineEditing = inlineEditSession != nil`。

### Step 2：`FileTreeContainerView` 绑定回调

在 `FileTreeContainerView.swift` 的 `FileTreeTableView(...)` 构造处追加：

```swift
.onNewFile {
    Task { await vm.beginCreate(.createFile, near: vm.selection.primary) }
}
.onNewFolder {
    Task { await vm.beginCreate(.createFolder, near: vm.selection.primary) }
}
.onRenameSelected {
    guard let primary = vm.selection.primary else { return }
    Task { await vm.beginRename(primary) }
}
.onCommitEdit { draft in
    Task {
        vm.inlineEdit?.draftName = draft
        await vm.commitEdit()
    }
}
.onCancelEdit {
    vm.cancelEdit()
}
```

（如 `FileTreeTableView` 使用链式 `.modifier` 风格，需在 `FileTreeTableView` 中添加对应的 `func onNewFile(_ action: @escaping () -> Void) -> Self` 等链式方法。）

### Step 3：全量编译 + 测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|Test Suite.*passed|failed"
```

期望：全部已有测试 + 14 个 FT-R8 测试均通过，无编译错误。

### Step 4：⚠️ 删除旧实现（需用户确认后执行）

先检查引用：

```bash
grep -r "WorkspaceTreeInlineEdit\|WorkspaceTreeInlineEditApplier" \
  agentGui/ --include="*.swift"
```

若无引用，**在获得用户确认后**删除：

```bash
rm agentGui/Views/WorkspaceTree/WorkspaceTreeInlineEdit.swift
```

然后再次构建确认无编译错误。

### Step 5：最终回归测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FileTreeInlineEditTests \
  -only-testing:agentGuiTests/FileTreeAutoFoldTests \
  -only-testing:agentGuiTests/FileTreeDiffUpdateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|passed|failed"
```

期望：全部通过。

### Step 6：提交

```
feat(ft-r8): wire keyboard shortcuts, bind callbacks, delete WorkspaceTreeInlineEdit

- FileTreeKeyboardTableView handles Cmd+N / Cmd+Shift+N / Return / Esc
- FileTreeContainerView binds all inline edit callbacks to FileTreeViewModel
- Remove WorkspaceTreeInlineEdit + WorkspaceTreeInlineEditApplier (replaced)
```

---

## 估计行数

| 文件 | 变更类型 | 估计 LoC |
|------|---------|---------|
| `agentGui/Models/InlineEditSession.swift` | 新建 | ~80 |
| `agentGui/Models/VisibleEntry.swift` | 修改（+25 行） | ~25 |
| `agentGui/Views/FileTree/FileTreeInlineTextField.swift` | 新建 | ~90 |
| `agentGui/ViewModels/FileTreeViewModel.swift` | 修改（+~110 行） | ~110 |
| `agentGui/Services/FileTreeStore.swift` | 修改（去 `private` + `siblingNames` + `currentRootURL`，+~15 行） | ~15 |
| `agentGui/Views/FileTree/FileTreeTableView.swift` | 修改（+`FileTreeKeyboardTableView` + 新回调，+~60 行） | ~60 |
| `agentGui/Views/FileTree/FileTreeCellView.swift` | 修改（编辑态切换，+~30 行） | ~30 |
| `agentGui/Views/FileTree/FileTreeContainerView.swift` | 修改（绑定回调，+~20 行） | ~20 |
| `agentGui/Views/WorkspaceTree/WorkspaceTreeInlineEdit.swift` | 删除 | −112 |
| `agentGuiTests/FileTreeInlineEditTests.swift` | 新建 | ~200 |
| **净增合计** | | **~518 行** |
