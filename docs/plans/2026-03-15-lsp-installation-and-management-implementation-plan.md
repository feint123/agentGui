# LSP Installation And Management Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a modular LSP service platform for agentGui that keeps Python as the only built-in profile, adds one-click installation/configuration for mainstream languages, and introduces a unified management UI for service status and lifecycle operations.

**Architecture:** Keep the existing generic LSP runtime and diagnostics pipeline, but add a provider/install layer above the runtime and a presentation layer above the state stores. Separate “what can be installed”, “what is configured as a runtime service”, “what is currently running”, and “what the UI shows”, so future language additions do not require rewriting the LSP core.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, SwiftData, Foundation `Process`, existing `LSPServerRegistry` / `LSPServerManager` / `LSPProcessSupervisor`, `AppSettings`, `SettingsToolsView`, `WorkspacePanelView`.

---

## 0. 当前执行状态（2026-03-15）

- 已完成 Task 1 到 Task 8 的主链最小实现：provider/catalog、Python-only built-in registry、安装协调器、服务状态仓库、设置页管理 UI、服务动作 wiring、工作区 footer 管理入口、主流语言 provider 目录。
- 已把安装协调器从“仅做 executable probe”升级为真实受管安装执行链：
  - `npm` 用于 TypeScript / JavaScript
  - `brew` 用于 `clangd` 与 `jdtls`
  - `go install` 用于 `gopls`
  - `cargo install` 用于 `rust-analyzer`
- 所有受管安装产物现在统一落到 `~/.agentgui/lsp-server`，并通过受管 `bin` 目录下的 wrapper 或 symlink 作为 runtime 可执行入口。
- 已补齐安装可视化基础能力：共享安装协调器现在保留安装进度、版本探测结果和最近失败日志，设置页与工作区管理入口共享同一份安装状态来源。
- 已新增工作区侧边栏中的 LSP 管理 popover 入口，并统一了中文状态文案的展示色彩映射。
- 已通过完整的 LSP 非 UI 单元测试集，包括 provider、install coordinator、service state、management view model、registry、server manager、workspace context、resolver、workspace coordinator、project indexer、tool facade、diagnostics presentation。
- 本次会话明确未运行任何 UI tests。
- 本次会话也未运行 `Quality Smoke`，因为用户要求避免 UI 测试，而当前 smoke 任务并不保证只覆盖非 UI 路径。

当前仍属于“可工作的最小闭环”，尚未完成的收尾项主要是：

- Task 9 的文档归档与偏差说明补充
- 安装日志历史目前以内存中的近期记录为主，尚未做持久化归档
- 失败后重试策略和更强的 repair 语义仍可继续增强
- 更细粒度的日志查看、版本展示、配置/重配置和工作区绑定管理仍可继续增强

## 1. 实施原则

- 严格按 `@test-driven-development` 执行，先锁定 provider、安装状态、迁移和 UI presentation 契约，再接真实实现。
- 不推翻现有 LSP runtime；优先在现有 `Services/LSP` 体系上增量演进，避免把“安装器需求”变成“重写 LSP”。
- Python 继续走统一平台抽象，只是默认出厂 provider，不允许因为“内建保留”而写出额外的旁路逻辑。
- 一键安装、状态管理、工作区摘要、设置页 UI 必须共享同一份状态真相，不能各自拼接判断逻辑。
- 自定义 profile 仍然保留，但必须纳入统一目录与状态管理，不允许出现“官方服务能管理，自定义服务看不到”的双轨体系。
- 任何失败都要结构化：缺少命令、PATH 不可达、安装器不可用、版本探测失败、配置未完成、进程握手失败都要进入统一错误模型。

## 2. 当前代码落点

本次实现主要围绕以下现有文件展开：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPServerDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProcessSupervisor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+WorkspaceContext.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsToolsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerManagerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPSettingsTests.swift`

已知现状：

- registry 目前内建了 TypeScript/JavaScript、Python、Swift stub。
- 设置页当前只有 LSP 开关、自动启动、默认路由和自定义 profile JSON。
- 工作区 footer 只有摘要展示和 diagnostics popover，没有服务级管理能力。
- runtime 已经能启动和重启 session，但还没有“已安装/未安装/待修复/可重检”这类更高层状态。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPProviderDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPManagedServiceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPInstallResult.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProviderCatalog.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPInstallStrategy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPInstallCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServiceStateStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/LSPManagementViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/LSPManagementSectionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/LSPServiceRowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/LSPServiceDetailView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProviderCatalogTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPInstallCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServiceStateStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPManagementViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPMigrationTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPServerDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProcessSupervisor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+WorkspaceContext.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsToolsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerManagerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPSettingsTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceWorkspaceContextTests.swift`

