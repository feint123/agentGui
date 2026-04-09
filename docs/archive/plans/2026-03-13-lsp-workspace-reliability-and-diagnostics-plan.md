# LSP Workspace Reliability And Diagnostics Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make LSP behave like a workspace-level background service in agentGui: auto-start from workspace context instead of tool-only entrypoints, self-heal on failure, continuously re-check changed language files, collect diagnostics for the full project, and expose rich error details in a popover styled consistently with the existing context-usage UI.

**Architecture:** Extend the current generic LSP runtime with a workspace coordinator layer above `LSPServerManager`. That coordinator owns project file discovery, session auto-start, document sync, retry/restart policy, and project-wide diagnostics refresh. Keep protocol transport and process launch in the existing LSP core, but move workspace lifecycle, recovery policy, and UI-facing diagnostic aggregation into explicit services so Chat/Workspace/File Editor views do not each reimplement LSP orchestration.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Foundation `Process`, JSON-RPC over stdio, existing `LSPServerManager` / `LSPClient` / `LSPDiagnosticsStore`, `WorkspaceState`, `WorkspacePanelView`, `FileEditorView`, `BlockTextEditor`, `ContextUsageRingView` popover style.

---

## 1. 实施原则

- 先做行为定标测试，再补最小实现，避免继续用 tool-path 修修补补。
- 自动启动必须以 workspace/file lifecycle 驱动，而不是消息发送或 tool 调用驱动。
- diagnostics 必须升级为“项目级缓存 + 文件级详情”，不能只盯当前打开文件。
- 恢复策略必须是显式状态机，不能只有一个手动 `restartServer(...)` 原语。
- 错误详情 UI 必须沿用现有 `ContextUsageRingView` 的 popover 视觉语言，避免额外引入一套完全不同的浮层风格。
- Phase 1 不做 rename/code action；只把 server 生命周期、同步和 diagnostics 质量做扎实。

## 2. 当前缺口归纳

