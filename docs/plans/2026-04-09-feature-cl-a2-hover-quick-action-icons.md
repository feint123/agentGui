# CL-A2 行级 Hover 快捷操作图标 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把变更列表（GitSidebarChangesSection）每行的常驻文字按钮改为 hover 时才出现的图标，非 hover 状态仅显示状态徽章，大幅减少 UI 视觉噪音。

**Architecture:** 提取 `changeRow` 函数为独立 `ChangeRowView` struct，在 struct 内用 `@State private var isHovered` 管理每行各自的悬停状态；同时为 `GitChangeStatus` 和 `GitChangeSection` 增加两个纯计算属性用于展示数据（`statusBadgeText` / `hoverActionSymbol`），以便单独单元测试。整个改动**仅影响视图层**，不触碰 ViewModel 或 Service。

**Tech Stack:** Swift 6, SwiftUI (macOS), XCTest

**参考来源：** `git4idea/index/ui/GitStageTree.kt` → `createHoverIcon()` / `HoverIcon`；IDEA 悬停图标映射：staged → `GitResetOperation`（minus），unstaged/untracked → `GitAddOperation`（plus）。

---

## 当前状态速查

| 文件 | 现状 |
|---|---|
| `agentGui/Views/Git/GitSidebarChangesSection.swift` | `changeRow` 是私有函数；行下方常驻 HStack 含文字按钮 |
| `agentGui/Models/GitRepositorySnapshot.swift` | `GitChangeStatus` / `GitChangeSection` 均无 badge/icon 属性 |
| `agentGuiTests/GitSidebarViewModelSelectionTests.swift` | CL-A1 测试，无 hover 相关测试 |

**目标行为：**

```
非 hover：  [relativePath]  ....  [M]
hover    ：  [relativePath]  ....  [🗑 trash]  [−]   ← unstaged 示例
             [relativePath]  ....              [−]   ← staged 示例
             [relativePath]  ....              [+]   ← untracked 示例
```

---

## Task 1：`GitChangeStatus.statusBadgeText`

**Files:**
- Modify: `agentGui/Models/GitRepositorySnapshot.swift`
- Test: `agentGuiTests/GitChangeBadgeDisplayTests.swift` (新建)

### Step 1：新建测试文件，写失败测试

```swift
// agentGuiTests/GitChangeBadgeDisplayTests.swift
import XCTest
@testable import agentGui

final class GitChangeBadgeDisplayTests: XCTestCase {

    func test_statusBadgeText_modified() {
        XCTAssertEqual(GitChangeStatus.modified.statusBadgeText, "M")
    }

    func test_statusBadgeText_added() {
        XCTAssertEqual(GitChangeStatus.added.statusBadgeText, "A")
    }

    func test_statusBadgeText_deleted() {
        XCTAssertEqual(GitChangeStatus.deleted.statusBadgeText, "D")
    }

    func test_statusBadgeText_renamed() {
        XCTAssertEqual(GitChangeStatus.renamed.statusBadgeText, "R")
    }

    func test_statusBadgeText_untracked() {
        XCTAssertEqual(GitChangeStatus.untracked.statusBadgeText, "??")
    }
}
```

### Step 2：运行，确认编译报错（属性不存在）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/GitChangeBadgeDisplayTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败，`value of type 'GitChangeStatus' has no member 'statusBadgeText'`

### Step 3：实现属性（最小代码）

在 `agentGui/Models/GitRepositorySnapshot.swift` 的 `enum GitChangeStatus` 中新增：

```swift
enum GitChangeStatus: String, Codable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case untracked

    /// 非 hover 状态下行尾显示的短标识（参照 IDEA GitStageTree 节点图标文字）。
    var statusBadgeText: String {
        switch self {
        case .added:     return "A"
        case .modified:  return "M"
        case .deleted:   return "D"
        case .renamed:   return "R"
        case .untracked: return "??"
        }
    }
}
```

### Step 4：运行测试，确认全部通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/GitChangeBadgeDisplayTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：5 个测试全部 PASS

### Step 5：提交

```bash
git add agentGui/Models/GitRepositorySnapshot.swift \
        agentGuiTests/GitChangeBadgeDisplayTests.swift
git commit -m "feat(cl-a2): add GitChangeStatus.statusBadgeText"
```

---

## Task 2：`GitChangeSection.hoverActionSymbol`

**Files:**
- Modify: `agentGui/Models/GitRepositorySnapshot.swift`
- Test: `agentGuiTests/GitChangeBadgeDisplayTests.swift` (追加测试)

### Step 1：追加测试

