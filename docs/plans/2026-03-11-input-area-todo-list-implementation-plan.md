# InputArea TodoList 内联卡片 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将当前会话的 TodoList 从 `WorkspacePanelView` 侧栏迁移到 `ChatView.inputArea` 上方，作为类似 `slashPopupCard` 的轻量浮层卡片展示，并建立与 slash / mention 输入辅助的一致优先级。

**Architecture:** 采用“先纯状态、后视图接线”的方式实现，避免一开始直接把显示逻辑堆进 `ChatView+InputArea`。先提炼一个纯 Swift 的 Todo 卡片展示模型和输入辅助优先级判断，再接入新的输入区卡片视图，最后从侧栏移除旧入口并补 UI 回归验证。Todo 数据来源保持不变，继续优先读取 `SessionTaskStateStore`，再回退到 `claudeService.sessionTodoLists`。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, XCTest UI Testing, existing `ChatView+InputArea`, `TodoItem`, `SessionTaskStateStore`, `TestLaunchOptions`.

---

## 1. 实施原则

- 我正在使用 writing-plans skill 来创建这份 implementation plan。
- 先建立可测试的纯状态模型，再接入 SwiftUI 视图，避免把显示优先级写死在大视图里。
- 不复用旧的侧栏 `DisclosureGroup` 交互；输入区 Todo 卡片是新的轻量浮层，不是把 `TodoListView` 生搬硬套过去。
- Todo 数据读取路径保持不变，不在本次引入新的持久化模型或新的工具协议。
- 输入区同一时刻只保留一个主辅助卡片，优先级固定为 `slash > mention > todo`。
- 侧栏旧 TodoList 展示必须删除，而不是隐藏。
- 每个任务完成后都提交一次小而明确的 commit。

## 2. 目标文件清单

### 主要新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatComposerTodoCardPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/InputAreaTodoCardView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerTodoCardPresentationTests.swift`

### 主要修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/TodoListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`

### 可能需要修改的测试支撑文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/InMemoryAppHarness.swift`

## 3. 关键设计决定

### 3.1 不直接在大视图里算一切

`ChatView+InputArea.swift` 已经承载 slash、mention、附件、上下文 chips、发送按钮和 drop 逻辑。Todo 卡片的显示条件、进度摘要、最大展示条数等逻辑不应继续叠加成一堆内联 `if`。应新增一个纯模型，例如：

```swift
struct ChatComposerTodoCardPresentation: Equatable {
    let title: String
    let progressText: String
    let visibleItems: [TodoItem]
    let hiddenCount: Int
    let isVisible: Bool
}
```

### 3.2 输入辅助优先级集中判断

不要在视图中通过多层 `if/else if` 隐式管理三类卡片的竞争关系。应抽出统一入口，例如：

```swift
enum ChatComposerAssistSurface {
    case slash
    case mention
    case todo(ChatComposerTodoCardPresentation)
    case none
}
```

然后由 `ChatView+InputArea` 根据当前状态选择唯一的 surface。

### 3.3 旧 TodoListView 不再作为主卡片

输入区 Todo 卡片需要新的尺寸和视觉约束，不应直接复用当前 `DisclosureGroup` 结构。可以复用行级渲染，但不保留旧折叠面板交互。

## 4. 任务拆解

