# Code Editor Feature 6 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为现有 CodeEditor 主路径接入只读语义能力，把 hover、definition、references 和 document symbols 稳定挂到编辑器交互里，同时继续保持“输入主路径不等待 LSP、所有异步结果按版本闸门丢弃过期结果”的约束。

**Architecture:** 这一轮不把语义逻辑塞回 `NSTextStorage`，也不让 `CodeEditorTextView` 直接依赖 `WorkspaceState` 或 `ClaudeService`。`CodeEditorLSPCoordinator` 继续作为 editor-scoped LSP 协调层，新增只读语义请求 API、hover 去抖和请求代际过滤；`CodeEditorTextView` 只负责把 Option-click、右键菜单、快捷键、鼠标停顿等交互翻译成语义 intent；`FileEditorView` 作为宿主层负责执行 definition/references/document symbols 导航，并复用 `WorkspaceState.showFileDetail(...)` 完成跨文件跳转。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Foundation、现有 `CodeEditorView` / `CodeEditorTextView` / `CodeEditorLSPCoordinator` / `LSPClient` / `LSPServerManager` / `WorkspaceState`、Swift Testing

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 当前执行状态（2026-03-30）

- Feature 1-5 的主骨架已经存在：`CodeEditorView`、`CodeEditorTextView`、`CodeEditorDocument`、`CodeEditorLineIndex`、Highlightr viewport 管线、gutter 和 `CodeEditorLSPCoordinator` 都已在仓库里落地。
- `LSPClient` 和 `LSPServerManager` 目前已经支持 `definition`、`references`、`hover` 三个请求，但 `documentSymbols` 仍是空实现，`LSPToolFacade` 里对应工具也只返回占位文本。
- `CodeEditorTextView` 已经可以稳定发布选区、光标位置和可见区变化，也已经有 `CodeEditorPlatformTextView` 作为 AppKit 子类承接高亮和当前行绘制，因此鼠标停顿、Option-click、菜单和 reveal 行为都应继续落在这一层扩展，而不是新建第二套文本组件。
- `FileEditorView` 当前已经持有 `WorkspaceState`、`ClaudeService`、当前文件 URL 和 `CodeEditorLSPCoordinator`，并且可以通过 `workspaceState.showFileDetail(...)` 触发工作区文件切换，因此 definition 的跨文件导航应优先复用这个现成宿主入口。
- 当前测试面覆盖了 `CodeEditorLSPCoordinatorTests`、`CodeEditorTextViewIntegrationTests`、`CodeEditorViewIntegrationTests` 和 `CodeEditorViewModelTests`，但还没有任何语义交互、hover 去抖、document symbols 解析或 reveal 请求的测试。

## 0. 范围约束

- Feature 6 只实现只读语义能力，不实现 rename、code action、completion、inline diagnostics fix-it 或任何会回写文件的 LSP 写操作。
- Feature 6 不重写 `CodeEditorLSPCoordinator` 的 didOpen/didChange/didClose 主路径；只在其上扩展“按位置发请求、按版本丢弃结果、按代际取消 hover”的能力。
- Feature 6 不引入新的全局侧边栏或复杂 symbol tree 容器；document symbols 只需要接到“当前文件内导航”的最小 UI 即可，优先复用 `FileEditorView` 现有 breadcrumb/action bar。
- Option-click definition、右键 references、F12/Shift-F12 快捷键和 hover 停顿都不能阻塞文本输入，也不能在 marked text/IME 组合输入阶段误触发。
- Feature 6 必须支持“同文件 reveal”和“跨文件 open + reveal”两条导航路径；跨文件跳转优先限定在可解析为本地文件 URL 的情况，对非 file URI 或工作区外 URI 只做保守失败处理。
- 这个 Xcode 工程使用 `PBXFileSystemSynchronizedRootGroup`；在 `agentGui` 和 `agentGuiTests` 下新增 Swift 文件通常不需要手动修改工程文件。

## 1. 代码锚点