- `autoStartLSPServerForSelectedFileIfNeeded(...)` 只在 [agentGui/Services/ClaudeService+Messaging.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Messaging.swift) 发消息路径被调用，且只看当前 `selectedFilePath`；用户仅切换 workspace/文件不会自动拉起 session。
- [agentGui/Services/LSP/LSPServerManager.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift) 只有 `startSession(...)` / `restartServer(...)`，没有健康检查、退避、初始化失败后重建、workspace reopen 后重连等策略层。
- [agentGui/Services/LSP/LSPClient.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift) 还没有真正的 `didOpen` / `didChange` / `didClose` / `publishDiagnostics` 协议处理链，`documentSymbols` / `workspaceSymbols` 仍是 stub。
- [agentGui/Services/LSP/LSPDiagnosticsStore.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDiagnosticsStore.swift) 现在只是 URI -> snapshot 存储，没有项目摘要、最近错误详情、按 server/session 过滤、按文件刷新原因追踪。
- [agentGui/Views/WorkspacePanelView.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift) 只展示当前选中文件的错误/警告数量，没有项目级状态，也没有错误详情弹层。
- 现有与弹框风格最接近的是 [agentGui/Views/ContextUsageRingView.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ContextUsageRingView.swift)，应直接复用其 header/detail row/progress-like information hierarchy，而不是重新发明 UI 语言。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPWorkspaceCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProjectFileIndexer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPProjectDiagnosticsSummary.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPDiagnosticsPopoverView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPWorkspaceCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProjectFileIndexerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProjectDiagnosticsSummaryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsPopoverViewTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPJSONRPCTransport.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProcessSupervisor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDiagnosticsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+WorkspaceContext.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceWorkspaceContextTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPClientTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProcessSupervisorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerManagerTests.swift`

## 4. 关键设计决策

### 4.1 自动启动的责任归属

自动启动不应继续挂在 `sendMessage(...)`。应把它提升到 `LSPWorkspaceCoordinator`，由以下事件触发：

- workspace 切换
- selected file 切换
- editor 打开文件
- 项目索引发现新的可匹配语言文件
- session 恢复时恢复上次活动的 workspace bindings

### 4.2 诊断的粒度模型

需要同时保留三层粒度：

- `per-file snapshot`: 现有 `LSPDiagnosticsSnapshot`
- `per-workspace summary`: 统计错误/警告数量、最近更新时间、受影响文件数、top errors
- `per-server runtime health`: 当前 server 状态、最近重启次数、最近错误日志

UI 和 verifier 不再直接看某个选中文件的 snapshot，而是从 summary + file details 组合读取。

### 4.3 文件变更同步策略

V1 只要求“发生变更后重新错误检查”，不要求做复杂增量 diff。优先采用：

- 文件打开时 `didOpen`
- 编辑器文本变更节流后 `didChange`
- 文件切换或关闭时 `didClose`
- workspace refresh 或外部文件变化时重新读取磁盘并重新同步对应文档

### 4.4 项目级诊断刷新边界

“自动检查整个项目空间中的代码文件”不等于每次敲一个字就全仓重扫。V1 建议分层：

- workspace 初次绑定或 server 初次启动后，对匹配文件做一次全量 open/sync + diagnostics bootstrap
- 单文件编辑后只重同步该文件
- 目录树 refresh、Git diff selection 变化、外部文件变更时，对受影响文件集合做增量重检
- 仅在 server 崩溃恢复或全局 workspace 切换后重新触发全项目 bootstrap

### 4.5 自愈策略边界

自愈必须覆盖以下状态：

- `failedToLaunch`: 命令不可执行、PATH 不可达、启动参数错误
- `crashed`: 进程异常退出
- initialize handshake timeout / failure
- diagnostics 长时间无更新但文档同步仍在发生

V1 采用有限重试 + 退避 + 状态暴露：

- 同一 workspace/server 的自动重启次数上限
- 基于最近错误类型区分“可重试”与“需要人工修复”
- UI 明确显示“自动恢复中”“已暂停自动恢复”“需要人工处理”

### 4.6 错误详情弹框风格

新的错误详情弹框必须遵循 [agentGui/Views/ContextUsageRingView.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ContextUsageRingView.swift#L57) 的结构：

- compact badge / chip 作为触发器
- popover header + status capsule
- detail rows 展示 server / file / counts / timestamps
- 列表中展示诊断 message、severity、location、source excerpt

不要直接做成 sheet，也不要做单独页面；先采用 footer 内 badge + popover。

## 5. 任务拆解

### Task 1: 建立 LSP workspace 协调层的失败测试与索引基线

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPWorkspaceCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProjectFileIndexer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPWorkspaceCoordinatorTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProjectFileIndexerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceWorkspaceContextTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖以下基线行为：

- workspace 载入后，即使用户没有发送消息，只要存在匹配语言文件，也会自动解析 profile 并启动 session
- 初次 bootstrap 会收集整个 workspace 下的匹配代码文件，而不是只看当前 `selectedFilePath`
- 当 selected file 为空但 workspace 内存在匹配文件时，仍可建立项目级 LSP 状态
- 同一 workspace 下按 server id 去重，不会因为多文件导致重复起相同 session

测试示例：

```swift
@Test func workspaceBootstrapStartsServerFromProjectFilesWithoutToolInvocation() async throws {
    let harness = LSPWorkspaceCoordinatorHarness()
    let coordinator = harness.makeCoordinator()

    try await coordinator.bootstrapWorkspace(
        workingDirectory: "/repo",
        selectedFilePath: nil,
        settings: .lspEnabledFixture()
    )

    #expect(harness.startedServerIDs == ["typescript-language-server"])
    #expect(harness.indexedFiles.contains("/repo/src/app.ts"))
}
```

**Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPWorkspaceCoordinatorTests \
  -only-testing:agentGuiTests/LSPProjectFileIndexerTests
```

Expected: FAIL because no workspace coordinator or project file indexer exists.

**Step 3: Write minimal implementation**

最小实现目标：

- `LSPProjectFileIndexer` 负责根据 `LSPServerRegistry` 的 `defaultFileGlobs` / `supportedLanguageIDs` 找到项目内候选文件
- `LSPWorkspaceCoordinator.bootstrapWorkspace(...)` 读取 workspace、建立 bindings、按 server 去重启动 session、返回 bootstrap summary