### Task 1: 建立 Todo 卡片展示模型，固定摘要、可见项和隐藏项契约

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatComposerTodoCardPresentation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerTodoCardPresentationTests.swift`

**Step 1: 写失败测试，先钉死展示契约**

新增测试覆盖：

- 空 TodoItems 时 `isVisible == false`
- 有 TodoItems 时能生成 `progressText`，例如 `2/5`
- `in-progress` 项优先于 `pending` 和 `done`
- 超出最大展示数量时，`hiddenCount` 正确
- `done` / `cancelled` 项保留但弱化，不应被错误过滤掉

建议测试代码：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatComposerTodoCardPresentationTests {

    @Test func buildReturnsInvisiblePresentationForEmptyItems() async throws {
        let presentation = ChatComposerTodoCardPresentation.build(items: [], maxVisibleItems: 4)

        #expect(!presentation.isVisible)
        #expect(presentation.visibleItems.isEmpty)
        #expect(presentation.progressText == "0/0")
    }

    @Test func buildPrioritizesInProgressItemsAndTracksOverflow() async throws {
        let items = [
            TodoItem(id: "1", title: "done", status: .done),
            TodoItem(id: "2", title: "doing", status: .inProgress),
            TodoItem(id: "3", title: "pending", status: .pending),
            TodoItem(id: "4", title: "pending-2", status: .pending),
            TodoItem(id: "5", title: "done-2", status: .done)
        ]

        let presentation = ChatComposerTodoCardPresentation.build(items: items, maxVisibleItems: 3)

        #expect(presentation.isVisible)
        #expect(presentation.progressText == "2/5")
        #expect(presentation.visibleItems.map(\.title) == ["doing", "pending", "pending-2"])
        #expect(presentation.hiddenCount == 2)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests
```

Expected: FAIL，因为展示模型和对应测试文件还不存在。

**Step 3: 写最小实现**

在 `ChatComposerTodoCardPresentation.swift` 中新增最小实现：

```swift
import Foundation

struct ChatComposerTodoCardPresentation: Equatable {
    let title: String
    let progressText: String
    let visibleItems: [TodoItem]
    let hiddenCount: Int
    let isVisible: Bool

    static func build(items: [TodoItem], maxVisibleItems: Int = 4) -> ChatComposerTodoCardPresentation {
        let prioritized = items.sorted(by: Self.sortItems)
        let visibleItems = Array(prioritized.prefix(maxVisibleItems))
        let doneCount = items.filter { $0.status == .done }.count

        return .init(
            title: "任务列表",
            progressText: "\(doneCount)/\(items.count)",
            visibleItems: visibleItems,
            hiddenCount: max(0, items.count - visibleItems.count),
            isVisible: !items.isEmpty
        )
    }

    private static func sortItems(lhs: TodoItem, rhs: TodoItem) -> Bool {
        statusRank(lhs.status) < statusRank(rhs.status)
    }

    private static func statusRank(_ status: TodoStatus) -> Int {
        switch status {
        case .inProgress: return 0
        case .pending: return 1
        case .done: return 2
        case .cancelled: return 3
        }
    }
}
```

实现只解决展示排序和摘要，不提前做视图逻辑。

**Step 4: 运行测试确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChatComposerTodoCardPresentation.swift agentGuiTests/ChatComposerTodoCardPresentationTests.swift
git commit -m "feat: add composer todo card presentation model"
```

### Task 2: 在输入区接入 Todo 卡片，并集中管理 slash / mention / todo 的优先级

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/InputAreaTodoCardView.swift`

**Step 1: 写失败测试，先固定优先级和显示入口**

在 `agentGuiTests` 中新增或扩展对输入辅助 surface 的纯状态测试。推荐在 `ChatComposerTodoCardPresentationTests.swift` 内新增一个轻量辅助枚举测试，或新建 `ChatComposerAssistSurfaceTests.swift`。

测试覆盖：

- slash 激活时 surface 为 `.slash`
- mention 激活时 surface 为 `.mention`
- slash / mention 都不激活且有 Todo 时 surface 为 `.todo`
- 三者都不满足时 surface 为 `.none`

建议测试代码：

```swift
@Test func assistSurfacePrefersSlashOverTodo() async throws {
    let presentation = ChatComposerTodoCardPresentation.build(
        items: [TodoItem(id: "1", title: "doing", status: .inProgress)],
        maxVisibleItems: 4
    )

    let surface = ChatComposerAssistSurface.resolve(
        slashQuery: "brain",
        mentionQuery: nil,
        todoPresentation: presentation
    )

    #expect(surface == .slash)
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests
```

