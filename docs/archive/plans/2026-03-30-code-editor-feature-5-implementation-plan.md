# Code Editor Feature 5 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为现有 CodeEditor 主路径补上一层受控的 LSP 文档同步协调器，把 didOpen/didChange/didClose 从 FileEditorView 的裸回调中抽离出来，并通过去抖、版本闸门和过期结果过滤保证持续输入期间本地编辑始终优先。

**Architecture:** 这一轮不把 LSP 逻辑下沉进 NSTextView，也不让 CodeEditorView 直接依赖 ClaudeService 或 LSPServerManager。`CodeEditorLSPCoordinator` 作为宿主层协调器，由 FileEditorView 负责构造 workspace/server/file 绑定和依赖注入；编辑器继续只输出 `EditorChangeSet` 与纯文本，协调器再负责 didOpen、debounced didChange、didClose、最新版本跟踪，以及对 diagnostics 快照的版本过滤。这样可以把“编辑器输入主路径”和“LSP 追赶路径”明确分层，同时为后续 Feature 6 的 hover/definition/references 复用同一版本闸门。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Foundation、现有 `CodeEditorView` / `CodeEditorDocument` / `EditorChangeSet` / `LSPServerManager` / `LSPClient` / `LSPDiagnosticsStore`、Swift Testing

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 当前执行状态（2026-03-30）

- Feature 1-4 的基础设施已经存在：`CodeEditorView`、`CodeEditorTextView`、`CodeEditorDocument`、`CodeEditorLineIndex`、`CodeEditorHighlightPipeline`、gutter 和状态栏均已落地。
- 当前文本编辑器里的 LSP 同步仍然是宿主层直连：`FileEditorView` 在 `CodeEditorView(... onTextChange:)` 回调里直接调用 `syncOpenDocumentToLSPIfNeeded(text:)`，而不是经过专用协调器。
- `CodeEditorDocument` 已经为每次用户编辑生成带版本号的 `EditorChangeSet`，这正好可以作为 Feature 5 的“编辑器本地版本真相”。
- `LSPServerManager.syncDocument(...)` 目前把“open 或 update”的判断合并在一起，能作为初始实现的发送出口，但还没有去抖层，也没有 editor-facing 的生命周期对象。
- `LSPDiagnosticsSnapshot` 当前只有 `updatedAt`，没有文档版本；如果要把“过期 diagnostics 丢弃”写成真正可执行的实现，必须补充版本信息或明确过滤策略。
- 仓库里还没有 `CodeEditorLSPCoordinatorTests` 或 `FileEditorView` 的 LSP 集成测试，因此本 Feature 的第一任务应该先补测试支架，而不是直接改宿主逻辑。

## 0. 范围约束

- Feature 5 只处理文档生命周期与同步调度，不实现 hover、definition、references、completion 或 code action。
- Feature 5 不改写 `CodeEditorTextView` 的输入主路径；输入仍然先落本地文本存储和 `CodeEditorDocument`，LSP 只能异步追赶。
- Feature 5 不把 `ClaudeService`、`AppSettings` 或 `WorkspaceState` 注入底层编辑器视图；这些环境依赖仍由 `FileEditorView` 宿主层解析后传给协调器。
- Feature 5 不把 diagnostics UI 展示层塞进协调器；协调器只负责“哪些 diagnostics 是当前版本可接受的”，`CodeEditorView` 继续消费已经过滤过的 snapshot。
- Feature 5 允许继续复用 `LSPServerManager.syncDocument(...)` 作为底层发送 API，但不允许 `FileEditorView` 再在 `onTextChange` 里直接调用它。
- 如果服务端 diagnostics 未提供版本，计划中的过滤逻辑必须采用“有版本则严格过滤，无版本则保守放行”的兼容策略，不能因为协议字段缺失直接让 diagnostics 全部失效。
- 这个 Xcode 工程使用 `PBXFileSystemSynchronizedRootGroup`；在 `agentGui` 和 `agentGuiTests` 目录下新增文件通常不需要手动修改工程文件。

## 1. 代码锚点

