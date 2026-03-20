# Workspace Tree Outline Multiselect Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 用适合 macOS 树形文件浏览的原生控件替换当前层级 List，为 workspaceTree 交付稳定的多选、范围选择、键盘导航和批量操作能力。

**Architecture:** 保持现有 `WorkspacePanelView -> WorkspaceTreeViewModel -> WorkspaceTreeActionHandler / WorkspaceTreeRefreshCoordinator / WorkspaceFileTreeOperations` 的状态与业务分层，把控件能力下沉为一个独立的 `NSOutlineView` bridge 模块，而不是继续在 `WorkspacePanelView` 里用手势拼多选。选择同步通过 ViewModel 的显式接口收口，批量动作、拖拽与重命名继续复用现有业务层，避免 UI 自己维护第二套状态。

**Tech Stack:** Swift 6、SwiftUI、AppKit `NSOutlineView`、Foundation、Swift Testing。

---

## 1. 设计结论

- 我正在使用 writing-plans skill 来创建这份 implementation plan。
- 当前层级 `List(..., children:)` 在 SwiftUI 文档里只提供单选绑定；多选只能继续绕到手势层自己维护，无法给出 macOS 原生的树选择体验。
- `NSOutlineView` 原生提供树结构、多选、范围选择、键盘导航、拖拽和选择变更通知，更符合工作区文件树的交互模型。
- 本次不引入 UI 测试；只补 focused 单元测试，锁定选择同步与动作语义。

## 2. 文件范围

### 主要修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeViewModelTests.swift`

### 计划新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspaceTree/WorkspaceTreeOutlineView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspaceTree/WorkspaceTreeRowContent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspaceTree/WorkspaceTreeInlineEdit.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspaceTree/WorkspaceTreeContextMenu.swift`

## 3. 任务拆解

### Task 1: 固定选择同步契约

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`

**Step 1: 写失败测试**

为 ViewModel 新增原生树控件选择同步测试，至少覆盖：

- 原生多选把完整选区同步到 `selectedTreeNodeIDs`
- `primarySelectionID` 跟随 outline 当前主选中项
- 当主选中项是文件时更新 `workspaceState.selectedFile`
- 当主选中项是目录时，不错误清空已有编辑器打开文件

**Step 2: 运行 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests
```

Expected: FAIL，因为原生 outline selection sync 接口还不存在。

**Step 3: 写最小实现并重跑测试**

在 ViewModel 中新增显式 selection sync API，避免让 AppKit 视图直接改写多个离散属性。

### Task 2: 引入模块化 NSOutlineView bridge

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspaceTree/WorkspaceTreeOutlineView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspaceTree/WorkspaceTreeRowContent.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspaceTree/WorkspaceTreeInlineEdit.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspaceTree/WorkspaceTreeContextMenu.swift`

**Step 1: 搭好 outline bridge 分层**

模块职责拆分如下：

- `WorkspaceTreeOutlineView`: `NSViewRepresentable`，负责 data source、delegate、selection、expand/collapse、拖拽与右键菜单桥接
- `WorkspaceTreeRowContent`: 单行 SwiftUI 内容，只负责视觉与 inline edit
- `WorkspaceTreeInlineEdit`: inline create / rename 模型与 AppKit text field bridge
- `WorkspaceTreeContextMenu`: 构造上下文菜单与批量动作路由

**Step 2: 保持业务层复用**

- 删除、重命名、拖拽、Finder 打开、复制相对路径仍然调用现有 ViewModel / service 方法
- 不在 outline bridge 内直接做文件系统操作
- 不把选中集合副本缓存在多个层级

### Task 3: 收口 WorkspacePanelView

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`

**Step 1: 把当前树区替换为独立模块**

- `WorkspacePanelView` 只负责组装环境对象与动作闭包
- 移除内联的树行、inline edit 和列表手势代码
- 保留上层工具栏、空态、错误提示和 LSP footer

**Step 2: focused 验证**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests \
  -only-testing:agentGuiTests/WorkspaceTreeActionHandlerTests \
  -only-testing:agentGuiTests/WorkspaceTreeDropCoordinatorTests \
  -only-testing:agentGuiTests/WorkspaceFileTreeOperationsTests \
  -only-testing:agentGuiTests/WorkspaceTreeSnapshotOpsTests
```

Expected: PASS。

## 4. 质量门槛

- 必须支持 `command` 多选和 `shift` 范围选中
- 必须保留右键、拖拽、重命名、批量删除、复制相对路径
- 禁止继续依赖 SwiftUI `List` 的自定义点击手势去模拟原生多选
- 禁止新增 UI 测试