Expected: FAIL，因为优先级解析类型尚不存在。

**Step 3: 写最小实现**

在 `ChatView+InputArea.swift` 或配套纯模型文件中新增：

```swift
enum ChatComposerAssistSurface: Equatable {
    case slash
    case mention
    case todo
    case none

    static func resolve(
        slashQuery: String?,
        mentionQuery: String?,
        todoPresentation: ChatComposerTodoCardPresentation
    ) -> ChatComposerAssistSurface {
        if slashQuery != nil { return .slash }
        if mentionQuery != nil { return .mention }
        if todoPresentation.isVisible { return .todo }
        return .none
    }
}
```

在 `ChatView+InputArea.swift` 中把当前：

```swift
if slashQuery != nil {
    slashPopupCard
} else if mentionQuery != nil && !mentionCandidates.isEmpty {
    mentionPopupCard
}
```

调整为统一 surface 分发：

```swift
switch assistSurface {
case .slash:
    slashPopupCard
case .mention:
    mentionPopupCard
case .todo:
    todoPopupCard
case .none:
    EmptyView()
}
```

同时新增 `InputAreaTodoCardView.swift`，最小样式直接对齐 `slashPopupCard`：

```swift
import SwiftUI

struct InputAreaTodoCardView: View {
    let presentation: ChatComposerTodoCardPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.08)
            bodyContent
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 8, y: -2)
    }
}
```

视图内先只展示：标题、进度、前若干项、溢出文案，不做交互式编辑。

**Step 4: 运行 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests -only-testing:agentGuiTests/ChatComposerSlashStateTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/ChatView+InputArea.swift agentGui/Views/InputAreaTodoCardView.swift agentGui/ViewModels/ChatComposerTodoCardPresentation.swift agentGuiTests/ChatComposerTodoCardPresentationTests.swift
git commit -m "feat: show todo card in composer assist area"
```

### Task 3: 从侧栏移除旧 TodoList，并收敛旧视图职责

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/TodoListView.swift`

**Step 1: 写失败测试或最小编译约束，先固定删除目标**

本任务以代码清理为主，不强制新建单元测试，但必须先明确删除对象：

- `WorkspacePanelView` 中的 `if !todoItems.isEmpty { TodoListView(items: todoItems) ... }`
- `WorkspacePanelView` 中仅为侧栏 Todo 展示服务的 `todoItems` 计算属性
- `TodoListView` 中基于 `DisclosureGroup` 的侧栏布局结构

如果 `TodoListView` 仅剩行级样式可复用，可将其改造为：

- 纯共享行组件
- 或直接删除旧 `DisclosureGroup` 包装，仅保留 `TodoRowView` 之类的最小复用部件

**Step 2: 写最小实现**

在 `WorkspacePanelView.swift` 中删除 Todo 区块：

```swift
if !todoItems.isEmpty {
    TodoListView(items: todoItems)
    Divider().opacity(0.4)
}
```

并删除对应 `todoItems` 计算属性，避免数据读取逻辑在两个区域重复存在。

在 `ChatView+InputArea.swift` 中新增唯一的数据读取入口，例如：

```swift
private var currentTodoItems: [TodoItem] {
    let store = SessionTaskStateStore(modelContext: modelContext)
    let persisted = store.todoItems(for: session.sessionId)
    if !persisted.isEmpty { return persisted }
    return claudeService.sessionTodoLists[session.sessionId] ?? []
}
```

在 `TodoListView.swift` 中，如果旧容器不再被使用，收敛为共享子视图，例如：

```swift
struct TodoRowContentView: View {
    let item: TodoItem
}
```

不要保留一个已经没有调用方的侧栏专用 `DisclosureGroup`。

