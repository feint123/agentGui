# Generic LSP Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a generic multi-language LSP client runtime and managed server layer for agentGui, with JS/TS/Python as first-class built-in profiles and a clean extension seam for future custom language servers.

**Architecture:** Use a layered design: pure value-model contracts at the bottom, a transport/session/process runtime in the middle, and a small tool-facing facade at the top. Apply Registry + Strategy for server selection, Supervisor for process lifecycle, Adapter for language-specific quirks, Facade for tool dispatch, and Repository-style state stores for diagnostics and workspace bindings.

**Tech Stack:** Swift 6, Swift Testing, SwiftData, SwiftUI, Foundation `Process`, JSON-RPC over stdio, existing `ClaudeService`, `ToolRegistry`, `ToolsetResolver`, workflow runtime, verification coordinator.

---

## 1. 实施原则

- 先完成 Phase 1 的通用能力，不在第一轮把 Swift/Xcode 特殊约束塞进核心 runtime。
- 严格按 `@test-driven-development` 执行：先锁定纯模型和调度契约，再接 transport，再接 UI 和工具层。
- 所有 server 选择、状态、能力暴露都走统一模型，不允许在 `ClaudeService+ToolDispatch` 里硬编码语言分支。
- 第一版只做只读语义能力和受控 server 管理，不做 rename/code action/workspace edit。
- 优先让失败可诊断：初始化失败、命令缺失、capability 缺失、root 解析失败都必须变成结构化状态，而不是静默降级。
- 每个任务结束都要有 focused tests；只有当纯单元测试稳定后，才接入更高层的 `ClaudeService` 和 SwiftUI 设置入口。

## 2. 设计模式落位

### 2.1 Registry Pattern

用 `LSPServerRegistry` 统一维护内建 profile 与用户自定义 profile，避免工具层、设置层、运行时各自保存一份 server 配置真相。

### 2.2 Strategy Pattern

用 `LSPWorkspaceResolver` 按文件后缀、工作目录规则、用户绑定策略选择 server。JS/TS/Python、自定义小说语言都只是不同策略输入，不应该变成 `switch language` 的硬编码散点。

### 2.3 Supervisor Pattern

用 `LSPProcessSupervisor` 承担进程启动、重启、健康检查、崩溃恢复和 backoff 策略。不要把 `Process` 生命周期散落到 `ClaudeService` 或 View 中。

### 2.4 Adapter Pattern

用 `LSPServerAdapter` 抽象语言特例。第一阶段只提供通用 adapter；后续 Swift/Xcode 用 `SourceKitLSPAdapter` 承接 BSP / build metadata 问题，而不是污染通用 core。

### 2.5 Facade Pattern

用 `LSPToolFacade` 对工具层暴露稳定 API，例如 `definition`、`hover`、`references`、`diagnostics`、`listServers`、`serverStatus`，屏蔽 JSON-RPC、session 复用和状态细节。

### 2.6 Repository / Store Pattern

用 `LSPDiagnosticsStore`、`LSPWorkspaceBindingStore` 维护运行时可观察状态。验证器、工作流、UI 都从 store 读取，不直接窥探 transport 或 `Process`。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPServerDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPServerCapabilities.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPWorkspaceBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDocumentSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPJSONRPCTransport.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProcessSupervisor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPWorkspaceResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDocumentStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDiagnosticsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPToolFacade.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPWorkspaceResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPJSONRPCTransportTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProcessSupervisorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDocumentStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerManagerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPToolFacadeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPSettingsTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolsetResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopVerificationCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolsetResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolDispatchBindingTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`

## 4. 关键设计决策

### 4.1 Profile 是真源，不是 View 状态

`LSPServerDefinition` 必须承载以下内容：

- `id`
- `displayName`
- `launchCommand`
- `launchArguments`
- `supportedLanguageIDs`
- `rootMarkers`
- `defaultFileGlobs`
- `transportKind`
- `capabilityHints`
- `adapterKind`
- `healthCheckMode`

这些字段只能在 registry/profile 层定义一次，不能在设置 UI、resolver、tool facade 中重复保存副本。

### 4.2 Session 的边界是 workspace + server profile

`LSPServerManager` 第一版按 `(workspaceRoot, serverProfileID)` 复用会话，不按“每个文件一个 server”建进程，也不按“整个 app 一个 server”做全局单例。

### 4.3 能力暴露必须 capability-aware

工具层不允许假设所有 server 都支持 `references`、`workspaceSymbol`、`hover`。`LSPClient` 拿到 initialize 结果后要缓存 capability snapshot，`LSPToolFacade` 按 capability 决定返回成功、降级还是结构化错误。

### 4.4 自定义语言 server 先受限，不做任意脚本执行

V1 允许用户保存自定义 profile，但只允许：

- 命令路径
- 参数模板
- root markers
- language ids / file patterns
- 环境变量白名单

不允许把任意 shell pipeline 当 profile 直接执行。

### 4.5 diagnostics 是共享状态，不是一次性工具结果

`publishDiagnostics` 必须持久化到 `LSPDiagnosticsStore`，并能被以下路径复用：

- `lsp_diagnostics` 工具
- verifier 证据补强
- workflow prompt 注入
- 设置页或诊断页状态摘要

## 5. 任务拆解

### Task 1: 建立 LSP 纯模型与 server registry

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPServerDefinition.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPServerCapabilities.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPWorkspaceBinding.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerRegistryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`