当前与 Feature 5 直接相关的实现落点如下：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
  这里仍然承担文本文件的 LSP bootstrap、当前文件 diagnostics 查询，以及 `syncOpenDocumentToLSPIfNeeded(text:)` 这种裸同步逻辑，是本 Feature 的主要宿主改造点。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
  这里已经有 `onTextChange: ((String, EditorChangeSet) -> Void)?` 回调，能把用户编辑与版本化 change set 向上传出，是协调器接入的自然接口。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDocument.swift`
  这里已经维护 `version`、`applyUserEdit` 和磁盘替换路径，是“编辑器本地版本”唯一可信来源。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
  目前提供 `syncDocument(...)` 与 `closeDocument(...)`，但没有 editor-scoped debounce 或生命周期对象。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
  这里负责 didOpen/didChange/didClose 发送和 publishDiagnostics 解析；如果要引入 diagnostics 版本，通知解析也要在这里补齐。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDiagnosticsStore.swift`
  当前只按 `workspaceRoot + uri` 保存最新快照，没有文档版本过滤能力。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`
  当前 snapshot 只有 `workspaceRoot`、`uri`、`diagnostics`、`updatedAt`；这里需要评估是否增加 `documentVersion`。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/LSPServerManagerHarness.swift`
  当前已经能记录 `documentLifecycleEvents` 和最新 `LSPDocumentSnapshot`，很适合拿来断言 didOpen/didChange/didClose 顺序与版本。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
  当前覆盖编辑器和宿主回调链路，但还没有 LSP 协调器接入后的集成回归。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/CodeEditorTextViewHarness.swift`
  当前可以稳定模拟文本输入、选区与可见区变化，必要时可复用来构造 change set 驱动测试。

## 2. 方案结论

本 Feature 建议按下面这条路线落地：

1. 新增一个 `CodeEditorLSPCoordinator`，由宿主层持有，输入是“已解析好的 LSP 文档绑定 + LSPServerManager + 当前文本与 change set”，输出是“发送 open/change/close”和“过滤后的当前文件 diagnostics”。
2. `FileEditorView` 不再在 `onTextChange` 里直接调 `syncOpenDocumentToLSPIfNeeded(text:)`，而是先解析当前文件的 LSP 绑定，再把编辑事件转交给协调器。
3. 协调器内部实现短窗口 debounce，只保留最新版本待发送的 didChange；连续输入期间旧任务全部取消，永远不等待 LSP 返回才允许下一次本地编辑发生。
4. didOpen 和 didClose 也由协调器托管：文件进入文本编辑器且 LSP 可用时打开文档，文件切换、视图消失、切换到非文本 viewer 时关闭文档并取消待发送的 change 任务。
5. diagnostics 过滤不放在 store 里“全局硬裁”，而是让 snapshot 带上可选 `documentVersion`，协调器或宿主层针对当前文件做 `latest-version-wins` 过滤；这样不会误伤 workspace panel 之类只关心“最近一份可见 diagnostics”的其他 UI。

这样做的原因：

- `CodeEditorView` 已经能稳定发出版本化 `EditorChangeSet`，没有必要再把 LSP manager 注入到最底层 AppKit 文本组件里。
- `FileEditorView` 已经掌握 working directory、settings、当前 file URL 和 ClaudeService，是解析 LSP workspace binding 的正确位置。
- `LSPServerManager.syncDocument(...)` 只解决“开或更”的发送，不解决“何时发、发哪一版、何时关闭”的调度；这正是协调器该负责的边界。
- diagnostics 版本过滤如果只靠 `updatedAt` 会非常脆弱，必须把版本语义显式写进模型，哪怕先做 optional 兼容位。

## 3. 设计细节

### 3.1 协调器输入模型

建议在 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorLSPCoordinator.swift` 中定义一个轻量绑定值，避免协调器直接依赖环境对象：

```swift
struct CodeEditorLSPDocumentBinding: Equatable, Sendable {
    let workspaceRoot: String
    let serverID: String
    let uri: String
    let languageID: String
}
```

`FileEditorView` 负责把下面这些上下文先解析成普通值：