当前与 Feature 6 直接相关的实现落点如下：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
  这里已经负责 didOpen/didChange/didClose、版本跟踪和 diagnostics 过滤，是只读语义请求继续扩展的第一落点。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
  这里已经掌握 `NSTextView`、`CodeEditorPlatformTextView`、选区发布、viewport 观察和 gutter 更新，是 hover hit-testing、Option-click、右键菜单、快捷键和 reveal 的主入口。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
  这里是 SwiftUI 壳层，已经负责把文本、diagnostics、LSP 状态和编辑回调组织起来，适合承接新的 `onSemanticIntent` / `revealRequest` / presentation 状态。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`
  当前只做状态栏和 diagnostics 行聚合，但它已经是编辑器纯值派生逻辑的集中点，适合继续承接 document symbols 扁平化、definition 导航动作判定和 references 列表投影。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
  当前已经持有 `WorkspaceState`、`ClaudeService` 和 `CodeEditorLSPCoordinator`，能解析当前文件的 LSP binding，也能通过 `workspaceState.showFileDetail(...)` 切换 detail 文件，是语义结果最终执行层。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
  这里提供 `showFileDetail(_:)` 和 `selectedFile` 主状态，但当前没有“切换文件后还要在新编辑器实例里 reveal 到指定行列”的挂起状态，需要在本 Feature 里补一个最小导航 payload。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
  当前 `definition`、`references`、`hover` 已实现，`documentSymbols` 仍为空；Feature 6 必须在这里补齐 `DocumentSymbol[]` / `SymbolInformation[]` 两种协议返回值解析。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
  当前暴露三类只读查询，需要同步补齐 `documentSymbols` 转发，给协调器和工具层使用。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPToolFacade.swift`
  当前 `documentSymbols(...)` 仍返回未实现占位文案；虽然这不是 Feature 6 的主要 UI 路径，但补齐这里能避免工具面和编辑器面语义能力分叉。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLSPCoordinatorTests.swift`
  当前只覆盖 didOpen/didChange/didClose 和 diagnostics 过滤，没有 hover 取消、definition/references/documentSymbols 请求测试。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
  当前已经有现成 harness 覆盖文本变更、选区、viewport、gutter 和 marked text，可以扩展语义 intent 与 reveal 回归。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
  当前已经覆盖 `CodeEditorView` 到宿主回调的桥接，适合继续覆盖 reveal 请求、hover/references presentation 和符号导航动作。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/LSPServerManagerHarness.swift`
  当前假实现已经能响应 initialize 并记录 document lifecycle，适合补上 definition/references/hover/documentSymbols 响应载荷，让协调器测试不需要真实语言服务器。

## 2. 方案结论

本 Feature 建议按下面这条路线落地：

1. 先补齐 LSP 数据层，把 document symbols 从 `LSPClient` 到 `LSPServerManager` 再到 `LSPToolFacade` 打通，并给它一个强类型模型，而不是继续用字符串占位。
2. 在 `CodeEditorLSPCoordinator` 里新增“只读语义请求层”，统一负责：
   - 绑定请求发起时的本地文档版本
   - hover 的去抖与旧请求取消
   - 过期结果丢弃
   - capabilities 缺失时的快速失败
3. `CodeEditorTextView` 只输出语义 intent，不自己直接发 LSP：
   - Option-click 触发 definition
   - 右键菜单和 Shift-F12 触发 references
   - F12 触发 definition
   - 鼠标停顿触发 hover
   - 宿主传入 reveal 请求后，文本视图负责选中并滚动到目标位置
4. `FileEditorView` 作为宿主层执行语义结果：
   - definition 命中同文件时直接 reveal
   - 命中其他本地文件时通过 `workspaceState.showFileDetail(...)` 切换文件，并把 reveal 目标挂到 `WorkspaceState`
   - references 结果以轻量列表呈现，点击后复用同一导航路径
   - document symbols 通过 breadcrumb/action bar 菜单接到当前文件内导航

不建议采用的路线：

- 不要把 hover/definition/references 直接写进 `CodeEditorPlatformTextView` 里去访问 `LSPServerManager`。这样会把 AppKit 文本组件和工作区环境强耦合，测试也会退化成 UI 集成硬测。
- 不要把所有逻辑都堆进 `FileEditorView`。它应该负责“执行语义动作”，而不该自己维护 hover 去抖、请求取消和版本过滤；这些都应留在 `CodeEditorLSPCoordinator`。
- 不要为了 document symbols 引入新的复杂 side panel。本 Feature 只需要把当前文件内导航闭环做通，优先做最小菜单和 reveal 流程。