**Step 4: Run focused tests**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPWorkspaceCoordinator.swift agentGui/Services/LSP/LSPProjectFileIndexer.swift agentGuiTests/LSPWorkspaceCoordinatorTests.swift agentGuiTests/LSPProjectFileIndexerTests.swift agentGuiTests/ClaudeServiceWorkspaceContextTests.swift
git commit -m "feat: add workspace-driven lsp bootstrap coordinator"
```

### Task 2: 让自动启动从 workspace / file lifecycle 触发，而不再依赖 agent tool 路径

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+WorkspaceContext.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceWorkspaceContextTests.swift`

**Step 1: Write the failing tests**

新增测试锁定以下行为：

- 切换 workspace 后会调用 workspace bootstrap
- 选中文件变化时会触发对应 binding 的 server ensure/start
- 打开 file editor 时，即使未发消息，workspace panel status 也会从“未启动”变成“running”
- `executeLSPTool(...)` 路径仍可复用已有 session，但不再是唯一启动入口

**Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ClaudeServiceWorkspaceContextTests
```

Expected: FAIL because auto-start is still wired only from `sendMessage(...)`.

**Step 3: Write minimal implementation**

最小实现要求：

- 将 `autoStartLSPServerForSelectedFileIfNeeded(...)` 收敛为 coordinator 的一个子能力，旧方法仅作为兼容 wrapper
- 在 `WorkspacePanelView.loadFromWorkspaceState()`、`FileEditorView.onChange(of: workspaceState.selectedFile)`、必要的 editor attach 路径里调用 coordinator bootstrap / ensure
- `ClaudeService` 暴露单一 `ensureWorkspaceLSPState(...)` 接口，避免多个 View 直接调用 manager

**Step 4: Run focused tests**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolDispatch.swift agentGui/Services/ClaudeService+WorkspaceContext.swift agentGui/Views/WorkspacePanelView.swift agentGui/Views/FileEditorView.swift agentGui/Views/ChatView.swift agentGui/Utilities/WorkspaceState.swift agentGuiTests/ClaudeServiceWorkspaceContextTests.swift
git commit -m "refactor: trigger lsp auto start from workspace lifecycle"
```

### Task 3: 补齐文档同步与 publishDiagnostics 协议链，支持文件变更后自动重检

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPJSONRPCTransport.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPClientTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerManagerTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- `initializeSession(...)` 之后支持 `didOpen` / `didChange` / `didClose` notification
- 收到 `textDocument/publishDiagnostics` notification 时，transport 能路由到 client，client 能写入 diagnostics store
- 编辑器文本变化后，节流发送 `didChange` 并刷新该文件 diagnostics snapshot
- 外部文件变化或 reopen 时，文档版本能递增且重新检查错误

测试示例：

```swift
@Test func clientPublishesDiagnosticsFromServerNotification() async throws {
    let harness = LSPClientNotificationHarness()
    let client = harness.makeClient()

    try await client.initializeSession(server: .testTypeScript, workspaceRoot: "/repo")
    harness.injectPublishDiagnostics(
        uri: "file:///repo/src/app.ts",
        diagnostics: [.init(message: "Type mismatch", severity: .error)]
    )

    let snapshot = try #require(client.diagnosticsSnapshot(workspaceRoot: "/repo", uri: "file:///repo/src/app.ts"))
    #expect(snapshot.diagnostics.count == 1)
}
```

**Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPClientTests \
  -only-testing:agentGuiTests/LSPServerManagerTests
```

Expected: FAIL because diagnostics notifications and document sync are not implemented.

**Step 3: Write minimal implementation**

实现范围：

- `LSPJSONRPCTransport` 增加 notification payload 回调，而不只是 method 名字
- `LSPClient` 增加 `openDocument`, `changeDocument`, `closeDocument` 对应的 LSP notifications
- `LSPServerManager` 提供 `syncDocument(...)` / `closeDocument(...)` API
- `FileEditorView` 或编辑器层在文本变化时调用 manager sync（带节流）

**Step 4: Run focused tests**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPClient.swift agentGui/Services/LSP/LSPJSONRPCTransport.swift agentGui/Services/LSP/LSPServerManager.swift agentGui/Views/FileEditorView.swift agentGui/Views/Editor/BlockTextEditor.swift agentGuiTests/LSPClientTests.swift agentGuiTests/LSPServerManagerTests.swift
git commit -m "feat: sync lsp documents and publish diagnostics on file changes"
```

