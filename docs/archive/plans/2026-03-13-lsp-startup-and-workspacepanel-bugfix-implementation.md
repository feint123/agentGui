# LSP 首次诊断、启动卡顿与 WorkspacePanel 丢失问题修复实施文档

**日期：** 2026-03-13

## 1. 背景与目标

本次修复覆盖三个已复现问题：

1. LSP 服务启动后没有对整个项目做首次诊断预热，导致初始错误面板为空。
2. LSP 启动阶段存在同步阻塞，切换到需要 LSP 的项目或文件时 UI 会冻结。
3. 顶部 tab 在“对话”与其他页面之间切换后，WorkspacePanel 的目录树会消失。

目标不是局部打补丁，而是把三处问题统一收敛到更稳定的状态管理和后台启动路径上：

- LSP bootstrap 负责“启动 + 全项目首次预热”。
- 耗时的项目索引、环境解析、文件读取必须离开主线程。
- 聊天工作区状态必须提升到顶层 tab 容器之上，避免 tab 切换时丢失会话级工作目录上下文。

## 2. 根因分析

### 2.1 首次没有项目级诊断

当前 [agentGui/Services/LSP/LSPWorkspaceCoordinator.swift](../../agentGui/Services/LSP/LSPWorkspaceCoordinator.swift) 只做两件事：

- 基于项目索引结果启动对应 server。
- 在项目索引为空时回退到 `selectedFilePath`。

它没有在 server 启动后把已索引文件同步进 LSP 文档生命周期，因此多数 language server 不会主动发布全项目 diagnostics。现状等价于“server 起了，但没有任何 didOpen/didChange 触发”。

### 2.2 启动期间 UI 冻结

目前有两段明显的同步重活发生在 UI 驱动路径上：

- `LSPProjectFileIndexer.indexFiles(...)` 在 `@MainActor` 协调器里做整仓文件遍历。
- [agentGui/Utilities/ShellEnvironmentResolver.swift](../../agentGui/Utilities/ShellEnvironmentResolver.swift) 用 `zsh -l -c` 同步解析 PATH，并 `waitUntilExit()`。

这两段都可能在首次进入工作区时卡住主线程，造成整个页面无响应。

### 2.3 切换 tab 后目录树消失

当前 [agentGui/ContentView.swift](../../agentGui/ContentView.swift) 直接在 `TabView` 中内联创建 `MainSplitView()`；而 [agentGui/Views/MainSplitView.swift](../../agentGui/Views/MainSplitView.swift) 自己持有 `workspaceState` 和 `gitPanelViewModel`。

当顶层 tab 切换时，`MainSplitView` 可能被重建，导致：

- `workspaceState.selectedSession` 丢失。
- 会话级 `workingDirectory` 上下文被重置。
- `WorkspacePanelView` 重载时只能看到不完整状态，目录树出现空白或无法恢复。

## 3. 实施方案

### 3.1 为 LSP bootstrap 增加“首次项目预热”

修改 [agentGui/Services/LSP/LSPWorkspaceCoordinator.swift](../../agentGui/Services/LSP/LSPWorkspaceCoordinator.swift)：

- 为 coordinator 注入文件加载能力。
- 将项目索引结果按 server 分组后，在 server 已启动或恢复成功后，对该 server 对应文件做首次 `didOpen` 预热。
- 预热时读取磁盘文本并调用 `LSPServerManager.syncDocument(...)`，从而触发 diagnostics 发布。
- 仍保留 `selectedFilePath` 兜底逻辑，确保空索引时不会回退失效。

验收标准：首次进入一个有错误的项目时，不需要手动打开每个文件，WorkspacePanel 的项目级错误统计就能出现。

### 3.2 将索引、环境解析、文件读取移到后台

修改以下文件：

- [agentGui/Services/LSP/LSPWorkspaceCoordinator.swift](../../agentGui/Services/LSP/LSPWorkspaceCoordinator.swift)
- [agentGui/Services/LSP/LSPProcessSupervisor.swift](../../agentGui/Services/LSP/LSPProcessSupervisor.swift)
- [agentGui/Utilities/ShellEnvironmentResolver.swift](../../agentGui/Utilities/ShellEnvironmentResolver.swift)

具体策略：

- `indexFiles(...)` 通过 detached/background task 执行，避免主线程枚举整仓。
- 首次文档文本读取通过后台 loader 执行，再回到主线程同步到 `LSPServerManager`。
- PATH 解析改为异步缓存路径：首次等待后台解析结果，后续命中缓存，避免每次启动都同步拉起 login shell。

验收标准：切换到需要 LSP 的工作区时，窗口不再出现整段冻结；即使 bootstrap 持续进行，UI 仍可响应切 tab、滚动和点击。

### 3.3 上移工作区状态，修复 tab 切换后目录树丢失

修改以下文件：

- [agentGui/ContentView.swift](../../agentGui/ContentView.swift)
- [agentGui/Views/MainSplitView.swift](../../agentGui/Views/MainSplitView.swift)

具体策略：

- 将 `workspaceState` 与 `gitPanelViewModel` 提升到 `ContentView` 的稳定 `@State`。
- `MainSplitView` 改为接收这两个共享实例，而不是自己创建。
- 继续由 `MainSplitView` 负责 split view UI，但不再拥有聊天工作区的状态真源。

验收标准：通过启动参数注入工作目录后，从“对话”切到“设置”再切回“对话”，文件树仍可见，且不会丢失原有工作区上下文。

## 4. 回归测试

### 4.1 单元测试

修改 [agentGuiTests/LSPWorkspaceCoordinatorTests.swift](../../agentGuiTests/LSPWorkspaceCoordinatorTests.swift)：

- 新增 `workspaceBootstrapPrewarmsIndexedFilesToPopulateProjectDiagnostics`
- 新增 `workspaceBootstrapIndexesFilesOffMainActor`

这两项分别锁定：

- 首次 bootstrap 必须读取已索引文件并发送 `didOpen`。
- 项目索引不能继续在主线程执行。

### 4.2 UI 测试

新增 [agentGuiUITests/WorkspacePanelUITests.swift](../../agentGuiUITests/WorkspacePanelUITests.swift)：

- 启动时注入会话级工作目录。
- 验证 `workspace.fileTree` 存在。
- 切到设置 tab 再切回对话 tab。
- 再次验证文件树和目录项仍存在。

## 5. 执行顺序

1. 先让新增测试从“编译失败/行为失败”进入可执行状态。
2. 实现 coordinator 首次预热与后台索引。
3. 实现异步 PATH 解析缓存，去掉启动路径上的同步阻塞。
4. 上移 `workspaceState` / `gitPanelViewModel`，修复 tab 切换状态丢失。
5. 运行定向测试，再根据结果补最小修正。

## 6. 风险与边界

- 首次预热会读取较多文件，因此必须保持后台执行；否则会把“诊断缺失”变成“更严重的卡顿”。
- 某些 language server 只对打开文档发布 diagnostics；当前修复基于这个现实约束，不引入新的 `workspace/diagnostic` 协议实现。
- 本轮不处理更多 LSP 能力缺口，例如 workspace symbols、document symbols 的完整实现。

## 7. 完成定义

满足以下条件即视为完成：

- 首次进入有错误的项目时，WorkspacePanel 能显示项目级 diagnostics。
- LSP 启动期间 UI 不再明显冻结。
- 切换顶部 tab 后再回到对话页，目录树仍存在。
- 新增单元测试与 UI 测试通过。