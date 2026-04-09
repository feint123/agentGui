# Terminal Screen Rich Rendering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade the current plain-text terminal screen into a high-fidelity terminal renderer that preserves ANSI color, text attributes, buffer state, cursor state, and common TUI redraw behavior inside the existing tool detail UI.

**Architecture:** Extend the existing `TerminalVTParser -> TerminalScreenModel -> TerminalScreenSnapshot` chain so the screen snapshot carries cell-level style data instead of only plain text. Add a dedicated terminal theme and renderer layer, then replace the current single-`Text` SwiftUI rendering path with an AppKit-backed rich text surface optimized for mixed styles, selection, fallback, and incremental refresh.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Foundation, Swift Testing, existing `TerminalVTParser`, `TerminalScreenModel`, `TerminalTaskRuntime`, `TerminalScreenView`, and terminal UI tests.

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. 实施约束

- 严格按 TDD 执行，每个能力先补失败测试，再写最小实现。
- 不重做终端 runtime 底座；本计划建立在当前已存在的 VT parser、screen model 与 runtime 之上。
- `TerminalSurfaceProjector` 和交互 planner 继续依赖同一份 screen state，不能为 UI 另起一套解析逻辑。
- 终端渲染优先保证正确性和可读性，不做超出需求的终端产品化扩展。
- 当富样式渲染不可用时必须保留纯文本降级路径，不能让终端区域空白。
- 终端内容选择、复制与滚动是交付要求，渲染方案必须满足这些基础交互。

## 1. 当前代码锚点

本计划直接基于以下现有文件演进：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalSurfaceModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalVTParser.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalScreenModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceProjector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/TerminalScreenView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalVTParserTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceProjectorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenViewTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/TerminalInteractiveFixtures.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-17-terminal-screen-rich-rendering-requirements.md`

已确认现状：

- `TerminalScreenSnapshot` 目前只有 `plainTextLines`、buffer、cursor、尺寸。
- `TerminalScreenModel` 遇到 `setGraphicsRendition` 直接忽略，尚未保留样式状态。
- `TerminalScreenView` 仍使用单个 `Text` 渲染全文本。
- 现有测试只覆盖纯文本屏幕，不覆盖颜色、属性、反显、主题或富文本渲染。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalScreenTheme.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalScreenRenderer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/TerminalRichTextView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenRendererTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/TerminalRenderFixtures.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalSurfaceModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalVTParser.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalScreenModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceProjector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/TerminalScreenView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalVTParserTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceProjectorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenViewTests.swift`

## 3. 关键架构决策

### 3.1 继续以 screen model 为唯一事实来源

颜色、属性、反显、光标与主备屏状态都从 `TerminalScreenModel` 导出，`TerminalSurfaceProjector` 和 `TerminalScreenRenderer` 共享这份底层状态。

### 3.2 使用独立 renderer 层，而不是让 View 直接遍历底层 cell

`TerminalScreenRenderer` 负责把 screen snapshot 转成 UI 友好的渲染段落与 attributed content。这样可以把 VT 语义、主题映射和视图实现隔离开，便于测试和后续换渲染技术。

### 3.3 采用 AppKit-backed 富文本视图承载首版渲染

macOS 下如果要同时满足混合样式、文本选择、复制、长内容滚动和较稳定的性能，首版推荐走 `NSViewRepresentable + NSTextView`。纯 SwiftUI `Text` 或简单 `AttributedString` 拼接路线不适合承担大段混合样式终端内容的主视图。

### 3.4 保留 plain-text 兼容字段

`plainTextLines` 不能立即删除。它仍用于现有 projector、fallback 和诊断日志，直到富渲染与交互提取都稳定后再考虑是否进一步收缩。

## 4. 任务拆解