## 3. 设计细节

### 3.1 新增语义模型

建议新增一个轻量模型文件，例如 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorSemanticModels.swift`，集中定义编辑器和宿主层共享的纯值类型：

```swift
import Foundation

struct CodeEditorSemanticPosition: Equatable, Sendable {
    let line: Int
    let column: Int
    let utf16Offset: Int
    let version: Int
}

enum CodeEditorSemanticIntent: Equatable, Sendable {
    case requestDefinition(CodeEditorSemanticPosition)
    case requestReferences(CodeEditorSemanticPosition)
    case requestHover(CodeEditorSemanticPosition)
    case cancelHover
}

struct CodeEditorRevealRequest: Equatable, Sendable, Identifiable {
    let id: UUID
    let fileURL: URL
    let line: Int
    let column: Int
    let reason: Reason

    enum Reason: Equatable, Sendable {
        case definition
        case reference
        case documentSymbol
    }
}

struct CodeEditorHoverPresentation: Equatable, Sendable {
    let position: CodeEditorSemanticPosition
    let markdown: String
}

struct CodeEditorReferencePresentation: Equatable, Sendable, Identifiable {
    let id: UUID
    let queryPosition: CodeEditorSemanticPosition
    let items: [Item]

    struct Item: Equatable, Sendable, Identifiable {
        let id: UUID
        let fileURL: URL
        let line: Int
        let column: Int
        let title: String
        let subtitle: String
    }
}
```

这个文件只放纯值模型，不放任何环境依赖。原因：

- `CodeEditorTextView`、`CodeEditorView`、`FileEditorView`、`WorkspaceState` 和测试 harness 都会消费这些类型。
- reveal 请求会跨过“旧编辑器实例销毁 -> 新文件打开 -> 新编辑器实例出现”的过程，不适合只存在于局部闭包里。
- hover/references/document symbols 的展示态如果没有强类型，很容易继续退化成“字符串 + 可选字典”的脆弱接口。

### 3.2 LSP document symbols 数据层

Feature 6 必须先补齐 document symbols 这一条数据链路。建议新增一个强类型模型，例如 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDocumentSymbol.swift`：

```swift
import Foundation

struct LSPDocumentSymbol: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let detail: String?
    let kind: Int
    let line: Int
    let character: Int
    let endLine: Int?
    let endCharacter: Int?
    let children: [LSPDocumentSymbol]
}
```

`LSPClient` 需要补一个异步 API：

```swift
func documentSymbols(uri: String) async throws -> [LSPDocumentSymbol]
```

实现要求：

- 支持 `DocumentSymbol[]` 返回：读取 `name`、`detail`、`kind`、`selectionRange.start` 和递归 `children`。
- 支持 `SymbolInformation[]` 返回：读取 `name`、`kind`、`location.range.start`，再把其平铺转成没有 children 的数组。
- 对空结果返回 `[]`，不要抛错。
- 解析失败时宁可保守忽略当前条目，也不要让整个查询链路崩掉。

然后在 `LSPServerManager` 和 `LSPToolFacade` 补同名转发。`LSPToolFacade.documentSymbols(...)` 的最小输出可以是多行纯文本，但底层必须以 `LSPDocumentSymbol` 为真相，避免编辑器 UI 和工具层各自写一套解析逻辑。

### 3.3 `CodeEditorLSPCoordinator` 的语义请求层

这一层是 Feature 6 的核心。建议在现有 `CodeEditorLSPCoordinator` 基础上新增：

```swift
@MainActor
func requestDefinition(at position: CodeEditorSemanticPosition) async -> CodeEditorRevealRequest?

@MainActor
func requestReferences(at position: CodeEditorSemanticPosition) async -> CodeEditorReferencePresentation?

@MainActor
func requestDocumentSymbols(documentVersion: Int) async -> [LSPDocumentSymbol]

@MainActor
func scheduleHover(
    at position: CodeEditorSemanticPosition,
    debounceNanoseconds: UInt64,
    deliver: @escaping @MainActor (CodeEditorHoverPresentation?) -> Void
)

@MainActor
func cancelHover()
```

新增内部状态建议如下：

```swift
private var latestHoverGeneration = 0
private var pendingHoverTask: Task<Void, Never>?
```

关键规则：