**Step 3: 运行 focused tests 和编译验证**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests \
  -only-testing:agentGuiTests/ChatComposerSlashStateTests \
  -only-testing:agentGuiTests/SessionTaskStateStoreTests
```

Expected: PASS。

**Step 4: Commit**

```bash
git add agentGui/Views/WorkspacePanelView.swift agentGui/Views/TodoListView.swift agentGui/Views/ChatView+InputArea.swift
git commit -m "refactor: remove sidebar todo list entry"
```

### Task 4: 补输入区 UI 回归验证，确认 Todo 卡片与 slash / mention 竞争关系正确

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`
- Possibly Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/InMemoryAppHarness.swift`

**Step 1: 建立 UI test 注入路径的失败测试**

新增一个最小 UI 测试场景，验证：

- 启动时当前会话有 Todo，则输入区显示 Todo 卡片
- 输入 `/` 触发 slash 后，Todo 卡片隐藏，slash 卡片接管

建议测试代码：

```swift
import XCTest

final class ChatFlowUITests: UITestBase {

    @MainActor
    func testTodoCardAppearsAboveComposerAndYieldsToSlashPopup() throws {
        launchApp(arguments: [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.todoFixtureMode", "basic"
        ])

        XCTAssertTrue(app.otherElements["chat.todoCard"].waitForExistence(timeout: 2))

        let input = app.textViews["chat.inputField"]
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        input.click()
        input.typeText("/")

        XCTAssertTrue(app.otherElements["chat.slashPopup"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.otherElements["chat.todoCard"].exists)
    }
}
```

**Step 2: 运行 UI test 确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/ChatFlowUITests
```

Expected: FAIL，因为 Todo fixture 注入、accessibility identifiers 和 slash/todo 竞争行为尚未稳定暴露。

**Step 3: 写最小实现**

在 `TestLaunchOptions.swift` 中新增：

```swift
let todoFixtureMode: String?
```

并解析：

```swift
todoFixtureMode = Self.stringValue(for: "-com.agentgui.test.todoFixtureMode", in: arguments)
```

在 `agentGuiApp.swift` 或测试注入入口中，当 `todoFixtureMode == "basic"` 时，为当前测试会话写入一组最小 TodoItems 到 `claudeService.sessionTodoLists` 或对应测试 harness。

在 `ChatView+InputArea.swift` 和 `InputAreaTodoCardView.swift` 中新增至少以下 identifiers：

- `chat.todoCard`
- `chat.todoCard.header`
- `chat.todoCard.progress`
- `chat.slashPopup`

确保 `slashPopupCard` 有稳定 id，例如：

```swift
.accessibilityIdentifier("chat.slashPopup")
```

**Step 4: 运行 UI test 确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Utilities/TestLaunchOptions.swift agentGui/agentGuiApp.swift agentGuiUITests/ChatFlowUITests.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/InputAreaTodoCardView.swift
git commit -m "test: cover composer todo card visibility"
```

## 5. 最终验收清单

- TodoList 不再显示在 `WorkspacePanelView` 侧栏
- 当前会话存在 TodoItems 时，输入区上方显示 Todo 卡片
- Todo 卡片样式与 `slashPopupCard` 属于同一浮层家族
- `slashPopupCard` 和 `mentionPopupCard` 的优先级高于 Todo 卡片
- slash / mention 退出后，Todo 卡片能按当前会话状态恢复
- Todo 数据仍优先来自 `SessionTaskStateStore`，再回退到 `claudeService.sessionTodoLists`
- focused 单测和 UI test 通过

## 6. 执行建议

建议严格按以下顺序执行：

1. 先做纯展示模型和优先级判断
2. 再接入 `ChatView+InputArea` 与新卡片视图
3. 再删除侧栏旧入口
4. 最后补 UI 回归验证

不要一开始直接改 `ChatView+InputArea` 大视图并同时删除侧栏，这样很容易把优先级、布局和测试一起搞乱。