## 4. 关键架构决策

### 4.1 Provider Catalog 与 Runtime Registry 分离

`LSPProviderCatalog` 负责描述“可安装服务”，例如语言覆盖、推荐命令、安装方式、预检规则、默认 profile 模板；`LSPServerRegistry` 只负责“当前可路由的 runtime definitions”。

### 4.2 Python 仍走统一 provider 链路

Python 保留为唯一 built-in provider，但要和其他 provider 一样拥有安装状态、配置状态和 UI 展示模型，避免后续继续出现特殊分支。

### 4.3 安装状态与运行状态必须拆开

至少要区分：

- provider 存在但未安装
- 已安装但未配置为 runtime definition
- 已配置但未运行
- 运行中
- 配置异常
- 启动失败
- 运行崩溃

### 4.4 管理 UI 只消费 presentation model

SwiftUI 层只读取 `LSPManagementViewModel` 暴露的 `LSPServicePresentation` 列表与动作接口，不直接拼接 `AppSettings`、`LSPServerManager` 和 `Process` 的细节。

### 4.5 迁移优先于破坏性收敛

把 registry 收敛为 Python-only built-in 时，必须同时补 migration，确保历史 JS/TS/Swift stub 或已有自定义绑定不会静默丢失。

## 5. 任务拆解

### Task 1: 建立 provider、安装结果与服务状态的纯模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPProviderDefinition.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPManagedServiceState.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPInstallResult.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProviderCatalogTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPServerDefinition.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- provider 可声明 `id`、`displayName`、`supportedLanguageIDs`、`recommendedInstallMethod`、`isBuiltIn`、`defaultServerTemplate`
- 服务状态可区分安装、配置、运行、错误摘要
- Python provider 标记为 built-in，JS/TS、Go、Rust、Java、C/C++ 标记为 installable

测试示例：

```swift
@Test func pythonProviderIsBuiltInButTypeScriptIsInstallable() {
    let catalog = LSPProviderCatalog.builtInCatalog()

    #expect(catalog.provider(id: "python-lsp")?.isBuiltIn == true)
    #expect(catalog.provider(id: "typescript-language-server")?.isBuiltIn == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPProviderCatalogTests
```

Expected: FAIL because provider and managed state models do not exist.

**Step 3: Write minimal implementation**

最小实现：

- 新增 provider、安装结果、服务状态值模型
- `LSPServerDefinition` 增加来源信息字段，例如 `sourceKind` 或 `providerID`
- 暂不接入真实安装器，只先把模型和默认 catalog 契约固定住

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/LSPProviderDefinition.swift agentGui/Models/LSPManagedServiceState.swift agentGui/Models/LSPInstallResult.swift agentGui/Models/LSPServerDefinition.swift agentGuiTests/LSPProviderCatalogTests.swift
git commit -m "feat: add lsp provider and managed service models"
```

### Task 2: 引入 provider catalog，并把 registry 收敛为 Python-only built-in

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProviderCatalog.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPMigrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerRegistryTests.swift`

**Step 1: Write the failing tests**

锁定以下行为：

- registry 的默认 built-in definitions 只剩 Python
- provider catalog 仍能列出 JS/TS、C/C++、Rust、Java、Go
- 历史内建 JS/TS 或 Swift stub 的 server id 可以被 migration 识别并映射到 provider
- 用户自定义 profile JSON 不被 migration 覆盖

测试示例：

```swift
@Test func registryDefaultsToPythonOnlyBuiltInDefinitions() throws {
    let registry = try LSPServerRegistry(settings: .testFixture())
    let ids = Set(registry.allDefinitions().map(\.id))

    #expect(ids == ["python-lsp"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPServerRegistryTests \
  -only-testing:agentGuiTests/LSPMigrationTests
```

Expected: FAIL because the registry still returns multiple built-ins and migration does not exist.

**Step 3: Write minimal implementation**

最小实现：