- 发起 definition / references / hover / document symbols 前，先检查 `isOpen` 和 `manager.capabilities(...)`。服务端不支持时直接返回空结果，不发请求。
- definition / references / hover 发起时都记录“请求位置的本地版本”；只有当结果返回时 `position.version == latestLocalVersion` 时才允许回流到 UI。旧版本结果全部丢弃。
- hover 采用单独的 debounce，并且每次新 hover 都取消上一个 `pendingHoverTask`。鼠标移走、滚动、开始输入、进入 marked text 时立即 `cancelHover()`。
- document symbols 可以不做高频 debounce，但仍应附带“当前文档版本”入参，只在请求发起和结果回流时确保文件绑定未变化、版本未倒退。
- 这层不要自己执行 `workspaceState.showFileDetail(...)`；它只返回 reveal 或 presentation，由宿主决定如何展示和导航。

### 3.4 编辑器交互层

`CodeEditorTextView` / `CodeEditorPlatformTextView` 建议只做 3 类增强。

第一类：新增语义 intent 回调和 reveal 输入。

```swift
var onSemanticIntent: ((CodeEditorSemanticIntent) -> Void)? = nil
var revealRequest: CodeEditorRevealRequest? = nil
```

`revealRequest` 的处理规则：

- 当宿主传入新 `CodeEditorRevealRequest.id` 时，把 `line/column` 转成 UTF-16 offset。
- 使用 `setSelectedRange(...)` + `scrollRangeToVisible(...)` 让目标行进入视口。
- reveal 属于程序性更新，不应被当成用户编辑，也不应触发新的 hover。

第二类：新增交互挂点。

- Option-click：在 `CodeEditorPlatformTextView.mouseDown(with:)` 里检测 `event.modifierFlags.contains(.option)`，命中时把点击点转成字符位置，再发 `.requestDefinition(...)`。
- 右键菜单：在 `CodeEditorPlatformTextView.menu(for:)` 或自定义 menu provider 里生成 `Go to Definition` / `Find References` 菜单项；点击菜单项时发对应 intent。菜单构建只负责把 point 解析为 position，不直接发 LSP。
- 快捷键：优先使用 `F12` 触发 definition，`Shift-F12` 触发 references；如果当前 `NSTextView` 已经有系统占用冲突，再降级为 `Fn-F12` 检测，但计划执行时先以标准 IDE 习惯为主。
- Hover：给 `CodeEditorPlatformTextView` 加 `NSTrackingArea`，在 `mouseMoved(with:)` 里解析 point -> position，转发 `.requestHover(...)`；在 `mouseExited(with:)`、滚动、选区变化或输入开始时发 `.cancelHover`。

第三类：IME 和性能保护。

- `hasMarkedText()` 为真时，不发 definition/references/hover 请求。
- 文本变化后先走已有 `commitDisplayedText(...)` 主路径，再取消 hover；不要在按键尚未落盘到 `CodeEditorDocument` 之前读取位置版本。
- 滚动导致 visible range 大量变化时，只取消 hover，不主动重发 definition/references。

### 3.5 宿主层导航与展示

`FileEditorView` 需要新增几类宿主状态：

- 当前 hover presentation
- 当前 references presentation
- 当前 document symbols 列表
- 待发送到编辑器实例的 `CodeEditorRevealRequest`

definition 导航规则建议抽成纯值 helper，放在 `CodeEditorViewModel` 中，例如：

```swift
enum CodeEditorSemanticNavigationAction: Equatable {
    case revealInCurrentFile(CodeEditorRevealRequest)
    case openFileAndReveal(URL, CodeEditorRevealRequest)
    case unsupported
}
```

判定规则：

- 如果 target URI 解析后与当前文件相同，返回 `.revealInCurrentFile`。
- 如果 target URI 是本地 file URL 且存在文件路径，返回 `.openFileAndReveal`。
- 其他 URI 返回 `.unsupported`。

宿主执行策略：