### Task 1: 锁定富样式屏幕数据契约

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalSurfaceModels.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenModelTests.swift`

**Step 1: Write the failing test**

为 `TerminalScreenSnapshot` 和相关 cell 模型补测试，先锁定需要承载的数据：

- cell 文本
- display width
- 前景色 / 背景色
- text attributes
- continuation cell
- line 级 cells 集合

示例：

```swift
@Test func screenSnapshotPreservesStyledCells() {
    let cell = TerminalScreenCell(
        text: "A",
        displayWidth: 1,
        foreground: .ansi256(196),
        background: .defaultBackground,
        attributes: [.bold, .underline],
        isContinuationCell: false
    )

    let snapshot = TerminalScreenSnapshot(
        lines: [.init(cells: [cell])],
        plainTextLines: ["A"],
        activeBuffer: .primary,
        cursor: .init(row: 0, column: 1),
        width: 80,
        height: 24
    )

    #expect(snapshot.lines[0].cells[0].foreground == .ansi256(196))
    #expect(snapshot.lines[0].cells[0].attributes.contains(.bold))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalScreenModelTests
```

Expected: FAIL because the styled cell types and snapshot fields do not exist.

**Step 3: Write minimal implementation**

在 `TerminalSurfaceModels.swift` 中新增最小模型：

- `TerminalColor`
- `TerminalTextAttribute`
- `TerminalScreenCell`
- `TerminalScreenLine`

并扩展 `TerminalScreenSnapshot` 以同时保留 `lines` 和 `plainTextLines`。

**Step 4: Run test to verify it passes**

运行同一命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/TerminalSurfaceModels.swift agentGuiTests/TerminalScreenModelTests.swift
git commit -m "feat: add styled terminal screen snapshot models"
```

### Task 2: 让 screen model 保留 SGR 样式与宽字符状态

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalVTParser.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalScreenModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalVTParserTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenModelTests.swift`

**Step 1: Write the failing test**

新增 parser/model 测试锁定以下行为：

- `CSI m` 事件不仅被解析，还会影响后续写入 cell 的样式。
- `0m` 重置当前样式。
- `7m` 反显、`1m` 粗体、`4m` 下划线、`38;5;n`、`48;2;r;g;b` 等常见样式能写进 snapshot。
- 宽字符至少能正确占位并标记 continuation cell。

示例：

```swift
@Test func screenModelAppliesAnsiForegroundAndInverseAttributes() {
    let parser = TerminalVTParser()
    var screen = TerminalScreenModel(width: 20, height: 8)

    for event in parser.parse("\u{001B}[31;7mERR\u{001B}[0m") {
        screen.apply(event)
    }

    let snapshot = screen.snapshot()
    let firstCell = snapshot.lines[0].cells[0]
    #expect(firstCell.foreground == .ansi16(.red))
    #expect(firstCell.attributes.contains(.inverse))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalVTParserTests \
  -only-testing:agentGuiTests/TerminalScreenModelTests
```

Expected: FAIL because SGR state is currently ignored by the screen model.

**Step 3: Write minimal implementation**

最小实现要求：

- 在 `TerminalScreenModel` 中引入当前 graphics state。
- 写入字符时把当前样式固化到每个 cell。
- 实现基础宽字符占位逻辑，不需要首轮就覆盖全部 Unicode 边角案例。
- `snapshot()` 同时导出 styled lines 与兼容的 `plainTextLines`。

**Step 4: Run test to verify it passes**

运行同一命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalVTParser.swift agentGui/Services/Terminal/TerminalScreenModel.swift agentGuiTests/TerminalVTParserTests.swift agentGuiTests/TerminalScreenModelTests.swift
git commit -m "feat: preserve sgr styles in terminal screen model"
```

### Task 3: 补 terminal renderer 与主题映射层

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalScreenTheme.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalScreenRenderer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenRendererTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/TerminalRenderFixtures.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceProjectorTests.swift`

**Step 1: Write the failing test**

新增 renderer 测试，锁定以下行为：

- ANSI 16 色、256 色、true color 能映射到终端主题色。
- `inverse` 会交换前景/背景。
- bold、underline、italic 等能映射到 attributed content。
- renderer 不破坏 `plainTextFrame`，`TerminalSurfaceProjector` 继续能从 enriched snapshot 中提取交互语义。

示例：

```swift
@Test func rendererMapsInverseCellIntoSwappedForegroundAndBackground() {
    let snapshot = TerminalRenderFixtures.inverseWarningSnapshot
    let rendered = TerminalScreenRenderer(theme: .darkDefault).render(snapshot)

    let firstRun = try #require(rendered.runs.first)
    #expect(firstRun.backgroundColor != nil)
    #expect(firstRun.foregroundColor != nil)
    #expect(firstRun.text == "WARN")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalScreenRendererTests \
  -only-testing:agentGuiTests/TerminalSurfaceProjectorTests
```

Expected: FAIL because the renderer and theme layer do not exist.

**Step 3: Write minimal implementation**

实现：

- `TerminalScreenTheme`：定义浅色/深色默认主题与 ANSI 调色板。
- `TerminalScreenRenderer`：把 `TerminalScreenSnapshot` 转成稳定的渲染段落、文本 run 或 `NSAttributedString`。
- `TerminalRenderFixtures`：提供彩色日志、反显选择器、宽字符等固定样本。

**Step 4: Run test to verify it passes**

运行同一命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalScreenTheme.swift agentGui/Services/Terminal/TerminalScreenRenderer.swift agentGuiTests/TerminalScreenRendererTests.swift agentGuiTests/TestSupport/TerminalRenderFixtures.swift agentGuiTests/TerminalSurfaceProjectorTests.swift
git commit -m "feat: add terminal theme and renderer layer"
```

### Task 4: 用 AppKit-backed 终端富文本视图替换纯文本渲染

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/TerminalRichTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/TerminalScreenView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenViewTests.swift`

**Step 1: Write the failing test**

补视图测试，先锁定以下要求：

- `TerminalScreenView` 不再只依赖 `displayText(for:)`。
- 终端屏幕仍保留 buffer、尺寸、cursor 元数据。
- 当 snapshot 含样式 run 时，视图选择 rich path；当样式不可用时，保留 plain-text fallback。
- 视图对外暴露稳定的 accessibility identifier。

示例：

```swift
@Test func terminalScreenViewPrefersRichRendererWhenStyledCellsExist() {
    let snapshot = TerminalRenderFixtures.coloredDiffSnapshot

    #expect(TerminalScreenView.usesRichRendering(for: snapshot))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalScreenViewTests
```

Expected: FAIL because `TerminalScreenView` has no rich rendering branch.

**Step 3: Write minimal implementation**

实现策略：

- 用 `NSViewRepresentable` 包装只读 `NSTextView` 或等价 AppKit 文本视图。
- 接收 `TerminalScreenRenderer` 产出的 attributed content。
- 在 `TerminalScreenView` 中保留当前 header/badge 结构，但把正文切换成 rich text surface。
- 仅在无 styled cells 或渲染失败时回退到纯文本 `Text`。

**Step 4: Run test to verify it passes**

运行同一命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/TerminalRichTextView.swift agentGui/Views/TerminalScreenView.swift agentGuiTests/TerminalScreenViewTests.swift
git commit -m "feat: render terminal screen with rich appkit text view"
```

### Task 5: 补主备屏、焦点态与容错回归样本

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceProjector.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceProjectorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskRuntimeTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/TerminalRenderFixtures.swift`

**Step 1: Write the failing test**

补端到端回归测试，锁定以下行为：

- alternate screen snapshot 进入 UI 后不会丢失焦点态。
- runtime 导出的 snapshot 在样式增强后仍可被 projector 正常消费。
- 非法 ANSI 或不完整样式片段不会导致 renderer 返回空内容。
- 进度条 / spinner 类重绘输出不会在最终 snapshot 中堆积成历史垃圾。

示例：

```swift
@Test func runtimeSnapshotKeepsAlternateScreenFocusForProjector() async throws {
    let snapshot = TerminalRenderFixtures.createVueSelectionSnapshot
    let surface = TerminalSurfaceProjector().project(snapshot)

    #expect(surface.isAlternateScreen)
    #expect(surface.visibleOptions.isEmpty == false)
    #expect(surface.focusedOptionIndex != nil)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalSurfaceProjectorTests \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests
```

Expected: FAIL because the current projector/runtime tests do not cover the enriched snapshot contract.

**Step 3: Write minimal implementation**

重点只做兼容和稳态，不扩额外产品行为：

- 确保 `TerminalSurfaceProjector` 继续从 `plainTextLines` 或 enriched lines 中稳定提取文本。
- 确保 runtime 生成 snapshot 时不会丢 `plainTextLines`。
- 补容错分支，render 失败时仍能返回 plain-text content。

**Step 4: Run test to verify it passes**

运行同一命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalSurfaceProjector.swift agentGui/Services/Terminal/TerminalTaskRuntime.swift agentGuiTests/TerminalSurfaceProjectorTests.swift agentGuiTests/TerminalTaskRuntimeTests.swift agentGuiTests/TestSupport/TerminalRenderFixtures.swift
git commit -m "test: add rich terminal rendering regression coverage"
```

### Task 6: 做完整回归与质量验证

**Files:**
- Modify as needed from previous tasks only. Do not create extra feature scope here.

**Step 1: Run focused terminal test suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalVTParserTests \
  -only-testing:agentGuiTests/TerminalScreenModelTests \
  -only-testing:agentGuiTests/TerminalSurfaceProjectorTests \
  -only-testing:agentGuiTests/TerminalScreenRendererTests \
  -only-testing:agentGuiTests/TerminalScreenViewTests \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests
```

Expected: PASS.

**Step 2: Run smoke validation**

Run workspace task:

```bash
Quality Smoke
```

Expected: existing smoke checks pass, or any unrelated pre-existing failures are documented.

**Step 3: Manual verification checklist**

手工验证以下样本：

- 彩色 `git diff --color`
- 目录彩色输出
- create-vue / create-next-app 风格选择器
- 中英文混排与 emoji
- alternate screen 进入与退出
- renderer 降级到 plain text 的异常路径

**Step 4: Commit**

```bash
git add agentGui/Models/TerminalSurfaceModels.swift agentGui/Services/Terminal/TerminalVTParser.swift agentGui/Services/Terminal/TerminalScreenModel.swift agentGui/Services/Terminal/TerminalScreenTheme.swift agentGui/Services/Terminal/TerminalScreenRenderer.swift agentGui/Views/TerminalRichTextView.swift agentGui/Views/TerminalScreenView.swift agentGuiTests/TerminalVTParserTests.swift agentGuiTests/TerminalScreenModelTests.swift agentGuiTests/TerminalSurfaceProjectorTests.swift agentGuiTests/TerminalScreenRendererTests.swift agentGuiTests/TerminalScreenViewTests.swift agentGuiTests/TerminalTaskRuntimeTests.swift agentGuiTests/TestSupport/TerminalRenderFixtures.swift
git commit -m "feat: add rich terminal screen rendering"
```

## 5. 交付顺序建议

推荐严格按以下顺序推进：

1. 先扩数据模型，不碰 UI。
2. 再让 screen model 正确保存样式状态。
3. 然后补 renderer 和主题层。
4. 最后替换 `TerminalScreenView` 的实际渲染组件。
5. 收尾阶段只做兼容与回归，不再扩需求。

这样做可以避免在 VT 样式还不稳定时，就把问题引入 SwiftUI/AppKit 视图层，导致调试边界混乱。

## 6. 风险与控制策略

### 风险 1：宽字符与 combining 处理不足

控制：第一版先用固定样本锁定 CJK + emoji + box drawing 的核心路径，不追求一次性覆盖所有 Unicode 细节。

### 风险 2：富文本终端内容刷新卡顿

控制：renderer 输出必须可增量复用；`TerminalScreenView` 不要每次刷新都重建复杂 SwiftUI 文本树。

### 风险 3：交互 projector 与 UI renderer 语义分叉

控制：两者都从同一份 `TerminalScreenSnapshot` 读取，不允许 renderer 直接重新解析 ANSI 字符串。

### 风险 4：富渲染引入后 fallback 路径失效

控制：保留 `plainTextLines`，并为异常输入单独补 renderer fallback 测试。

## 7. 完成定义

以下条件全部满足，视为此计划完成：

- `TerminalScreenSnapshot` 已包含 cell 级样式数据。
- `TerminalScreenModel` 能把常见 SGR 样式与宽字符状态保留到 snapshot。
- `TerminalScreenRenderer` 能输出带主题映射的富文本内容。
- `TerminalScreenView` 已不再以单个 `Text` 作为主渲染路径。
- `TerminalSurfaceProjector` 与 runtime 仍兼容 enriched snapshot。
- 终端相关 focused tests 全绿，且 smoke 验证无新增回归。

Plan complete and saved to `docs/plans/2026-03-17-terminal-screen-rich-rendering-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?