```swift
// 追加到 GitChangeBadgeDisplayTests 末尾
func test_hoverActionSymbol_staged() {
    XCTAssertEqual(GitChangeSection.staged.hoverActionSymbol, "minus.circle")
}

func test_hoverActionSymbol_modified() {
    XCTAssertEqual(GitChangeSection.modified.hoverActionSymbol, "plus.circle")
}

func test_hoverActionSymbol_untracked() {
    XCTAssertEqual(GitChangeSection.untracked.hoverActionSymbol, "plus.circle")
}
```

### Step 2：运行，确认编译报错

预期：`value of type 'GitChangeSection' has no member 'hoverActionSymbol'`

### Step 3：实现属性

```swift
enum GitChangeSection: String, Codable, Equatable {
    case staged
    case modified
    case untracked

    /// hover 时行尾主操作按钮使用的 SF Symbol名称。
    /// staged → 取消暂存（minus.circle）; modified/untracked → 暂存（plus.circle）
    var hoverActionSymbol: String {
        switch self {
        case .staged:    return "minus.circle"
        case .modified:  return "plus.circle"
        case .untracked: return "plus.circle"
        }
    }
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/GitChangeBadgeDisplayTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：8 个测试全部 PASS（含 Task 1 的 5 个）

### Step 5：提交

```bash
git add agentGui/Models/GitRepositorySnapshot.swift \
        agentGuiTests/GitChangeBadgeDisplayTests.swift
git commit -m "feat(cl-a2): add GitChangeSection.hoverActionSymbol"
```

---

## Task 3：提取 `ChangeRowView` Struct

**Files:**
- Modify: `agentGui/Views/Git/GitSidebarChangesSection.swift`

> **背景：** 当前 `changeRow` 是私有函数（non-struct），无法拥有 `@State`。要实现每行独立 hover 状态，必须提取为独立 View struct。

### Step 1：阅读现有 `changeRow` 实现

完整定位：`GitSidebarChangesSection.swift` → `private func changeRow(...)`.  
确认当前签名：`change / primaryActionTitle / primaryAction / secondaryActionTitle? / secondaryAction?`。

### Step 2：在文件末尾添加 `ChangeRowView`（不删除旧代码）

```swift
// MARK: - ChangeRowView
/// 单个文件变更行：非 hover 时仅显示状态徽章；hover 时显示快捷操作图标。
private struct ChangeRowView: View {
    let change: GitFileChange
    let isSelected: Bool
    /// SF Symbol 名称，主操作按钮（stage / unstage）。
    let primarySymbol: String
    let primaryAction: () -> Void
    /// 仅 unstaged 区传入（丢弃）；默认 nil。
    var discardAction: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(change.relativePath)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered {
                hoverIcons
            } else {
                Text(change.status.statusBadgeText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            // 行点击逻辑由外部 changeGroup 处理（CL-A1 已实现）
        }
    }