### Task 4: 建立项目级 diagnostics 汇总与全项目重检策略

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPProjectDiagnosticsSummary.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDiagnosticsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPWorkspaceCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+WorkspaceContext.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProjectDiagnosticsSummaryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsStoreTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- workspace summary 能聚合整个项目的 diagnostics 总数、受影响文件数、最新更新时间、top errors
- coordinator 的 bootstrap 会为全部匹配文件建立初始同步任务，而不是只同步选中文件
- workspace 切换或 server 恢复后会重新做全项目 diagnostics bootstrap

**Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPDiagnosticsStoreTests \
  -only-testing:agentGuiTests/LSPProjectDiagnosticsSummaryTests \
  -only-testing:agentGuiTests/LSPWorkspaceCoordinatorTests
```

Expected: FAIL because there is no project-level summary or bootstrap refresh strategy.

**Step 3: Write minimal implementation**

实现要点：

- `LSPDiagnosticsStore` 增加 `workspaceSummary(...)` / `recentDiagnostics(...)` / `filesWithDiagnostics(...)`
- `LSPWorkspaceCoordinator` 在 bootstrap 后对索引文件集做 open/sync bootstrap，并记录完成状态
- `ClaudeService+WorkspaceContext` 改为默认返回项目级错误/警告统计，再补当前文件的局部细节

**Step 4: Run focused tests**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/LSPProjectDiagnosticsSummary.swift agentGui/Services/LSP/LSPDiagnosticsStore.swift agentGui/Services/LSP/LSPWorkspaceCoordinator.swift agentGui/Services/ClaudeService+WorkspaceContext.swift agentGuiTests/LSPDiagnosticsStoreTests.swift agentGuiTests/LSPProjectDiagnosticsSummaryTests.swift agentGuiTests/LSPWorkspaceCoordinatorTests.swift
git commit -m "feat: add project-wide lsp diagnostics aggregation"
```

### Task 5: 为 LSP 增加明确的自愈状态机与恢复策略

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProcessSupervisor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPToolFacade.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPWorkspaceCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProcessSupervisorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerManagerTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- crash 后 coordinator/manager 会按退避策略自动重启，达到上限后进入 paused/degraded 状态
- initialize handshake 失败后不会卡在“running”，而会回到可诊断状态并记录错误原因
- 文件同步持续发生但 diagnostics 长时间无更新时，会触发一次健康检查重连
- `serverStatus(...)` 输出包含“自动恢复中 / 已暂停自动恢复 / 最近恢复失败原因”

**Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPProcessSupervisorTests \
  -only-testing:agentGuiTests/LSPServerManagerTests \
  -only-testing:agentGuiTests/LSPToolFacadeTests
```

Expected: FAIL because current implementation only exposes manual restart.

**Step 3: Write minimal implementation**

建议引入：

- `LSPRecoveryPolicy`：最大重试次数、退避秒数、可重试错误分类
- `LSPServerRuntimeHealth`：最近成功 handshake 时间、最近 diagnostics 时间、最近 sync 时间
- `LSPWorkspaceCoordinator.recoverSessionIfNeeded(...)`

**Step 4: Run focused tests**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPProcessSupervisor.swift agentGui/Services/LSP/LSPServerManager.swift agentGui/Services/LSP/LSPToolFacade.swift agentGui/Services/LSP/LSPWorkspaceCoordinator.swift agentGuiTests/LSPProcessSupervisorTests.swift agentGuiTests/LSPServerManagerTests.swift
git commit -m "feat: add lsp self-healing and recovery policy"
```

### Task 6: 实现项目级错误详情 popover，视觉与上下文用量弹框对齐

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/LSPDiagnosticsPopoverView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+WorkspaceContext.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsPopoverViewTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- footer 中的错误/警告 chip 可触发 popover
- popover header、status capsule、detail rows、分组列表风格与 `ContextUsageRingView` 一致
- popover 能显示：server、workspace 统计、最近错误详情、文件路径、位置、上下文摘要
- 无 diagnostics 时显示明确 empty state，而不是空白弹层

**Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPDiagnosticsPopoverViewTests \
  -only-testing:agentGuiTests/ClaudeServiceWorkspaceContextTests