- working directory
- 当前文件 URL
- `LSPWorkspaceResolver` 返回的 `workspaceRoot/serverID/languageID`
- `claudeService.lspServerManager`

协调器初始化后不再自己读 `AppSettings` 或重新 resolve workspace。这样可以避免底层服务对象偷偷依赖 UI 环境，后续也更容易给测试传入固定 binding。

### 3.2 协调器生命周期

建议把 `CodeEditorLSPCoordinator` 设计成 `@MainActor final class`，内部持有一个可取消的 debounced Task：

```swift
@MainActor
final class CodeEditorLSPCoordinator {
    private let manager: LSPServerManager
    private let binding: CodeEditorLSPDocumentBinding
    private let debounceNanoseconds: UInt64
    private var isOpen = false
    private var latestLocalVersion = 0
    private var latestSentVersion = 0
    private var pendingChangeTask: Task<Void, Never>?
    private var pendingText: String?

    init(
        manager: LSPServerManager,
        binding: CodeEditorLSPDocumentBinding,
        debounceNanoseconds: UInt64 = 120_000_000
    ) { ... }
}
```

最小公开 API 建议是：

```swift
func activate(initialText: String, version: Int)
func handleTextChange(text: String, change: EditorChangeSet)
func handleProgrammaticReload(text: String, version: Int)
func deactivate()
func acceptsDiagnostics(_ snapshot: LSPDiagnosticsSnapshot?) -> Bool
```

关键规则：

- `activate` 负责发送一次 open，如果文档已经打开则不重复 didOpen。
- `handleTextChange` 只更新 `latestLocalVersion` 和待发送文本，然后重置 debounce 任务。
- debounce 到期时只发送当前最新文本，发送后更新 `latestSentVersion`。
- `deactivate` 必须取消 pending task，并在文档已打开时发送 didClose。
- `handleProgrammaticReload` 只在“磁盘替换后文本已变化且编辑器版本前进”场景调用，用于保证外部重载后 LSP 也能追上最新内容，但不能把宿主层自己的赋值回声当成用户编辑再发一轮 didChange。

### 3.3 didOpen / didChange / didClose 策略

建议明确以下行为：

- didOpen：文件首次进入 `.text` viewer 且 resolve 到有效 LSP binding 时触发一次，使用当前完整文本。
- didChange：所有用户输入都先落本地；协调器只在 debounce 后发送最新版本完整文本，旧版本任务全部取消。
- didClose：发生在以下任一时机
  - `FileEditorView.onDisappear`
  - `fileURL` 变化前关闭旧文件
  - viewer 从 `.text` 切换到其他模式
  - LSP binding 失效或 manager 不可用时清理旧会话

注意点：

- 当前 `LSPServerManager.syncDocument(...)` 会在 update 失败时自动 open，所以协调器首轮可以继续复用它作为发送出口；但计划中仍应把“是否已打开”的状态保存在协调器里，避免宿主层每次变化都把 open/update 决策外溢。
- 如果后续要支持更精细的增量 contentChanges，本协调器 API 不应把“发送全文字符串”写死在调用方；但本 Feature 先坚持全文同步，避免一次引入过多复杂度。

### 3.4 diagnostics 版本过滤

这里是 Feature 5 最容易写虚的地方，必须落成明确的数据路径。

建议修改 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`：

```swift
struct LSPDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let workspaceRoot: String
    let uri: String
    let diagnostics: [LSPDiagnostic]
    let documentVersion: Int?
    let updatedAt: Date
}
```

并在 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift` 的 publishDiagnostics 解析里读取协议 `version` 字段：

```swift
let documentVersion = number(from: params["version"])
publishDiagnostics(
    workspaceRoot: workspaceRoot,
    uri: uri,
    diagnostics: diagnostics,
    documentVersion: documentVersion
)
```

过滤规则：

- 如果 `snapshot.documentVersion == nil`，保守放行，维持当前兼容行为。
- 如果 `snapshot.documentVersion != nil`，只有当它 `>= latestSentVersion` 且 `<= latestLocalVersion` 时才向 `CodeEditorView` 暴露。
- 协调器销毁或关闭文档后，不再继续把旧文件的 diagnostics 传给当前编辑器实例。