**Step 1: 写失败测试，锁定 registry 契约**

新增 `LSPServerRegistryTests.swift`，至少覆盖：

- 默认内建 profile 包含 JS/TS、Python 两组
- profile 能声明多个 language ids 和 file globs
- `AppSettings` 能暴露 LSP 总开关、自动启动开关、默认路由策略、自定义 profile JSON
- 自定义 profile 覆盖内建 profile 时，registry 拒绝重复 id

测试示例：

```swift
import Testing
@testable import agentGui

struct LSPServerRegistryTests {

    @Test func builtInProfilesIncludeTypeScriptAndPython() throws {
        let registry = LSPServerRegistry(settings: .testFixture())

        let ids = Set(registry.allDefinitions().map(\.id))

        #expect(ids.contains("typescript-language-server"))
        #expect(ids.contains("python-lsp"))
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/LSPServerRegistryTests
```

Expected: FAIL，因为 LSP 模型和 registry 还不存在。

**Step 3: 写最小实现**

模型建议：

```swift
enum LSPAdapterKind: String, Codable, Sendable {
    case generic
    case sourcekit
}

struct LSPServerDefinition: Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let launchCommand: String
    let launchArguments: [String]
    let supportedLanguageIDs: [String]
    let defaultFileGlobs: [String]
    let rootMarkers: [String]
    let adapterKind: LSPAdapterKind
}
```

`AppSettings` 新增最小字段：

- `enableLSPTools`
- `autoStartLSPServers`
- `lspDefaultRoutingMode`
- `lspCustomServerProfilesJSON`

**Step 4: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/LSPServerRegistryTests -only-testing:agentGuiTests/MemoryRuntimeSettingsTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/LSPServerDefinition.swift agentGui/Models/LSPServerCapabilities.swift agentGui/Models/LSPWorkspaceBinding.swift agentGui/Models/AppSettings.swift agentGuiTests/LSPServerRegistryTests.swift
git commit -m "feat: add lsp server definitions and settings"
```

### Task 2: 建立 workspace resolver 与 profile 选择策略

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPWorkspaceResolver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPWorkspaceResolverTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`

**Step 1: 写失败测试，固定路由规则**

覆盖以下行为：

- `.ts` / `.tsx` 优先命中 TypeScript profile
- `.py` 命中 Python profile
- 同一 workspace 下不同文件允许绑定不同 profile
- 手动绑定优先级高于自动识别
- 未命中 profile 时返回结构化未绑定状态，而不是 `nil` + 静默失败

测试示例：

```swift
@Test func resolverMatchesTypeScriptFilesByExtension() throws {
    let resolver = LSPWorkspaceResolver()
    let registry = LSPServerRegistry(settings: .testFixture())

    let binding = try #require(
        resolver.resolve(
            filePath: "/repo/src/app.ts",
            workingDirectory: "/repo",
            registry: registry,
            settings: .testFixture()
        )
    )

    #expect(binding.serverID == "typescript-language-server")
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/LSPWorkspaceResolverTests
```

Expected: FAIL。

**Step 3: 写最小实现**

先只支持：

- `automatic`
- `manualBinding`
- `disabled`