- `LSPProviderCatalog` 提供默认 provider 列表
- `LSPServerRegistry` built-ins 只保留 Python
- `AppSettings` 增加用于记录 provider 安装/启用状态的最小字段，例如 JSON 数组或字典
- migration 先做映射和兼容解析，不做复杂 UI 提示

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPProviderCatalog.swift agentGui/Services/LSP/LSPServerRegistry.swift agentGui/Models/AppSettings.swift agentGuiTests/LSPServerRegistryTests.swift agentGuiTests/LSPMigrationTests.swift
git commit -m "refactor: keep python as the only built-in lsp profile"
```

### Task 3: 建立安装策略协议与安装协调器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPInstallStrategy.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPInstallCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPInstallCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProcessSupervisor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- 安装协调器会先做 executable/path 预检，再决定 install 或 repair
- 不同 provider 可选择不同安装策略，但统一返回 `LSPInstallResult`
- 安装成功后会产出可写入 registry 的 runtime definition 或 provider activation record
- 安装失败会返回结构化错误摘要和建议动作

测试示例：

```swift
@Test func installCoordinatorReturnsStructuredFailureWhenExecutableCannotBeResolved() async throws {
    let coordinator = LSPInstallCoordinator(
        catalog: .fixture(),
        strategies: [.failingExecutableProbe]
    )

    let result = await coordinator.install(providerID: "clangd")

    #expect(result.status == .failed)
    #expect(result.recoverySuggestion == .recheckPath)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPInstallCoordinatorTests
```

Expected: FAIL because no install abstraction exists.

**Step 3: Write minimal implementation**

最小实现：

- 定义 `LSPInstallStrategy` 协议
- 先提供 fake/test strategy 与基础 executable probe strategy
- `LSPInstallCoordinator` 支持 `install`、`recheck`、`repair`
- 先不接真实包管理器执行，只把协调器、结果模型和设置持久化链打通

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPInstallStrategy.swift agentGui/Services/LSP/LSPInstallCoordinator.swift agentGui/Models/AppSettings.swift agentGuiTests/LSPInstallCoordinatorTests.swift
git commit -m "feat: add lsp installation coordinator and strategy abstraction"
```

### Task 4: 建立服务状态仓库与管理视图模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServiceStateStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/LSPManagementViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServiceStateStoreTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPManagementViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`

**Step 1: Write the failing tests**

锁定以下行为：

- `LSPServiceStateStore` 能把 provider、installation、registry definition、runtime state 合成为单一服务状态
- `LSPManagementViewModel` 输出稳定排序的服务列表和支持的动作按钮状态
- runtime 从 `LSPServerManager` 收到启动、停止、崩溃、重启变化后，presentation 会刷新

测试示例：

```swift
@Test func managementViewModelMarksServiceAsRunningWhenRuntimeSessionExists() {
    let viewModel = LSPManagementViewModel.fixture(runningServerIDs: ["python-lsp"])

    let python = try #require(viewModel.services.first { $0.id == "python-lsp" })
    #expect(python.runtimeStatusText == "运行中")
    #expect(python.availableActions.contains(.stop))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPServiceStateStoreTests \
  -only-testing:agentGuiTests/LSPManagementViewModelTests
```

Expected: FAIL because the state store and view model do not exist.

**Step 3: Write minimal implementation**

最小实现：

- `LSPServiceStateStore` 聚合 provider、settings、registry、manager state
- `ACPClientService` 暴露一个稳定入口来获取 store/view model 需要的 LSP 状态
- `LSPManagementViewModel` 只做 presentation 映射，不直接启进程

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPServiceStateStore.swift agentGui/ViewModels/LSPManagementViewModel.swift agentGui/Services/LSP/LSPServerManager.swift agentGui/Services/ACPClientService.swift agentGuiTests/LSPServiceStateStoreTests.swift agentGuiTests/LSPManagementViewModelTests.swift
git commit -m "feat: add lsp service state store and management view model"
```

### Task 5: 在设置页落地 LSP 服务管理 UI

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/LSPManagementSectionView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/LSPServiceRowView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/LSPServiceDetailView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsToolsView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPSettingsTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- 设置页在启用 LSP 后优先显示服务目录和状态，而不是仅显示 built-in summary
- 每个服务行显示名称、语言、安装状态、运行状态和基础动作
- 详情视图可显示 executable 路径、最近错误、版本或探测摘要
- 高级 JSON 编辑器仍在，但降级为高级入口

测试示例：

```swift
@Test @MainActor func settingsShowsManagedLSPServicesInsteadOfBuiltInSummary() throws {
    let harness = SettingsLSPHarness.withInstalledProviders(["python-lsp", "gopls"])
    let view = SettingsToolsView(store: harness.store)

    #expect(harness.render(view).contains("Python LSP"))
    #expect(harness.render(view).contains("Go"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPSettingsTests
```

Expected: FAIL because the settings UI still only exposes toggles and JSON text editor.

**Step 3: Write minimal implementation**

最小实现：

- 在 `SettingsToolsView` 中新增 `LSPManagementSectionView`
- 使用 `LSPManagementViewModel` 驱动服务列表
- 保留现有开关，但把“内建 Profiles”替换为“服务目录/已安装服务”视图
- 高级 JSON 编辑器折叠到次级区域

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Settings/LSPManagementSectionView.swift agentGui/Views/Settings/LSPServiceRowView.swift agentGui/Views/Settings/LSPServiceDetailView.swift agentGui/Views/Settings/SettingsToolsView.swift agentGui/Views/Settings/SettingsWindowView.swift agentGuiTests/LSPSettingsTests.swift
git commit -m "feat: add lsp service management ui in settings"
```

### Task 6: 打通服务动作，支持启动、停止、重启、重检和修复

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/LSPManagementViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPInstallCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPServerManager.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProcessSupervisor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPServerManagerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPManagementViewModelTests.swift`

**Step 1: Write the failing tests**

锁定以下行为：

- 点击启动会走 `LSPServerManager.startSession(...)`
- 点击停止会终止活动会话并刷新 UI 状态
- 点击重启会走 `restartServer(...)`
- 点击重新检测或修复会走 `LSPInstallCoordinator.recheck/repair`
- 崩溃状态下 UI 会显示恢复可用动作而不是继续显示“运行中”

测试示例：

```swift
@Test func restartActionRestartsExistingServiceSession() async throws {
    let harness = LSPManagementActionHarness()
    let viewModel = harness.makeViewModel()

    try await viewModel.perform(.restart, for: "python-lsp")

    #expect(harness.didRestartServerIDs == ["python-lsp"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPServerManagerTests \
  -only-testing:agentGuiTests/LSPManagementViewModelTests
```

Expected: FAIL because management actions are not wired through a dedicated action layer.

**Step 3: Write minimal implementation**

最小实现：

- `LSPManagementViewModel` 暴露 `perform(_:for:)`
- `LSPServerManager` 补齐管理层所需的停止、日志、状态访问接口
- `LSPInstallCoordinator` 支持重新检测和修复的统一入口

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/LSPManagementViewModel.swift agentGui/Services/LSP/LSPInstallCoordinator.swift agentGui/Services/LSP/LSPServerManager.swift agentGui/Services/LSP/LSPProcessSupervisor.swift agentGuiTests/LSPServerManagerTests.swift agentGuiTests/LSPManagementViewModelTests.swift
git commit -m "feat: wire lsp management actions to runtime and installer"
```

### Task 7: 把工作区 LSP footer 升级为管理入口摘要

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+WorkspaceContext.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceWorkspaceContextTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPManagementViewModelTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- workspace footer 会显示服务状态摘要，但详细动作入口会跳到管理视图或弹出服务详情
- 当当前文件未命中 provider、provider 未安装、服务已崩溃时，摘要文案可区分
- footer 状态与设置页管理状态使用同一套 presentation source

测试示例：

```swift
@Test func workspaceFooterShowsProviderNotInstalledState() {
    let status = WorkspacePanelLSPStatusPresentation.fixture(stateText: "未安装", serverID: "gopls")
    #expect(status.stateText == "未安装")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ClaudeServiceWorkspaceContextTests \
  -only-testing:agentGuiTests/LSPManagementViewModelTests
```

Expected: FAIL because the workspace footer only knows basic runtime/diagnostics status.

**Step 3: Write minimal implementation**

最小实现：

- `ClaudeService+WorkspaceContext` 从 `LSPServiceStateStore` 取更高层摘要
- `WorkspacePanelView` 将 footer 保留为摘要入口，增加“打开管理详情”或“显示服务详情”的交互
- 不删除现有 diagnostics popover，但让它从属于服务详情而不是单独承担全部 LSP 状态职责

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+WorkspaceContext.swift agentGui/Views/WorkspacePanelView.swift agentGuiTests/ClaudeServiceWorkspaceContextTests.swift agentGuiTests/LSPManagementViewModelTests.swift
git commit -m "feat: upgrade workspace lsp footer into management summary entry"
```

### Task 8: 接入首批可安装 provider 与兼容性回归验证

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPProviderCatalog.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPInstallStrategy.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPProviderCatalogTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPInstallCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPMigrationTests.swift`

**Step 1: Write the failing tests**

锁定以下行为：

- catalog 默认包含 JS/TS、C/C++、Rust、Java、Go 的 provider 元数据
- 每个 provider 都有推荐命令、语言 ID 和默认 root markers
- 旧配置升级后，历史绑定仍能映射到 provider 或保留为自定义服务
- Python 现有行为不回退

测试示例：

```swift
@Test func defaultCatalogIncludesMainstreamInstallableProviders() {
    let catalog = LSPProviderCatalog.builtInCatalog()
    let ids = Set(catalog.allProviders().map(\.id))

    #expect(ids.contains("typescript-language-server"))
    #expect(ids.contains("clangd"))
    #expect(ids.contains("rust-analyzer"))
    #expect(ids.contains("jdtls"))
    #expect(ids.contains("gopls"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPProviderCatalogTests \
  -only-testing:agentGuiTests/LSPInstallCoordinatorTests \
  -only-testing:agentGuiTests/LSPMigrationTests
```

Expected: FAIL until the real default provider list and migration behaviors are filled in.

**Step 3: Write minimal implementation**

最小实现：

- 为 JS/TS、C/C++、Rust、Java、Go 写默认 provider 定义
- 为每个 provider 绑定推荐安装策略类型或探测方式
- 补齐兼容性迁移和 provider 激活持久化

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/LSP/LSPProviderCatalog.swift agentGui/Services/LSP/LSPInstallStrategy.swift agentGui/Models/AppSettings.swift agentGuiTests/LSPProviderCatalogTests.swift agentGuiTests/LSPInstallCoordinatorTests.swift agentGuiTests/LSPMigrationTests.swift
git commit -m "feat: add installable providers for mainstream languages"
```

### Task 9: 完整回归、文档更新与质量门检查

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-15-lsp-installation-and-management-requirements.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-15-lsp-installation-and-management-implementation-plan.md`

**Step 1: Write the failing test list / regression checklist**

列出必须回归的测试集：

- `LSPProviderCatalogTests`
- `LSPInstallCoordinatorTests`
- `LSPServiceStateStoreTests`
- `LSPManagementViewModelTests`
- `LSPServerRegistryTests`
- `LSPServerManagerTests`
- `LSPSettingsTests`
- `ClaudeServiceWorkspaceContextTests`

**Step 2: Run tests to verify the integrated feature set**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LSPProviderCatalogTests \
  -only-testing:agentGuiTests/LSPInstallCoordinatorTests \
  -only-testing:agentGuiTests/LSPServiceStateStoreTests \
  -only-testing:agentGuiTests/LSPManagementViewModelTests \
  -only-testing:agentGuiTests/LSPServerRegistryTests \
  -only-testing:agentGuiTests/LSPServerManagerTests \
  -only-testing:agentGuiTests/LSPSettingsTests \
  -only-testing:agentGuiTests/ClaudeServiceWorkspaceContextTests
```

Expected: PASS.

然后运行仓库烟测：

```bash
./scripts/run_quality_smoke.sh
```

Expected: exit code 0.

**Step 3: Write minimal documentation updates**

更新需求和计划文档中的实际文件清单、已完成状态和任何偏差记录。

**Step 4: Re-run smoke if docs or build wiring changed**

若修改了工程文件、设置入口或测试注册，再跑一次 smoke。

**Step 5: Commit**

```bash
git add docs/spec/2026-03-15-lsp-installation-and-management-requirements.md docs/plans/2026-03-15-lsp-installation-and-management-implementation-plan.md
git commit -m "docs: finalize lsp installation and management rollout plan"
```

## 6. 实施顺序建议

建议按以下顺序执行，避免 UI 先行导致状态模型返工：

1. Task 1-2：先定模型、catalog、Python-only built-in 与迁移契约。
2. Task 3-4：再做安装协调器、服务状态仓库和管理视图模型。
3. Task 5-7：最后接设置页管理 UI、动作 wiring 和工作区摘要联动。
4. Task 8-9：补齐首批 provider、做兼容验证和烟测收口。

## 7. 风险与检查点

- 风险 1：把 provider catalog 和 registry 混成一层，后面会再次把“安装列表”和“运行时可用服务”耦合在一起。
- 风险 2：把 Python 做成硬编码特例，会破坏平台抽象，后续更难维护。
- 风险 3：设置页和工作区 footer 各自推导状态，会产生显示冲突。
- 风险 4： migration 做得过晚，会在 built-in 收敛时误伤历史用户配置。

每完成一个阶段都要人工检查：

- 设置页看到的状态是否与工作区 footer 一致。
- Python 现有工作流是否仍能自动启动并给出 diagnostics。
- 未安装 provider 是否能明确显示“未安装”，而不是“未启动”。

## 8. 完成定义

以下条件全部满足时，才可视为该计划完成：

- 应用默认只保留 Python built-in LSP profile。
- JS/TS、C/C++、Rust、Java、Go 以 installable provider 形式出现在管理目录中。
- 用户无需编辑 JSON profile 即可完成安装、重检、启动、停止、重启、修复等常见操作。
- 工作区 footer 与设置页管理视图共享一致的 LSP 服务状态。
- 旧配置和自定义 profile 不会因 built-in 收敛而静默失效。
- 相关 focused tests 和 smoke checks 全部通过。