- `.revealInCurrentFile`：直接更新本地 `revealRequest` 状态并传给 `CodeEditorView`。
- `.openFileAndReveal`：调用 `workspaceState.showFileDetail(targetURL)`，同时把 reveal 请求写入 `WorkspaceState` 的一个新字段，例如 `pendingCodeEditorRevealRequest`。新文件对应的 `FileEditorView` 在 `onAppear` / `onChange(of: fileURL)` 时消费这个字段并清空。
- references：使用宿主层轻量列表展示即可，优先做 `sheet` 或附着在编辑器附近的简单面板，不必在本 Feature 里实现复杂树状分组。点击某条 reference 后复用同一 navigation action。
- document symbols：优先在 breadcrumb/action bar 增加一个 `Menu` 按钮。点击按钮时异步请求 symbols；如果列表非空，就把经过 view model 扁平化后的条目塞进菜单。点击菜单项后只做当前文件 reveal，不做跨文件跳转。

### 3.6 hover 展示最小实现

hover UI 不需要复杂 markdown renderer，本 Feature 只要做到“有文本、有版本闸门、不挡输入”即可。

建议：

- `CodeEditorLSPCoordinator.scheduleHover(...)` 返回 `CodeEditorHoverPresentation`，其中 `markdown` 直接沿用 LSP hover 文本。
- `CodeEditorView` 接收一个可选 `hoverPresentation`，并把它转发给 `CodeEditorTextView`。
- `CodeEditorTextView` 内部由 `CodeEditorPlatformTextView` 负责把 hover 文本展示成轻量 `NSPopover` 或 tooltip-like 面板，并按位置更新锚点。
- 只要文本变更、滚动、切换文件、切换 viewer、hover 结果为空或版本过期，就立即关闭当前 hover 面板。

这里不要追求富文本和高亮嵌套渲染；首轮直接显示 plain text / markdown 原文即可。Feature 6 的重点是语义链路稳定，而不是 tooltip 样式复杂度。

## 4. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorSemanticModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDocumentSymbol.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorSemanticQueryTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPToolFacade.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLSPCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/LSPServerManagerHarness.swift`

### Optional modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorStatusBar.swift`
  只有在执行时决定把 document symbols 按钮放到底部状态栏，而不是 breadcrumb/action bar，才需要改这个文件。首选是不改。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
  只有在跨文件 reveal 需要额外协调 workspace 面板和 detail 切换时才修改；首轮优先只通过 `WorkspaceState.showFileDetail(...)` 完成切换。

## 5. 任务拆解