不要在这一阶段做多根工作区或复杂优先级合并。

**Step 4: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/LSPWorkspaceResolverTests -only-testing:agentGuiTests/LSPServerRegistryTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPWorkspaceResolver.swift agentGuiTests/LSPWorkspaceResolverTests.swift agentGui/Models/AppSettings.swift
git commit -m "feat: add lsp workspace routing"
```

### Task 3: 建立 JSON-RPC transport、document store 与 process supervisor

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPJSONRPCTransport.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDocumentStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProcessSupervisor.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDocumentSnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPJSONRPCTransportTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDocumentStoreTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProcessSupervisorTests.swift`

**Step 1: 写 transport 失败测试**

覆盖：

- 能编码 `Content-Length` framing
- 能从碎片化输入流重组 JSON-RPC 消息
- request id 与 response 正确匹配
- transport 收到 server notification 时会走通知回调

**Step 2: 写 document store 失败测试**

覆盖：

- `didOpen` 后版本从 `1` 开始
- `didChange` 自增版本
- 重复内容更新不会错误回退版本
- `didClose` 后文档被移除

**Step 3: 写 supervisor 失败测试**

覆盖：

- 启动成功更新状态为 `running`
- 启动命令缺失更新状态为 `failedToLaunch`
- 异常退出进入 `crashed` 并累加 `restartCount`
- 手动停止不会被误判为崩溃

**Step 4: 写最小实现**

此阶段不要接真实 LSP server，只用可控 fake process / fake stream 验证 runtime 行为。

状态模型建议：

```swift
enum LSPServerRuntimeState: Equatable {
    case idle
    case starting
    case running(pid: Int32?)
    case degraded(reason: String)
    case failedToLaunch(reason: String)
    case crashed(reason: String, restartCount: Int)
    case stopped
}
```

**Step 5: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPJSONRPCTransportTests \
  -only-testing:agentGuiTests/LSPDocumentStoreTests \
  -only-testing:agentGuiTests/LSPProcessSupervisorTests
```

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Services/LSP/LSPJSONRPCTransport.swift agentGui/Services/LSP/LSPDocumentStore.swift agentGui/Services/LSP/LSPProcessSupervisor.swift agentGui/Models/LSPDocumentSnapshot.swift agentGuiTests/LSPJSONRPCTransportTests.swift agentGuiTests/LSPDocumentStoreTests.swift agentGuiTests/LSPProcessSupervisorTests.swift
git commit -m "feat: add lsp transport document store and supervisor"
```

### Task 4: 建立 LSP client、diagnostics store 与 server manager

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPDiagnosticsStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerAdapter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsStoreTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerManagerTests.swift`

**Step 1: 写 manager 失败测试**

覆盖：

- 同一 `(workspaceRoot, serverID)` 复用已有 session
- 不同 `serverID` 不会错误复用同一个 session
- `initialize` 成功后缓存 capability snapshot
- `publishDiagnostics` 会写入 `LSPDiagnosticsStore`
- `restartServer` 会先 stop 再创建新 session

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/LSPServerManagerTests -only-testing:agentGuiTests/LSPDiagnosticsStoreTests
```

Expected: FAIL。

**Step 3: 写最小实现**

`LSPClient` 先暴露：

- `initializeSession(...)`
- `openDocument(...)`
- `updateDocument(...)`
- `closeDocument(...)`
- `definition(...)`
- `references(...)`
- `hover(...)`
- `documentSymbols(...)`
- `workspaceSymbols(...)`
- `diagnosticsSnapshot(...)`

不要在这个任务里实现 completion、rename、code action。

**Step 4: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPServerManagerTests \
  -only-testing:agentGuiTests/LSPDiagnosticsStoreTests \
  -only-testing:agentGuiTests/LSPProcessSupervisorTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPClient.swift agentGui/Services/LSP/LSPDiagnosticsStore.swift agentGui/Services/LSP/LSPServerManager.swift agentGui/Services/LSP/LSPServerAdapter.swift agentGui/Models/LSPDiagnosticsSnapshot.swift agentGuiTests/LSPDiagnosticsStoreTests.swift agentGuiTests/LSPServerManagerTests.swift