这样做的好处是：

- 支持服务端没有回填 version 的现实情况。
- 不把 store 改成“只保留某一版可见快照”的全局单例逻辑，避免影响工作区面板、项目汇总或其他消费者。
- 为 Feature 6 的 hover/definition 结果过滤复用同一套版本语义。

### 3.5 FileEditorView 的宿主改造

`FileEditorView` 建议做三类调整：

1. 用一个新的 helper 替代 `syncOpenDocumentToLSPIfNeeded(text:)`，先解析当前文件的 `CodeEditorLSPDocumentBinding`。
2. 在文本分支里创建并持有协调器实例，把 `onTextChange` 回调转发给 `coordinator.handleTextChange(text:change:)`。
3. 在 `onAppear`、`onDisappear`、`onChange(of: fileURL)` 和 viewer 变化时显式执行 `activate/deactivate`，保证旧文件关闭、新文件重新打开。

推荐不要让 `CodeEditorView` 自己 resolve workspace 或自己决定何时 close。`CodeEditorView` 只知道“文本变化了”和“当前文件 URL 是什么”，它不该知道工作区根目录、LSP provider 配置或 ClaudeService 生命周期。

## 4. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLSPCoordinatorTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDiagnosticsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/LSPServerManagerHarness.swift`

### Optional modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
  只有在实践中发现 `syncDocument(...)` 与协调器职责分界不清，才考虑补一个更语义化的 `openOrUpdateDocument` 包装；首轮优先复用现有 API。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+WorkspaceContext.swift`
  只有在 editor status 需要消费“已过滤 diagnostics”而当前 helper 无法复用时才修改；不要为了 Feature 5 顺手重构整个 workspace context。

## 5. 任务拆解

### Task 1: 先为协调器补最小生命周期测试

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLSPCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/LSPServerManagerHarness.swift`

**Step 1: Write the failing test**

先锁定三个核心行为：

- `activate(initialText:version:)` 会发送一次 open
- 连续多次 `handleTextChange` 只发送最后一个 change
- `deactivate()` 会取消 pending change 并发送 close

示例：

```swift
@MainActor
@Test
func rapidTypingSendsOnlyLatestDocumentVersion() async {
    let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["swift"]))
    let manager = harness.makeManager()
    let coordinator = CodeEditorLSPCoordinator(
        manager: manager,
        binding: .fixtureSwiftFile(),
        debounceNanoseconds: 30_000_000
    )

    coordinator.activate(initialText: "let value = 1", version: 0)
    coordinator.handleTextChange(
        text: "let value = 2",
        change: EditorChangeSet(version: 1, replacedRange: NSRange(location: 12, length: 1), insertedText: "2", selectedRange: .init(location: 13, length: 0), origin: .userEdit)
    )
    coordinator.handleTextChange(
        text: "let value = 3",
        change: EditorChangeSet(version: 2, replacedRange: NSRange(location: 12, length: 1), insertedText: "3", selectedRange: .init(location: 13, length: 0), origin: .userEdit)
    )

    try? await Task.sleep(nanoseconds: 80_000_000)

    #expect(harness.documentLifecycleEvents.contains("open:file:///tmp/Sample.swift"))
    #expect(harness.documentLifecycleEvents.last == "change:file:///tmp/Sample.swift")
    #expect(harness.lastClientDocumentSnapshot?.text == "let value = 3")
    #expect(harness.lastClientDocumentSnapshot?.version == 2)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature5-task1 -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，提示 `CodeEditorLSPCoordinator` 或测试辅助 fixture 尚不存在。

**Step 3: Write minimal implementation**

先创建协调器壳子和最小 fixture，哪怕 diagnostics 过滤能力暂时留空，也要先让 open / latest-change / close 行为跑起来：

```swift
@MainActor
final class CodeEditorLSPCoordinator {
    private let manager: LSPServerManager
    private let binding: CodeEditorLSPDocumentBinding
    private let debounceNanoseconds: UInt64
    private var isOpen = false
    private var latestLocalVersion = 0
    private var latestSentVersion = 0
    private var pendingTask: Task<Void, Never>?