### Task 1: 先锁定 LSP 只读语义数据层

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDocumentSymbol.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorSemanticQueryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPToolFacade.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/LSPServerManagerHarness.swift`

**Step 1: Write the failing tests**

先新增一组聚焦语义查询链路的测试，至少覆盖：

- `documentSymbols` 能解析 `DocumentSymbol[]`
- `documentSymbols` 能兼容 `SymbolInformation[]`
- `LSPServerManager.documentSymbols(...)` 会把请求转发给正确 session
- `LSPToolFacade.documentSymbols(...)` 不再返回占位字符串

示例：

```swift
@MainActor
@Test
func documentSymbolsParsesNestedDocumentSymbolPayload() async throws {
    let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
    let manager = harness.makeManager()
    _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")

    let symbols = try await manager.documentSymbols(
        workspaceRoot: "/tmp",
        serverID: "python-lsp",
        uri: "file:///tmp/Sample.py"
    )

    #expect(symbols.first?.name == "Demo")
    #expect(symbols.first?.children.first?.name == "inner")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature6-task1 -only-testing:agentGuiTests/CodeEditorSemanticQueryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，报 `documentSymbols` 未实现、类型缺失或 façade 仍返回占位文本。

**Step 3: Write the minimal implementation**

- 新增 `LSPDocumentSymbol`。
- 在 `LSPClient` 实现 `documentSymbols(uri:) async throws -> [LSPDocumentSymbol]`。
- 在 `LSPServerManager` 和 `LSPToolFacade` 补对应转发。
- 扩展 `SharedLSPServerManagerHarness` 的假响应载荷，让 `textDocument/documentSymbol` 返回稳定 fixture。

**Step 4: Run test to verify it passes**

重复上面的 `xcodebuild test` 命令。

Expected: PASS，且 `documentSymbols` 相关断言全部通过。

**Step 5: Commit**

```bash
git add agentGui/Models/LSPDocumentSymbol.swift agentGui/Services/LSP/LSPClient.swift agentGui/Services/LSP/LSPServerManager.swift agentGui/Services/LSP/LSPToolFacade.swift agentGuiTests/CodeEditorSemanticQueryTests.swift agentGuiTests/TestSupport/LSPServerManagerHarness.swift
git commit -m "feat: add lsp document symbol queries"
```

### Task 2: 扩展 `CodeEditorLSPCoordinator` 的只读语义请求与 hover 代际控制

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorSemanticModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLSPCoordinatorTests.swift`

**Step 1: Write the failing tests**

在现有 `CodeEditorLSPCoordinatorTests` 基础上追加以下用例：

- hover 在更晚版本输入后不会把旧结果回流
- 新 hover 请求会取消旧 hover 任务
- definition 命中本地 file URL 时返回 reveal request
- references 会映射成稳定的 `CodeEditorReferencePresentation`
- document symbols 请求在 coordinator deactivated 后返回空结果

示例：

```swift
@MainActor
@Test
func staleHoverResultIsDiscardedAfterNewerVersionArrives() async throws {
    let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
    let manager = harness.makeManager()
    _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
    let coordinator = CodeEditorLSPCoordinator(manager: manager, binding: .fixtureSourceFile(), debounceNanoseconds: 10_000_000)

    coordinator.activate(initialText: "value", version: 1)

    var delivered: [CodeEditorHoverPresentation?] = []
    coordinator.scheduleHover(
        at: .init(line: 1, column: 1, utf16Offset: 0, version: 1),
        debounceNanoseconds: 5_000_000
    ) { delivered.append($0) }

    coordinator.handleTextChange(
        text: "value2",
        change: .init(version: 2, replacedRange: NSRange(location: 5, length: 0), insertedText: "2", selectedRange: NSRange(location: 6, length: 0), origin: .userEdit)
    )

    try? await Task.sleep(nanoseconds: 60_000_000)
    #expect(delivered.allSatisfy { $0 == nil })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature6-task2 -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，报缺少语义模型、缺少 coordinator API 或 hover 结果没有被正确丢弃。

**Step 3: Write the minimal implementation**

- 新增 `CodeEditorSemanticModels.swift`。
- 在 `CodeEditorLSPCoordinator` 里实现 definition / references / document symbols / hover API。
- 增加 hover generation、pending hover task 和 capabilities 快速失败。
- 明确 `cancelHover()` 在 `deactivate()`、`handleProgrammaticReload(...)` 等路径中也会被调用。

**Step 4: Run test to verify it passes**

重复 Task 2 的 `xcodebuild test` 命令。

Expected: PASS，hover 取消、版本闸门和 reveal/reference 映射全部通过。

**Step 5: Commit**

```bash
git add agentGui/Models/CodeEditorSemanticModels.swift agentGui/Services/Editor/CodeEditorLSPCoordinator.swift agentGuiTests/CodeEditorLSPCoordinatorTests.swift
git commit -m "feat: add code editor semantic coordinator queries"
```

### Task 3: 给 `CodeEditorTextView` 加上语义 intent 和 reveal 管线

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

**Step 1: Write the failing tests**

扩展 `CodeEditorTextViewIntegrationTests`，至少覆盖：

- Option-click 会发 `.requestDefinition(...)`
- Shift-F12 会发 `.requestReferences(...)`
- 鼠标停顿会发 `.requestHover(...)`，继续移动或开始输入会发 `.cancelHover`
- reveal request 到达后，文本视图会选中目标位置并滚动到可见区
- marked text 期间不会发任何语义 intent

示例：

```swift
@MainActor
@Test
func revealRequestSelectsRequestedLocationWithoutEmittingUserEdit() {
    let harness = CodeEditorTextViewHarness(text: "alpha\nbeta\ngamma")
    harness.applyRevealRequest(
        .init(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/Demo.swift"),
            line: 3,
            column: 2,
            reason: .definition
        )
    )

    #expect(harness.textView.selectedRange().location == harness.document.utf16Offset(line: 3, column: 2))
    #expect(harness.changeSetCount == 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature6-task3 -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，报缺少 `onSemanticIntent`、`revealRequest` 或鼠标/键盘挂点未实现。

**Step 3: Write the minimal implementation**

- 在 `CodeEditorTextView` / `CodeEditorView` 新增 `onSemanticIntent` 与 `revealRequest` 透传。
- 在 `CodeEditorPlatformTextView` 扩展 mouseDown、menu、keyDown、tracking area。
- 在 coordinator 中处理 reveal 请求，并确保 reveal 不会被误认为用户编辑。
- 在文本编辑、marked text、滚动、selection change 路径里调用 `.cancelHover`。

**Step 4: Run test to verify it passes**

重复 Task 3 的 `xcodebuild test` 命令。

Expected: PASS，语义 intent 和 reveal 行为都通过，且原有文本编辑用例无回归。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGui/Views/CodeEditor/CodeEditorView.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "feat: add code editor semantic interaction hooks"
```

### Task 4: 先把 definition / references 的宿主导航闭环做通

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing tests**

先锁定导航决策和宿主执行行为：

- 同文件 definition 返回 `.revealInCurrentFile`
- 跨文件 definition 返回 `.openFileAndReveal`
- references presentation 点击条目后复用同一导航动作
- `WorkspaceState` 的 pending reveal 会被新 `FileEditorView` 消费一次并清空

示例：

```swift
@Test
func navigationActionUsesOpenFileAndRevealForDifferentLocalFile() {
    let currentFile = URL(fileURLWithPath: "/tmp/A.swift")
    let reveal = CodeEditorRevealRequest(
        id: UUID(),
        fileURL: URL(fileURLWithPath: "/tmp/B.swift"),
        line: 8,
        column: 3,
        reason: .definition
    )

    let action = CodeEditorViewModel.navigationAction(currentFileURL: currentFile, revealRequest: reveal)
    #expect(action == .openFileAndReveal(reveal.fileURL, reveal))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature6-task4 -only-testing:agentGuiTests/CodeEditorViewModelTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，报导航动作、pending reveal 状态或宿主回调链路未实现。

**Step 3: Write the minimal implementation**

- 在 `CodeEditorViewModel` 增加导航动作判定和 document symbols 扁平化 helper。
- 在 `WorkspaceState` 加一个最小 `pendingCodeEditorRevealRequest`，只用于 detail 文件切换后的单次消费。
- 在 `FileEditorView` 处理 definition/references intent：
  - 请求 coordinator
  - 执行导航动作
  - 管理 references presentation 状态
- 确保 `FileEditorView` 在 `onAppear` / `fileURL` 变化后消费与当前文件匹配的 pending reveal。

**Step 4: Run test to verify it passes**

重复 Task 4 的 `xcodebuild test` 命令。

Expected: PASS，definition/references 导航闭环成立，且同文件 / 跨文件路径都稳定。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/CodeEditorViewModel.swift agentGui/Utilities/WorkspaceState.swift agentGui/Views/FileEditorView.swift agentGuiTests/CodeEditorViewModelTests.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "feat: add semantic navigation handling to file editor"
```

### Task 5: 接通 hover 展示和 document symbols 文件内导航

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing tests**

至少覆盖：

- hover presentation 更新时，旧 hover 会关闭，新 hover 会显示最新内容
- `cancelHover` 会清空当前 hover 展示态
- breadcrumb/action bar 的 symbol 菜单会请求 document symbols，并把点击项转成 reveal request
- document symbols 仅做当前文件内导航，不触发跨文件 open

示例：

```swift
@MainActor
@Test
func symbolNavigationProducesRevealRequestForSelectedSymbol() {
    let symbols = [
        LSPDocumentSymbol(
            id: UUID(),
            name: "Demo",
            detail: nil,
            kind: 12,
            line: 4,
            character: 0,
            endLine: 8,
            endCharacter: 1,
            children: []
        )
    ]

    let item = try #require(CodeEditorViewModel.flattenedDocumentSymbols(symbols).first)
    #expect(item.revealRequest.line == 5)
    #expect(item.revealRequest.reason == .documentSymbol)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature6-task5 -only-testing:agentGuiTests/CodeEditorViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，报 hover presentation、symbol flattening 或 symbol menu 处理未实现。

**Step 3: Write the minimal implementation**

- 在 `FileEditorView` 加 hover state、references state、symbol menu state。
- 在 `CodeEditorView` / `CodeEditorTextView` 接入 hover presentation 的显示与关闭。
- 在 breadcrumb/action bar 加一个最小 symbols 菜单按钮，点击时请求 `coordinator.requestDocumentSymbols(documentVersion:)`。
- 点击 symbol 菜单项后，仅生成当前文件 reveal request，不做跨文件跳转。

**Step 4: Run test to verify it passes**

重复 Task 5 的 `xcodebuild test` 命令。

Expected: PASS，hover 和 symbol 导航通过，原有 `CodeEditorView` 回归测试仍稳定。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorView.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGui/Views/FileEditorView.swift agentGuiTests/CodeEditorViewIntegrationTests.swift agentGuiTests/CodeEditorViewModelTests.swift
git commit -m "feat: add hover and document symbol navigation"
```

### Task 6: 跑聚焦验证并做手工回归

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorSemanticQueryTests.swift`（如需补漏）
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLSPCoordinatorTests.swift`（如需补漏）
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`（如需补漏）
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`（如需补漏）

**Step 1: Run the focused automated test gate**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature6-final -only-testing:agentGuiTests/CodeEditorSemanticQueryTests -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

如果本地 `xcodebuild test` 仍被 scheme 里的 UI target 签名问题卡住，先执行：

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination platform=macOS -derivedDataPath /tmp/agentGui-feature6-build CODE_SIGNING_ALLOWED=NO
```

至少确认 app target 和 unit test target 编译健康。

**Step 2: Run manual regression checks**

手工验证以下场景：

1. 在当前文件里 Option-click 可跳到定义，且编辑器输入没有明显停顿。
2. F12 和 Shift-F12 在 `CodeEditorTextView` 聚焦时可用。
3. 右键菜单里可触发 definition/references，references 点击结果能跳到正确位置。
4. 鼠标停顿出现 hover，继续输入、滚动、切换文件或进入中文输入法组合阶段时 hover 会立即消失。
5. symbols 菜单能列出当前文件符号，并在点击后滚动到正确位置。
6. 跨文件 definition 会切换 detail 到目标文件，并在新文件打开后 reveal 到目标行列。

**Step 3: Commit**

```bash
git add agentGui agentGuiTests
git commit -m "feat: complete code editor read-only semantic navigation"
```

## 6. 风险与决策点

### 风险 1: hover 结果回流时已经过期

**应对：**

- hover 使用独立 generation 和 debounce task。
- 所有 hover 结果都同时检查 `position.version == latestLocalVersion` 和当前 binding 未变化。
- 一旦文件切换、文本变化或 marked text 开始，立即 cancel。

### 风险 2: 跨文件 definition 打开了目标文件，但新编辑器实例没收到 reveal

**应对：**

- 在 `WorkspaceState` 中加单次消费的 `pendingCodeEditorRevealRequest`。
- `FileEditorView` 仅在 `fileURL` 与 reveal request 匹配时消费，并立刻清空。

### 风险 3: 右键菜单与异步 references 请求耦合过深

**应对：**

- 菜单构建只发 intent，不在 menu 构建阶段等待 LSP。
- 真正请求发生在菜单 action 里，由宿主层异步执行。

### 风险 4: document symbols 返回形态不一致

**应对：**

- `LSPClient` 同时兼容 `DocumentSymbol[]` 和 `SymbolInformation[]`。
- 用强类型模型统一下游消费，UI 只看 `LSPDocumentSymbol`。

## 7. 完成定义

达到以下条件时，可以认为 Feature 6 初步完成：

- `CodeEditorLSPCoordinator` 能稳定处理 definition、references、hover 和 document symbols，只读语义请求都带版本闸门。
- `CodeEditorTextView` 支持 Option-click、右键菜单、F12/Shift-F12 和 hover 停顿，并能接收 reveal 请求。
- `FileEditorView` 能把 definition/references/document symbols 结果转成当前文件或跨文件导航。
- hover 在输入、滚动、切换文件和 IME 组合输入场景下不会残留或造成明显卡顿。
- document symbols 已接入当前文件内导航，而不是停留在工具层占位实现。
- 聚焦自动化测试通过，且手工回归能完成同文件 / 跨文件 / hover / symbols 四条关键路径。

Plan complete and saved to `docs/plans/2026-03-30-code-editor-feature-6-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按任务顺序逐个实现、逐个验证

**2. Parallel Session (separate)** - 新开会话按 executing-plans skill 并行执行

**Which approach?**