git commit -m "feat: add lsp client diagnostics store and server manager"
```

### Task 5: 将 LSP 能力接入工具定义、解析和分发

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPToolFacade.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolsetResolver.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolRegistryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolsetResolverTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolDispatchBindingTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPToolFacadeTests.swift`

**Step 1: 写失败测试，固定工具契约**

覆盖以下行为：

- registry 暴露 `lsp_definition`、`lsp_references`、`lsp_hover`、`lsp_document_symbols`、`lsp_workspace_symbols`、`lsp_diagnostics`
- registry 暴露 `lsp_list_servers`、`lsp_server_status`
- `ToolsetResolver` 在 `enableLSPTools = false` 时排除全部 LSP 工具
- dispatch binding 能验证 `executorKey` 绑定到 LSP facade 路径

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolRegistryTests \
  -only-testing:agentGuiTests/ToolsetResolverTests \
  -only-testing:agentGuiTests/ToolDispatchBindingTests \
  -only-testing:agentGuiTests/LSPToolFacadeTests
```

Expected: FAIL。

**Step 3: 写最小实现**

建议 executor keys：

- `lsp.definition`
- `lsp.references`
- `lsp.hover`
- `lsp.documentSymbols`
- `lsp.workspaceSymbols`
- `lsp.diagnostics`
- `lsp.listServers`
- `lsp.serverStatus`

`ClaudeService+ToolDispatch` 不直接解析 JSON-RPC 参数，只负责把规范化输入转给 `LSPToolFacade`。

**Step 4: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolRegistryTests \
  -only-testing:agentGuiTests/ToolsetResolverTests \
  -only-testing:agentGuiTests/ToolDispatchBindingTests \
  -only-testing:agentGuiTests/LSPToolFacadeTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPToolFacade.swift agentGui/Services/ToolRegistry.swift agentGui/Services/ToolsetResolver.swift agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ClaudeService+ToolDispatch.swift agentGuiTests/ToolRegistryTests.swift agentGuiTests/ToolsetResolverTests.swift agentGuiTests/ToolDispatchBindingTests.swift agentGuiTests/LSPToolFacadeTests.swift
git commit -m "feat: expose lsp tools through registry and dispatch"
```

### Task 6: 接入设置页与 server 管理 UI 状态

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPSettingsTests.swift`

**Step 1: 写失败测试，锁定设置模型行为**

覆盖：

- `AppSettings` 暴露 LSP 默认值
- 设置页保存后 profile JSON 可 round-trip
- 关闭 `enableLSPTools` 会让自动启动开关禁用或无效

**Step 2: 写最小实现**

在 Settings 的“工具”分区增加：

- 启用 LSP 工具
- 自动启动语言服务器
- 默认路由策略 picker
- 内建 profile 摘要
- 自定义 profile JSON 编辑入口或文本区

第一版不要做复杂 profile 列表编辑器，先用受控文本区 + 校验消息。

**Step 3: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/LSPSettingsTests
```

Expected: PASS。

**Step 4: Commit**

```bash
git add agentGui/ContentView.swift agentGui/Models/AppSettings.swift agentGuiTests/LSPSettingsTests.swift
git commit -m "feat: add lsp settings and profile management ui"
```

### Task 7: 将 diagnostics 与 server 状态接入 verifier 和 workflow context

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopVerificationCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`

**Step 1: 写失败测试，锁定语义证据注入行为**

覆盖：

- verifier 证据文本可包含 diagnostics 摘要
- workflow prompt 在有 active file / selection 时可注入 LSP server 状态与 diagnostics 概览
- diagnostics 不存在时明确写 `none`，而不是省略整段

测试示例：

```swift
@Test func verifierEvidenceTextIncludesLSPDiagnosticsSummary() {
    let text = AgentLoopVerificationCoordinator.buildExecutionEvidenceTextForTests(
        executionEvidence: [.builtinTool],
        toolCalls: []
    )

    #expect(text.contains("High-level signals"))
}
```

这里需要扩充 helper，使其接收 diagnostics snapshot，而不是继续只看 tool calls。

**Step 2: 写最小实现**

新增的 verifier 注入仅包含摘要字段：

- active server id
- server state
- diagnostics count by severity
- first 3 diagnostics preview

不要把整份 diagnostics 原文无脑注入 prompt。

**Step 3: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests \
  -only-testing:agentGuiTests/LSPServerManagerTests
```