```

Expected: FAIL because no popover exists.

**Step 3: Write minimal implementation**

实现要求：

- 新增 `LSPDiagnosticsPopoverView`，组件化 header/detail row/diagnostic row
- `WorkspacePanelView` 中错误/警告 chip 变为 popover 触发器
- `ClaudeService+WorkspaceContext` 返回 popover 所需的 summary + recent diagnostics data model

**Step 4: Run focused tests**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/LSPDiagnosticsPopoverView.swift agentGui/Views/WorkspacePanelView.swift agentGui/Services/ClaudeService+WorkspaceContext.swift agentGuiTests/LSPDiagnosticsPopoverViewTests.swift agentGuiTests/ClaudeServiceWorkspaceContextTests.swift
git commit -m "feat: add lsp diagnostics popover in workspace panel"
```

### Task 7: 回归工具路径、workspace 状态和现有 LSP 测试

**Files:**
- Modify as needed after regression failures in existing files listed above
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPToolFacadeTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPWorkspaceResolverTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPSettingsTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`

**Step 1: Run the full focused LSP regression suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPWorkspaceResolverTests \
  -only-testing:agentGuiTests/LSPToolFacadeTests \
  -only-testing:agentGuiTests/LSPSettingsTests \
  -only-testing:agentGuiTests/LSPServerRegistryTests \
  -only-testing:agentGuiTests/LSPJSONRPCTransportTests \
  -only-testing:agentGuiTests/LSPProcessSupervisorTests \
  -only-testing:agentGuiTests/LSPDocumentStoreTests \
  -only-testing:agentGuiTests/LSPDiagnosticsStoreTests \
  -only-testing:agentGuiTests/LSPServerManagerTests \
  -only-testing:agentGuiTests/LSPClientTests \
  -only-testing:agentGuiTests/ClaudeServiceWorkspaceContextTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests
```

Expected: PASS.

**Step 2: Run quality smoke if the suite passes**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS, or only unrelated pre-existing failures.

**Step 3: Commit final integration pass**

```bash
git add agentGui agentGuiTests docs/plans/2026-03-13-lsp-workspace-reliability-and-diagnostics-plan.md
git commit -m "feat: harden workspace lsp lifecycle and diagnostics"
```

## 6. 额外实现说明

### 6.1 与你提出的 5 点需求一一映射

1. 自动匹配语言启动 LSP 服务：通过 `LSPWorkspaceCoordinator` 从 workspace/file lifecycle 驱动，替代“仅 tool 启动”。
2. 完善自我恢复机制：通过 `LSPRecoveryPolicy` + health state + bounded retry/backoff 实现。
3. 语言文件发生变更后重新错误检查：通过 `didChange` / reopen / external refresh 同步链实现。
4. 自动检查整个项目空间：通过 `LSPProjectFileIndexer` + workspace bootstrap + project diagnostics summary 实现。
5. 支持查看错误具体信息且 UI 风格一致：通过 `LSPDiagnosticsPopoverView` 复用 `ContextUsageRingView` 风格实现。

### 6.2 风险与注意事项

- 当前 `LSPClient` 还没有真正消费 server 发回的 diagnostics notification；这是整条计划的最大技术前提，必须优先完成。
- “全项目自动检查”需要控制规模。超大仓库必须允许后续按上限分批 bootstrap，否则首次绑定会卡 UI。
- 如果 TypeScript / Python server 对未打开文件不主动返回 diagnostics，需要 coordinator 做“bootstrap open/close”策略，而不是假设 server 会自己扫描磁盘。
- Swift profile 目前仍是 stub，不应把这轮计划误扩展到 SourceKit 特殊适配。

## 7. 完成定义

- 用户切换到有可匹配语言文件的 workspace 后，不用调用 agent tool 也能看到对应 LSP server 自动启动。
- 服务器崩溃或初始化失败后，UI 能显示恢复状态，系统会进行有限自愈重试。
- 当前编辑文件变更后会自动重检 diagnostics。
- workspace footer 默认展示项目级错误/警告统计，而不是仅当前文件统计。
- 用户可通过统一风格 popover 查看错误详情、文件位置和上下文摘要。

Plan complete and saved to `docs/plans/2026-03-13-lsp-workspace-reliability-and-diagnostics-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?