    func activate(initialText: String, version: Int) {
        guard !isOpen else { return }
        isOpen = true
        latestLocalVersion = version
        latestSentVersion = version
        manager.syncDocument(
            workspaceRoot: binding.workspaceRoot,
            serverID: binding.serverID,
            uri: binding.uri,
            languageID: binding.languageID,
            text: initialText
        )
    }

    func handleTextChange(text: String, change: EditorChangeSet) {
        latestLocalVersion = max(latestLocalVersion, change.version)
        pendingTask?.cancel()
        pendingTask = Task { [manager, binding, debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            manager.syncDocument(
                workspaceRoot: binding.workspaceRoot,
                serverID: binding.serverID,
                uri: binding.uri,
                languageID: binding.languageID,
                text: text
            )
        }
    }

    func deactivate() {
        pendingTask?.cancel()
        pendingTask = nil
        guard isOpen else { return }
        isOpen = false
        manager.closeDocument(
            workspaceRoot: binding.workspaceRoot,
            serverID: binding.serverID,
            uri: binding.uri
        )
    }
}
```

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorLSPCoordinator.swift agentGuiTests/CodeEditorLSPCoordinatorTests.swift agentGuiTests/TestSupport/LSPServerManagerHarness.swift
git commit -m "feat: add code editor lsp coordinator skeleton"
```

### Task 2: 把 FileEditorView 的裸同步替换成协调器驱动

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing test**

补一个宿主层回归，锁定“编辑器回调仍然发出 change set，但 FileEditorView 不再自己做裸 sync helper 调用”的预期。因为当前仓库没有 `FileEditorView` 专用测试，可先从 `CodeEditorViewIntegrationTests` 补一个更贴近宿主回调的断言：

- 用户编辑后 `onTextChange` 仍携带 `EditorChangeSet.version`
- 程序性 `persistedText` 刷新不会回声成用户 change

如果测试里需要看到协调器接收事件，可增加一个 fake sink：

```swift
@Test
func editorChangeCallbackCarriesVersionedChangeSetForHostCoordinator() {
    let harness = CodeEditorViewHarness(initialText: "a", persistedText: "a")

    harness.replaceCharacters(in: NSRange(location: 1, length: 0), with: "b")

    #expect(harness.lastForwardedText == "ab")
    #expect(harness.lastChange?.version == 1)
    #expect(harness.lastChange?.origin == .userEdit)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature5-task2 -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，若测试依赖的新宿主接口尚未存在，或回调没有暴露足够信息给协调器。

**Step 3: Write minimal implementation**

宿主层改造建议分两步完成：

1. 在 `FileEditorView` 中新增 helper，把当前文件解析成 `CodeEditorLSPDocumentBinding?`

```swift
private func currentLSPDocumentBinding(for url: URL) -> CodeEditorLSPDocumentBinding? {
    let settings = AppSettings.getOrCreate(in: modelContext)
    let workingDirectory = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
    guard settings.enableLSPTools,
          let registry = try? LSPServerRegistry(settings: settings),
          let resolved = LSPWorkspaceResolver().resolve(
            filePath: url.standardizedFileURL.path,
            workingDirectory: workingDirectory,
            registry: registry,
            settings: settings
          ) else {
        return nil
    }

    return CodeEditorLSPDocumentBinding(
        workspaceRoot: resolved.workspaceRoot,
        serverID: resolved.serverID,
        uri: url.standardizedFileURL.absoluteString,
        languageID: resolved.languageID ?? "plaintext"
    )
}
```

2. 用 `@State private var lspCoordinator: CodeEditorLSPCoordinator?` 托管当前文件的协调器，并在以下时机驱动它：

- 文件文本加载完成时 `activate(initialText:version:)`
- `CodeEditorView.onTextChange` 时 `handleTextChange(text:change:)`
- `onDisappear` 和 `onChange(of: fileURL)` 时 `deactivate()`

同时删除 `syncOpenDocumentToLSPIfNeeded(text:)`，避免新旧两套入口并存。

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS，并且现有 CodeEditorView 回归不退化。

**Step 5: Commit**

```bash
git add agentGui/Views/FileEditorView.swift agentGui/Views/CodeEditor/CodeEditorView.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "refactor: route code editor lsp sync through coordinator"
```

### Task 3: 给 diagnostics 补版本语义并实现过滤

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDiagnosticsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLSPCoordinatorTests.swift`

**Step 1: Write the failing test**

先补两个版本门禁测试：

- 旧版本 diagnostics 快照会被协调器拒绝
- 没有 `documentVersion` 的快照仍然可显示，保证兼容旧服务端

示例：

```swift
@MainActor
@Test
func staleVersionedDiagnosticsAreRejected() {
    let coordinator = CodeEditorLSPCoordinator.fixture(latestLocalVersion: 5, latestSentVersion: 5)
    let snapshot = LSPDiagnosticsSnapshot(
        workspaceRoot: "/tmp",
        uri: "file:///tmp/Sample.swift",
        diagnostics: [.init(message: "old", severity: .warning, line: 0, character: 0)],
        documentVersion: 3
    )

    #expect(coordinator.acceptsDiagnostics(snapshot) == false)
}

@MainActor
@Test
func unversionedDiagnosticsRemainVisibleForCompatibility() {
    let coordinator = CodeEditorLSPCoordinator.fixture(latestLocalVersion: 5, latestSentVersion: 5)
    let snapshot = LSPDiagnosticsSnapshot(
        workspaceRoot: "/tmp",
        uri: "file:///tmp/Sample.swift",
        diagnostics: [.init(message: "compat", severity: .warning, line: 0, character: 0)],
        documentVersion: nil
    )

    #expect(coordinator.acceptsDiagnostics(snapshot) == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature5-task3 -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，提示 `documentVersion` 或过滤逻辑尚不存在。

**Step 3: Write minimal implementation**

按下面顺序最小化落地：

1. 给 `LSPDiagnosticsSnapshot` 增加 `documentVersion: Int?`
2. 给 `LSPClient.publishDiagnostics(...)` 增加同名参数，并在 notification 解析中读取 `params["version"]`
3. 在 `CodeEditorLSPCoordinator` 增加过滤函数：

```swift
func acceptsDiagnostics(_ snapshot: LSPDiagnosticsSnapshot?) -> Bool {
    guard let snapshot else { return false }
    guard snapshot.uri == binding.uri else { return false }
    guard let version = snapshot.documentVersion else { return true }
    return version >= latestSentVersion && version <= latestLocalVersion
}
```

4. `FileEditorView` 在把 snapshot 传给 `CodeEditorView` 之前先调用协调器过滤，只有通过的快照才显示。

**Step 4: Run test to verify it passes**

Run 同 Step 2，并补跑编辑器集成回归：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature5-task3-view -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/LSPDiagnosticsSnapshot.swift agentGui/Services/LSP/LSPClient.swift agentGui/Services/LSP/LSPDiagnosticsStore.swift agentGui/Services/Editor/CodeEditorLSPCoordinator.swift agentGui/Views/FileEditorView.swift agentGuiTests/CodeEditorLSPCoordinatorTests.swift
git commit -m "feat: filter stale editor diagnostics by document version"
```

### Task 4: 收口关闭时机与切文件回归

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorLSPCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing test**

最后补两个容易漏掉的回归：

- 切换到新文件前旧文件会先 close
- 视图销毁时 pending didChange 不会在后台继续发送

示例：

```swift
@MainActor
@Test
func deactivateCancelsPendingChangeBeforeClose() async {
    let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["swift"]))
    let manager = harness.makeManager()
    let coordinator = CodeEditorLSPCoordinator(
        manager: manager,
        binding: .fixtureSwiftFile(),
        debounceNanoseconds: 200_000_000
    )

    coordinator.activate(initialText: "a", version: 0)
    coordinator.handleTextChange(
        text: "ab",
        change: EditorChangeSet(version: 1, replacedRange: NSRange(location: 1, length: 0), insertedText: "b", selectedRange: .init(location: 2, length: 0), origin: .userEdit)
    )
    coordinator.deactivate()
    try? await Task.sleep(nanoseconds: 260_000_000)

    #expect(harness.documentLifecycleEvents.last == "close:file:///tmp/Sample.swift")
    #expect(harness.documentLifecycleEvents.filter { $0 == "change:file:///tmp/Sample.swift" }.count == 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature5-task4 -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，说明关闭时机或 pending task 取消仍有漏洞。

**Step 3: Write minimal implementation**

确保 `FileEditorView` 和协调器遵守下面两条规则：

- 新 fileURL 生效前先 `deactivate()` 旧协调器，再创建新 binding 并 `activate()`
- `deactivate()` 先 cancel task，再 close document，避免 close 后旧 task 迟到又发出一轮 change

必要时把关闭逻辑封装为一个 helper：

```swift
private func resetLSPCoordinator() {
    lspCoordinator?.deactivate()
    lspCoordinator = nil
}
```

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/FileEditorView.swift agentGuiTests/CodeEditorLSPCoordinatorTests.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "fix: close editor lsp documents deterministically"
```

## 6. 测试门禁

每完成一个任务，至少运行与该任务直接相关的 focused tests。整个 Feature 收口时，建议跑下面这组：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature5-full -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

如果中途发现 `FileEditorView` 缺少可靠测试入口，再补一个专用宿主层测试文件，但不要在没有明确回归价值前先扩测试矩阵。

## 7. 风险与决策点

### 风险 1：服务端不回填 diagnostics version

**应对：** `documentVersion` 设计为 optional；有版本则严格过滤，无版本则保守放行，同时在日志里预留可观测点，方便后续判断哪些 provider 需要补 adapter。

### 风险 2：FileEditorView 生命周期重复触发 open/close

**应对：** 协调器内部维护 `isOpen`，宿主层所有 reset 入口统一走一个 helper，避免 `onAppear`、`onChange(fileURL)`、viewer 变化各自复制一套 close 逻辑。

### 风险 3：磁盘重载和用户输入都走 didChange，产生回声同步

**应对：** 区分 `handleTextChange` 和 `handleProgrammaticReload`，不要把 `persistedText` 的同步刷新直接当成用户编辑；只有真实 change set 才参与 debounce 队列。

### 风险 4：协调器把 LSP 依赖渗透进底层编辑器

**应对：** 坚持“编辑器只发 change set，宿主层才持有协调器”的边界，不给 `CodeEditorTextView` 注入 `LSPServerManager` 或 `ClaudeService`。

## 8. 完成定义

达到以下条件时，可以认为 Feature 5 初步完成：

- `FileEditorView` 不再通过 `syncOpenDocumentToLSPIfNeeded(text:)` 之类的裸 helper 直接发 LSP 文档同步。
- `CodeEditorLSPCoordinator` 能稳定处理 didOpen、debounced didChange、didClose，并且只保留最新版本待发送任务。
- 文件切换、视图消失和非文本 viewer 切换都能关闭旧文档，不会留下悬挂的 pending change。
- 版本化 diagnostics 快照在可用时会被过滤，旧版本结果不会继续污染当前编辑器视图；无版本服务端仍然兼容。
- Focused tests 能稳定覆盖协调器生命周期和编辑器宿主回调链路。

## 9. 最终建议

如果只给一个最务实的落地建议，那就是：

**先把协调器做成“宿主层单一入口 + 版本化 debounce + 明确 close 时机”，再去碰 diagnostics 过滤。**

原因很简单：只要 didOpen/didChange/didClose 的入口没有收口，后续 hover、definition、references 或 diagnostics 版本门禁都会继续长在错误的层上。

Plan complete and saved to `docs/plans/2026-03-30-code-editor-feature-5-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按任务顺序逐个实现、逐个验证

**2. Parallel Session (separate)** - 新开会话按 executing-plans skill 并行执行

**Which approach?**