Expected: PASS。

**Step 4: Commit**

```bash
git add agentGui/Services/AgentLoopVerificationCoordinator.swift agentGui/Services/WorkflowAgentRunner.swift agentGuiTests/AgentLoopVerificationCoordinatorTests.swift
git commit -m "feat: inject lsp diagnostics into verifier and workflow context"
```

### Task 8: 内建 JS/TS、Python profile 验证与后续 Swift adapter 预留

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/lsp-integration-research-2026-03-13.md`

**Step 1: 写失败测试，锁定 profile 元数据完整性**

覆盖：

- TypeScript profile 默认命令、参数、root markers 完整
- Python profile 默认命令、参数、root markers 完整
- Swift profile 可以作为 `disabled by default` 的 adapter stub 存在，但不会自动进入 Phase 1 路由

**Step 2: 写最小实现**

TypeScript 建议内建 profile：

- command: `typescript-language-server`
- args: `--stdio`
- markers: `package.json`, `tsconfig.json`, `jsconfig.json`

Python 建议内建 profile：

- command: `pylsp` 或 `pyright-langserver`
- args: `--stdio` 或 `--stdio` 对应格式
- markers: `pyproject.toml`, `requirements.txt`, `.venv`

Swift 只保留 stub profile：

- adapterKind: `.sourcekit`
- 默认不自动启用

**Step 3: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPServerRegistryTests \
  -only-testing:agentGuiTests/LSPWorkspaceResolverTests
```

Expected: PASS。

**Step 4: Commit**

```bash
git add agentGui/Services/LSP/LSPServerRegistry.swift agentGui/Services/LSP/LSPServerAdapter.swift docs/lsp-integration-research-2026-03-13.md
git commit -m "feat: add built-in js ts python lsp profiles"
```

## 6. 集成验收

在所有任务完成后，运行：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolRegistryTests \
  -only-testing:agentGuiTests/ToolsetResolverTests \
  -only-testing:agentGuiTests/ToolDispatchBindingTests \
  -only-testing:agentGuiTests/LSPServerRegistryTests \
  -only-testing:agentGuiTests/LSPWorkspaceResolverTests \
  -only-testing:agentGuiTests/LSPJSONRPCTransportTests \
  -only-testing:agentGuiTests/LSPProcessSupervisorTests \
  -only-testing:agentGuiTests/LSPDocumentStoreTests \
  -only-testing:agentGuiTests/LSPDiagnosticsStoreTests \
  -only-testing:agentGuiTests/LSPServerManagerTests \
  -only-testing:agentGuiTests/LSPToolFacadeTests \
  -only-testing:agentGuiTests/LSPSettingsTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests
```

Expected:

- 所有 LSP 相关新测试通过
- 现有工具注册/解析/验证器测试不回归
- 没有因为 AppSettings 新字段导致持久化默认值测试失败

## 7. 非目标

- 本计划不实现 rename、code action、workspace edit。
- 本计划不在第一阶段实现复杂的 profile 可视化编辑器。
- 本计划不解决 Swift/Xcode 的 BSP / `buildServer.json` 适配，只预留 adapter seam。
- 本计划不把 diagnostics 做成完整 IDE 面板，只做状态摘要和工具可消费结果。

## 8. 风险补充

- 如果真实 LSP server 在 CI 或本地环境不可用，优先保证 fake transport / fake process 单元测试覆盖，不要让外部依赖阻塞核心 runtime 设计。
- 如果 `AppSettings` 新增字段触发迁移问题，先补 `PersistenceMigrationTests` 再继续扩展 UI。
- 如果 `ClaudeService+ToolDispatch` 开始膨胀，立刻把参数规范化逻辑下沉到 `LSPToolFacade` 或请求构造器，不要继续加 `switch` 分支细节。

## 9. 后续阶段提示

Phase 2 可以继续做：

- 自定义 profile 表单化编辑
- `lsp_restart_server` / `lsp_rebind_server` 这类受控管理动作
- diagnostics 与 Reliability Center 的更深整合

Phase 3 再做：

- `SourceKitLSPAdapter`
- BSP / `buildServer.json` 探测
- Swift/Xcode 定向恢复指引

Plan complete and saved to `docs/plans/2026-03-13-generic-lsp-runtime-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?