    @ViewBuilder
    private var hoverIcons: some View {
        HStack(spacing: 4) {
            if let discardAction {
                Button(action: discardAction) {
                    Image(systemName: "trash")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("丢弃更改")
            }
            Button(action: primaryAction) {
                Image(systemName: primarySymbol)
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .help(change.section == .staged ? "取消暂存" : "暂存")
        }
    }
}
```

> **注意：** `onTapGesture` 行选中已在 `changeGroup` 里通过包裹层处理（见 Task 4），此处留空占位即可。

### Step 3：构建验证（不运行测试）

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`（旧 `changeRow` 函数尚未删除，不影响构建）

### Step 4：提交（暂存新 struct，保留旧代码）

```bash
git add agentGui/Views/Git/GitSidebarChangesSection.swift
git commit -m "feat(cl-a2): add ChangeRowView struct with hover state"
```

---

## Task 4：更新 `changeGroup` 使用 `ChangeRowView`

**Files:**
- Modify: `agentGui/Views/Git/GitSidebarChangesSection.swift`

> 本 Task 把 `changeGroup` 里的 `changeRow(...)` 调用换成 `ChangeRowView`，并删除旧 `changeRow` 函数。

### Step 1：修改 `changeGroup` 函数体

现有 `changeGroup` 内的 `ForEach` 区块：

```swift
ForEach(changes) { change in
    changeRow(
        change: change,
        primaryActionTitle: primaryActionTitle,
        primaryAction: primaryAction,
        secondaryActionTitle: secondaryActionTitle,
        secondaryAction: secondaryAction
    )
}
```

替换为：

```swift
ForEach(changes) { change in
    ChangeRowView(
        change: change,
        isSelected: sidebarViewModel.selectedChangeID == change.id,
        primarySymbol: change.section.hoverActionSymbol,
        primaryAction: { primaryAction(change) },
        discardAction: secondaryAction.map { action in { action(change) } }
    )
    .onTapGesture {
        Task {
            await sidebarViewModel.selectChange(change, workspaceState: workspaceState)
        }
    }
}
```

> **为什么要在外层加 `.onTapGesture`：** `ChangeRowView` 内的 `contentShape` 已覆盖整行区域，但 `onTapGesture` 在外层可以访问 `sidebarViewModel` 和 `workspaceState`，避免把它们传入 ChangeRowView（减少耦合）。SwiftUI 的事件冒泡会优先触发内层 gesture；此处内层 `onTapGesture` 留空，外层实际执行选中逻辑。

### Step 2：同步删除旧 `changeGroup` 签名中不再需要的参数

`changeGroup` 当前签名含 `primaryActionTitle` 和 `secondaryActionTitle`（文字），这两个参数在新实现中不再使用 UI 显示。保留参数签名（兼容调用处），但在函数体中删除对它们的使用；后续若希望用于 `.help()` tooltip 可以再引入。

### Step 3：删除旧 `private func changeRow(...)` 函数

删除从 `private func changeRow(` 开始到结束括号为止的全部代码块。

### Step 4：构建验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`，无编译错误

### Step 5：运行现有 Git 相关测试，确保无回归

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/GitSidebarViewModelSelectionTests \
  -only-testing:agentGuiTests/GitChangeBadgeDisplayTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有测试 PASS

### Step 6：提交

```bash
git add agentGui/Views/Git/GitSidebarChangesSection.swift
git commit -m "feat(cl-a2): replace changeRow with ChangeRowView, hover-triggered icons"
```

---

## Task 5：手动视觉验证 & 收尾

**Files:** 无代码改动

### Step 1：在 Xcode 启动 App，打开含变更的 Git 仓库

1. 打开侧边栏 → "Git" → "变更" 面板
2. 确认所有文件行**默认状态**：只显示路径 + 右侧状态徽章（M / A / D / R / ??），**没有**文字按钮

### Step 2：鼠标悬停验证

| 分区 | 预期图标 |
|---|---|
| 已暂存 | 右侧只出现 `minus.circle`（取消暂存） |
| 未暂存 | 右侧出现 `trash`（丢弃）+ `plus.circle`（暂存） |
| 未跟踪 | 右侧只出现 `plus.circle`（暂存） |

### Step 3：点击图标功能验证

- 点击 `plus.circle` → 文件移动到已暂存区
- 点击 `minus.circle` → 文件移回未暂存区
- 点击 `trash` → 弹出确认对话框（`confirmationDialog` 逻辑不变）

### Step 4：行点击选中 + Diff 预览（CL-A1 回归验证）

- 点击文件行（非图标区域）→ 行高亮，右侧 Diff 面板更新
- 键盘 ↑↓ 仍可在行间移动

### Step 5：提交 changelog commit

```bash
git add -A
git commit -m "feat(cl-a2): hover quick action icons complete"
```

---

## 文件改动总览

| 文件 | 操作 | 内容 |
|---|---|---|
| `agentGui/Models/GitRepositorySnapshot.swift` | 修改 | 增加 `GitChangeStatus.statusBadgeText`、`GitChangeSection.hoverActionSymbol` |
| `agentGui/Views/Git/GitSidebarChangesSection.swift` | 修改 | 提取 `ChangeRowView`，删除旧 `changeRow` 函数，更新 `changeGroup` |
| `agentGuiTests/GitChangeBadgeDisplayTests.swift` | 新建 | 8 个单元测试（badge text + hover symbol） |

---

## 设计决策记录（ADR）

| 决策 | 原因 |
|---|---|
| 提取 `ChangeRowView` 为 struct 而非保持函数 | SwiftUI 函数不能拥有 `@State`；每行独立 hover 状态必须在 struct 中 |
| `onTapGesture` 放在 `changeGroup` 外层（不放 `ChangeRowView` 内） | 避免将 `sidebarViewModel` 和 `workspaceState` 传递进 ChangeRowView，减少耦合 |
| `.trash` 图标只在 unstaged 区出现 | 丢弃操作不可逆，仅当 `discardAction != nil` 时渲染，与 IDEA 保持一致 |
| `withAnimation(.easeInOut(duration: 0.12))` | IDEA HoverIcon 有淡入效果；0.12s 足够快，不显拖沓 |
| 保留 `primaryActionTitle` / `secondaryActionTitle` 参数 | 兼容已有调用处；未来可用于 `.help()` tooltip |
| `statusBadgeText` 放 `GitChangeStatus`，`hoverActionSymbol` 放 `GitChangeSection` | badge 是文件当前状态（status），icon 是分区对应的操作（section），语义各自独立 |
