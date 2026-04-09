# Workbench LSP 面板 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 Workbench 侧栏中的 LSP 面板拆分到独立文件，并把“诊断详情 / 服务管理”从 popover 重构为面板内直接可见的列表式分区。

**Architecture:** 先把当前 popover 中仍在复用的展示逻辑提炼成与具体视图无关的 presentation helper，再把 WorkbenchLSPPanelView 从 WorkbenchSidebarView 中迁出，随后按诊断区和服务管理区两个层次渐进替换交互，最后删除不再使用的 popover 视图并补齐测试与构建验证。整个过程不改动 ClaudeService 的 LSP 状态计算链，只重组 SwiftUI 视图层和少量 presenter 装配代码。

**Tech Stack:** Swift 6、SwiftUI for macOS、SwiftData、Observation、现有 LSPServiceStateStore / LSPManagementViewModel / WorkspacePanelLSPFooterPresenter、Swift Testing、XCTest UI tests。

**Depends On:** [docs/plans/2026-03-24-workbench-lsp-panel-design.md](../plans/2026-03-24-workbench-lsp-panel-design.md)

---

## 0. Read This First

- 使用 @test-driven-development 执行所有生产代码变更。每一轮都先补失败测试，再写最小实现，再回归验证。
- 使用 @swiftui-expert-skill 处理 WorkbenchLSPPanelView、WorkbenchSidebarView 和新增长列表 section / row 视图，保持状态所有权清晰、body 纯净、子视图及时抽离。
- 不要改动 `ClaudeService.makeWorkspacePanelLSPStatus(...)`、`LSPServiceStateStore`、`LSPManagementViewModel.perform(...)` 的核心业务语义，除非测试证明当前语义无法支撑新 UI。
- 不要把 Settings 页的 `LSPManagementSectionView` 直接搬进 Workbench。可以复用 view model 和 action wiring，但 Workbench 需要自己的视觉层级和 row 结构。
- 当前 `LSPStatusPresentationTone` 和 `LSPDiagnosticRowPresentation` 仍定义在 `LSPDiagnosticsPopoverView.swift` 中。删除 popover 前必须先把这些共享展示逻辑迁出，否则测试和新 panel 会出现反向耦合。
- 如果 UI tests 因本地签名或目标环境问题无法稳定运行，至少执行一次 macOS build 验证：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build CODE_SIGNING_ALLOWED=NO
```

## 1. Scope Guardrails

- 不重写 Workbench 的导航结构，`WorkbenchNavigationItem` 和 `WorkbenchSidebarView` 的 panel 路由保持不变。
- 不扩展为完整 IDE 级 diagnostics navigator，只显示工作区摘要和最近诊断列表。
- 不重做 Settings 窗口中的 LSP 管理表单；Settings 仍保留其现有职责。
- 不引入新的后台轮询器或新的 LSP 状态存储层。
- 不顺带修改 Git panel、Workspace panel 或 Chat 区域。
- 不为这次重构设计通用“超级列表框架”；仅提炼当前 LSP panel 真正复用的 helper 和子视图。

## 2. Relevant Existing Files

### Workbench 与侧栏容器

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchSidebarView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchNavigationItem.swift`

### LSP 状态与管理展示

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspacePanelLSPFooterPresenter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/LSPManagementViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+WorkspaceContext.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPProjectDiagnosticsSummary.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`

### 现有 popover 和设置页组件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPDiagnosticsPopoverView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPManagementPopoverView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/LSPManagementSectionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/LSPServiceRowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/LSPServiceDetailView.swift`

### 可优先扩展的测试

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsPopoverPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPManagementViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/UITestBase.swift`

## 3. Target File Plan

### New Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchLSPPanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkbenchLSPPanelPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchLSPPanelPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkbenchLSPPanelUITests.swift`

### Modified Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchSidebarView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspacePanelLSPFooterPresenter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPDiagnosticsPopoverView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPManagementPopoverView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsPopoverPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPManagementViewModelTests.swift`

### Files Likely Deleted By The End

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPDiagnosticsPopoverView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPManagementPopoverView.swift`

如果在实现过程中发现其他入口仍依赖这两个 popover，则不要立即删除；先降级为兼容壳层，等所有调用方迁移后再删。

## 4. Implementation Order

先锁定共享展示契约，再做文件拆分，再替换诊断区，再替换服务区，最后清理废弃视图并跑验证。

---

### Task 1: 提炼与 popover 解耦的 LSP 面板展示 helper

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkbenchLSPPanelPresentation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchLSPPanelPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsPopoverPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspacePanelLSPFooterPresenter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPDiagnosticsPopoverView.swift`

**Step 1: Write the failing tests**

先锁定那些新旧视图都会复用的展示规则：

- 状态文案到 tone 的映射。
- 诊断 item 到 row presentation 的转换。
- 服务动作主次排序，例如未安装优先显示安装，运行中优先显示停止 / 重启。
- 状态 badge 的用户可见文案和颜色语义，不依赖具体 popover 视图。

测试草图：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkbenchLSPPanelPresentationTests {
    @Test func rowPresentationCombinesSourceAndLocationIntoMetadata() {
        let item = LSPProjectDiagnosticsSummary.DiagnosticItem(
            uri: "file:///repo/src/app.ts",
            message: "Type mismatch",
            severity: .error,
            source: "tsserver",
            line: 3,
            character: 7
        )

        let presentation = WorkbenchLSPDiagnosticRowPresentation.make(item)

        #expect(presentation.pathText == "app.ts")
        #expect(presentation.metadataText == "tsserver · L4:C8")
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/WorkbenchLSPPanelPresentationTests \
  -only-testing:agentGuiTests/LSPDiagnosticsPopoverPresentationTests
```

Expected: FAIL because the new presentation helper types do not exist yet.

**Step 3: Write minimal implementation**

最小实现：

- 新增 `WorkbenchLSPPanelPresentation.swift`，承载与具体视图无关的 helper，例如：
  - `WorkbenchLSPStatusTone`
  - `WorkbenchLSPDiagnosticRowPresentation`
  - `WorkbenchLSPServiceActionPresentation` 或等效的 action priority helper
- 让旧的 `LSPDiagnosticsPopoverView` 暂时改为依赖这些新 helper，而不是继续自己定义展示类型。
- 如果 `WorkspacePanelLSPFooterPresenter` 中已有 tone 辅助方法，改成转调新的 presentation helper，避免命名分裂。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/WorkbenchLSPPanelPresentation.swift agentGui/ViewModels/WorkspacePanelLSPFooterPresenter.swift agentGui/Views/LSPDiagnosticsPopoverView.swift agentGuiTests/WorkbenchLSPPanelPresentationTests.swift agentGuiTests/LSPDiagnosticsPopoverPresentationTests.swift
git commit -m "refactor: extract shared lsp panel presentation helpers"
```

### Task 2: 把 WorkbenchLSPPanelView 从 WorkbenchSidebarView 拆到独立文件

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchLSPPanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchSidebarView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkbenchLSPPanelUITests.swift`

**Step 1: Write the failing tests**

新增一个最小 UI 回归用例，锁定 LSP panel 仍然能通过 Workbench 导航进入，并显示基础 section：

- 使用 `-com.agentgui.test.initialTab lsp` 直接进入 LSP panel。
- 断言 `panel.lsp` 存在。
- 断言至少存在“状态”或基础 header 标识，证明 panel 内容已加载。

UI 草图：

```swift
import XCTest

final class WorkbenchLSPPanelUITests: UITestBase {
    @MainActor
    func testWorkbenchCanOpenLSPPanel() throws {
        launchApp(arguments: [
            "-com.agentgui.test.initialTab", "lsp",
            "-com.agentgui.test.workingDirectory", "/Volumes/T7/文稿/Projects/agentGui"
        ])

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "panel.lsp").firstMatch.waitForExistence(timeout: 2))
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiUITests/WorkbenchLSPPanelUITests
```

Expected: FAIL because the new UI test file does not exist yet.

**Step 3: Write minimal implementation**

最小实现：

- 新建 `WorkbenchLSPPanelView.swift`，先原样迁出当前 `WorkbenchSidebarView` 里的 `private struct WorkbenchLSPPanelView`。
- `WorkbenchSidebarView` 只保留侧栏容器和导航按钮逻辑，不再内嵌 LSP panel 大段实现。
- 在这一任务里不要改交互行为，popover 先保持原样，目标只是安全拆文件并让编译、UI 路由保持稳定。

**Step 4: Re-run the focused tests**

Run the same command from Step 2, then补一次编译验证：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build CODE_SIGNING_ALLOWED=NO
```

Expected: UI test PASS，build PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Workbench/WorkbenchSidebarView.swift agentGui/Views/Workbench/WorkbenchLSPPanelView.swift agentGuiUITests/WorkbenchLSPPanelUITests.swift
git commit -m "refactor: extract workbench lsp panel into its own file"
```

### Task 3: 用内联诊断列表替换“查看诊断详情” popover

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchLSPPanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchLSPPanelPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkbenchLSPPanelUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPDiagnosticsPopoverView.swift`

**Step 1: Write the failing tests**

锁定新的 diagnostics section 行为：

- 没有诊断时显示稳定空态文案。
- 有诊断时直接显示最近诊断列表，而不是只显示首条摘要。
- “查看诊断详情”按钮不再出现。
- 每条诊断行保留严重级别、文件名、消息和 metadata。

可以同时加一个 UI 断言来确认按钮消失、列表出现：

```swift
@MainActor
func testDiagnosticsAppearInlineWithoutPopoverTrigger() throws {
    launchApp(arguments: [
        "-com.agentgui.test.initialTab", "lsp",
        "-com.agentgui.test.workingDirectory", "/Volumes/T7/文稿/Projects/agentGui",
        "-com.agentgui.test.selectedFilePath", "/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchSidebarView.swift"
    ])

    XCTAssertFalse(app.buttons["查看诊断详情"].exists)
}
```

如果当前 UI 测试夹具不容易稳定制造诊断数据，至少用单元测试锁定 presentation 层的“多条 recentDiagnostics 会映射为多条 row”。

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/WorkbenchLSPPanelPresentationTests \
  -only-testing:agentGuiUITests/WorkbenchLSPPanelUITests
```

Expected: FAIL because the inline diagnostics list is not implemented yet and the popover trigger still exists.

**Step 3: Write minimal implementation**

最小实现：

- 删除 `showsLSPDiagnosticsPopover` 相关状态。
- 把 diagnostics section 改成直接显示最近诊断列表，默认显示 5 到 8 条。
- 复用 Task 1 的 row presentation helper，统一 severity 颜色、文件名解析、metadata 拼接。
- 保留计数 chip 和最近更新时间，但让它们成为列表上方的摘要，而不是详情入口。
- 暂时保留 `LSPDiagnosticsPopoverView.swift` 文件，直到确定没有其他引用方，再在后续任务删除。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Workbench/WorkbenchLSPPanelView.swift agentGuiTests/WorkbenchLSPPanelPresentationTests.swift agentGuiUITests/WorkbenchLSPPanelUITests.swift
git commit -m "feat: show lsp diagnostics inline in workbench panel"
```

### Task 4: 用面板内服务列表替换“服务管理” popover

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchLSPPanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspacePanelLSPFooterPresenter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPManagementViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkbenchLSPPanelUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPManagementPopoverView.swift`

**Step 1: Write the failing tests**

锁定新的服务区行为：

- “服务管理”按钮消失。
- panel 内直接显示服务列表。
- 每个服务行展示标题、语言、安装状态、运行状态。
- 点击行内“查看详情”或等效 disclosure 后，可看到版本、路径、最近错误或安装日志。
- “打开设置”仍存在，但降级为次级动作。

单元测试继续沿用 `LSPManagementViewModelTests`，重点增加“action 优先级和 row 需要的数据已齐备”一类断言。UI 测试重点只验证内联入口和基本元素存在，不在 UI 层测试实际安装流程。

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/LSPManagementViewModelTests \
  -only-testing:agentGuiUITests/WorkbenchLSPPanelUITests
```

Expected: FAIL because the Workbench panel still exposes service management through a popover button.

**Step 3: Write minimal implementation**

最小实现：

- 删除 `showsLSPManagementPopover` 相关状态。
- 在 `WorkbenchLSPPanelView.swift` 内引入 Workbench 风格的服务 row 和 detail 区，而不是直接复用 Settings 的 grouped Form。
- 使用 `presenter.managementViewModel(...)` 继续装配数据与动作闭环。
- 复用现有 `persistSettingsMutation(...)` 保存安装结果和设置变更。
- 保留“打开设置”按钮，但把它放在 services section header 或 footer 的次级位置。
- action busy 态只锁定当前服务行，不阻断整个 panel 浏览。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Workbench/WorkbenchLSPPanelView.swift agentGui/ViewModels/WorkspacePanelLSPFooterPresenter.swift agentGuiTests/LSPManagementViewModelTests.swift agentGuiUITests/WorkbenchLSPPanelUITests.swift
git commit -m "feat: show lsp service management inline in workbench panel"
```

### Task 5: 删除废弃 popover 视图并完成回归验证

**Files:**
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPDiagnosticsPopoverView.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPManagementPopoverView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsPopoverPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchLSPPanelPresentationTests.swift`

**Step 1: Write the failing tests**

在删除前先调整测试命名与覆盖范围，避免测试仍然绑定到旧视图文件名：

- 将 `LSPDiagnosticsPopoverPresentationTests` 中仍然指向 popover 语义的测试迁移到 `WorkbenchLSPPanelPresentationTests`。
- 新增一个构建级断言任务目标：项目不再引用 popover 视图文件。

这里的“失败测试”可以是构建失败或重复类型定义错误，目标是让删除动作在可控回归下完成。

**Step 2: Run tests to verify they fail or detect stale references**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build CODE_SIGNING_ALLOWED=NO
```

Expected: if stale references still exist, build FAIL and point to remaining popover usages.

**Step 3: Write minimal implementation**

最小实现：

- 删除两个已无调用方的 popover 视图文件。
- 把仍有价值的展示测试完整迁移到新的 panel presentation test 文件。
- 清理所有旧命名、旧引用和已失效的状态变量。

**Step 4: Run full focused verification**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/WorkbenchLSPPanelPresentationTests \
  -only-testing:agentGuiTests/LSPManagementViewModelTests \
  -only-testing:agentGuiUITests/WorkbenchLSPPanelUITests
```

Then run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

如果本地愿意再补一次仓库级冒烟，最后执行：

```bash
./scripts/run_quality_smoke.sh
```

如果 smoke 时间过长，至少运行：

```bash
./scripts/sample_quality_baseline.sh unit 5
```

**Step 5: Commit**

```bash
git add agentGui/Views/Workbench/WorkbenchLSPPanelView.swift agentGui/ViewModels/WorkbenchLSPPanelPresentation.swift agentGuiTests/WorkbenchLSPPanelPresentationTests.swift agentGuiUITests/WorkbenchLSPPanelUITests.swift
git rm agentGui/Views/LSPDiagnosticsPopoverView.swift agentGui/Views/LSPManagementPopoverView.swift
git commit -m "refactor: remove obsolete lsp popover views"
```

## 5. Manual Verification Checklist

- 在 Workbench 中切到 LSP tab，确认 panel 可以稳定显示。
- 未设置工作目录时，状态区显示明确空态。
- 选择文件后，状态区能显示当前文件名和对应服务状态。
- 有诊断时，最近诊断列表直接可见；没有诊断时显示空态文案。
- 面板内不再出现“查看诊断详情”和“服务管理”两个 popover 触发按钮。
- 服务列表可以展开详情，busy 态只影响当前行。
- “打开设置”仍可打开 `SettingsWindowScene.id`。
- 在窄侧栏宽度下，文件名、路径、状态 badge 都能合理截断，没有按钮挤压错位。

## 6. Risks And Notes

- `WorkbenchSidebarView.swift` 当前同时持有 sidebar button 和 panel routing。拆文件时要避免误改导航动画和 accessibility identifier。
- 如果把 Settings 页的 `LSPServiceRowView` / `LSPServiceDetailView` 直接复用到 Workbench，很容易产生视觉不一致。除非最终证明样式完全可接受，否则优先做 Workbench 自己的 row 视图。
- UI tests 很可能难以稳定制造真实 diagnostics 数据，因此不要把“有真实错误列表”完全寄托在 UI 测试上。更稳妥的做法是：单元测试锁定 presentation 映射，UI 测试只锁定入口和基本结构。
- 删除 popover 文件前务必先迁出 helper 类型，否则测试文件会因为类型消失而耦合回旧实现。

## 7. Definition Of Done

- `WorkbenchLSPPanelView` 已独立于 `WorkbenchSidebarView` 单独成文件。
- Workbench LSP panel 内直接展示 diagnostics list 和 services list。
- Workbench 中不再依赖 diagnostics / management popover。
- 共享展示逻辑已迁移到中性 presentation helper，不再挂在 popover 视图文件上。
- 相关单元测试、UI 测试和至少一次 macOS build 验证通过。

Plan complete and saved to `docs/plans/2026-03-24-workbench-lsp-panel-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?