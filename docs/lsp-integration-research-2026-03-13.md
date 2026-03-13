# agentGui 支持 LSP 的技术调研报告

日期：2026-03-13

## 1. 结论摘要

结论先行：当前应用非常适合引入 LSP，但不应把“让模型直接说 LSP”当成方案本身，而应把 LSP 作为本地语义服务层，再通过少量高价值工具暴露给 agent。

对当前仓库而言，推荐路线是：

1. 采用“通用 LSP Runtime + 可配置多语言 Server 管理”的主架构，不把 SourceKit 设为产品优先级。
2. 第一阶段先打通跨语言通用只读语义能力：symbols、hover、definition、references、diagnostics。
3. 产品能力以 JS、TS、Python 等通用语言接入为基线，同时保留未来接入自定义小说语言 server 的扩展位。
4. 把语言服务器管理做成一等能力，包括 server 注册、启动、停止、重启、健康检查、workspace 绑定与状态展示。
5. 暂缓把 rename、code action、workspace edit 直接开放给 agent，先把“看懂代码”和“判断影响范围”做扎实。

这条路线的收益很明确：当前 agent 只能读取文件文本、跑 shell、看网页，缺少符号级、类型级、跨文件依赖级信息；LSP 正好补的是这一层，而且现有工具注册、分发、workflow/verification 结构已经预留了非常自然的接入点。

## 2. 当前应用现状评估

### 2.1 现有工具体系已经具备插拔式扩展条件

当前工具体系是显式注册、显式分发、按上下文裁剪的：

- 工具注册中心在 [agentGui/Services/ToolRegistry.swift](../agentGui/Services/ToolRegistry.swift)，目前注册的主要是文本编辑、bash、payload 读取、web search/fetch、subagent、workflow 等工具。
- 主 agent 的工具列表由 [agentGui/Services/ClaudeService+ToolBuilder.swift](../agentGui/Services/ClaudeService+ToolBuilder.swift) 按设置动态构建。
- workflow/subagent 的工具列表由 [agentGui/Services/ToolsetResolver.swift](../agentGui/Services/ToolsetResolver.swift) 按角色和上下文裁剪。
- 实际工具执行统一汇聚到 [agentGui/Services/ClaudeService+ToolDispatch.swift](../agentGui/Services/ClaudeService+ToolDispatch.swift) 和 [agentGui/Services/AgentLoopToolExecutionCoordinator.swift](../agentGui/Services/AgentLoopToolExecutionCoordinator.swift)。

这意味着 LSP 不需要侵入 `runCoreAgentLoop` 内核，只需要新增：

- 一组 ToolDefinition
- 一条 executeTool 分支
- 一个本地 LSP runtime/service
- 少量 settings 和 UI 状态

这是低耦合接入，不是大手术。

### 2.2 当前 agent 的代码上下文能力仍然停留在“文本级”

当前 agent 已有的主要能力：

- 文件读取/精确字符串替换/插入/创建，见 [agentGui/Services/ClaudeService+TextEditorTool.swift](../agentGui/Services/ClaudeService+TextEditorTool.swift)
- 持久 shell 会话与后台任务，见 [agentGui/Services/ClaudeService+BashTool.swift](../agentGui/Services/ClaudeService+BashTool.swift) 与 [agentGui/Services/BashSession.swift](../agentGui/Services/BashSession.swift)
- workflow 多角色执行、验证和子代理，见 [agentGui/Services/WorkflowAgentRunner.swift](../agentGui/Services/WorkflowAgentRunner.swift) 与 [agentGui/Services/AgentLoopVerificationCoordinator.swift](../agentGui/Services/AgentLoopVerificationCoordinator.swift)

当前缺失的关键能力：

1. 看不到某个 symbol 的定义位置。
2. 找不到跨文件 references。
3. 不知道 hover/type information。
4. 没有真实语义诊断，只能依赖 build/test 命令文本输出。
5. 无法可靠判断修改一个 symbol 会影响哪些文件。
6. 无法为 verifier 提供“符号是否断裂”“导入是否失效”这类结构化证据。

换句话说，当前 agent 更像“能看文件、能改文件、能跑命令”，还不是“能理解工程语义结构的编程 agent”。

### 2.3 当前系统已经有“工作区语义上下文”的容器，但利用不充分

workflow 任务构造已经支持以下工作区上下文：

- working directory
- active file
- selected text
- available skills

相关结构和消费点见：

- [agentGui/Services/WorkflowDefinition.swift](../agentGui/Services/WorkflowDefinition.swift)
- [agentGui/Services/WorkflowAgentRunner.swift](../agentGui/Services/WorkflowAgentRunner.swift)

但在当前 ACP 路径里，`currentWorkspaceContext` 仍然把 `selectedFilePath` 和 `selectedText` 置空，见 [agentGui/Services/ACPClientService.swift](../agentGui/Services/ACPClientService.swift)。这说明系统数据模型已经为更强代码语义上下文留了位置，但目前喂给 agent 的信息不完整。

LSP 接入后，最自然的做法不是只新增工具，还要把：

- 当前活动文件
- 当前选择范围
- 当前文档版本
- 当前 diagnostics 摘要

一起纳入同一条 workspace context 管线。

### 2.4 应用当前没有 App Sandbox，具备拉起本地语言服务器的前提

[agentGui/agentGui.entitlements](../agentGui/agentGui.entitlements) 中 `com.apple.security.app-sandbox` 为 `false`。这点非常关键。

这意味着：

- 应用可以本地拉起 `sourcekit-lsp` / `clangd` / `xcode-build-server` 等进程。
- 不需要先绕过 App Sandbox 的进程执行限制。
- 第一版可以直接采用本地 stdio LSP client，不必先做独立 helper app。

如果未来上架 Mac App Store，再重新评估沙箱化方案；但当前阶段不是阻塞项。

## 3. 为什么 LSP 能显著提升 agent 编程质量

LSP 的核心价值不是“补一个 IDE 功能”，而是给 agent 一个结构化、可查询、跨语言通用的语义信息平面。

根据官方说明，LSP 通过 JSON-RPC 在编辑器和语言服务器之间传递语义能力，目标就是把补全、跳转定义、引用查找、hover、diagnostics 这类语言能力标准化。官方入口：

- LSP 总览：<https://microsoft.github.io/language-server-protocol/>
- 当前规范版本说明：LSP 3.17

对 agent 而言，最有价值的不是补全，而是以下能力：

1. `textDocument/definition`
   解决“这个名字到底定义在哪”。

2. `textDocument/references`
   解决“改这个东西会波及哪里”。

3. `textDocument/hover`
   解决“这个 API/类型在当前位置的语义是什么”。

4. `textDocument/documentSymbol` 与 `workspace/symbol`
   解决“当前文件/工作区有哪些重要结构”。

5. diagnostics
   解决“修改后是否立刻造成语义错误”。

这几项能力能直接提升 agent 的三个环节：

- 探索：更快定位改动面
- 实施：避免误改、漏改、同名 symbol 混淆
- 验证：把“我觉得改好了”变成“语义层面没有断裂”

## 4. LSP 协议层面的工程要点

### 4.1 传输与生命周期

LSP 标准传输通常是 JSON-RPC over stdio。对 agentGui 而言，这正好匹配 macOS 本地进程模型。

基础生命周期至少包括：

- `initialize`
- `initialized`
- 文档同步（`didOpen` / `didChange` / `didClose`）
- 语义请求（definition / references / hover / symbols / diagnostics）
- `shutdown`
- `exit`

这部分和当前 bash/git 之类的一次性 process 不同，LSP 需要长期会话、文档版本、按顺序处理消息，以及请求与通知并行管理。

SourceKit-LSP 的设计文档也强调了消息顺序的重要性，尤其是 `didChange` 这类文档同步消息不能乱序。官方设计概览：<https://raw.githubusercontent.com/swiftlang/sourcekit-lsp/main/Contributor%20Documentation/Overview.md>

### 4.2 不应该把原始 LSP 方法直接暴露给模型

虽然底层是标准 LSP，但不建议给 agent 一个“万能 `lsp_request(method, params)`”工具。这样会带来两个问题：

1. 模型要自己拼 protocol 参数，错误率高。
2. 工具层安全和缓存策略无法约束。

更好的做法是：

- 内部实现全量 LSP client
- 对模型只暴露 5-8 个语义化工具

例如：

- `lsp_document_symbols`
- `lsp_workspace_symbols`
- `lsp_definition`
- `lsp_references`
- `lsp_hover`
- `lsp_diagnostics`
- `lsp_semantic_summary`

这样模型拿到的是稳定、裁剪过、可控的高价值能力，而不是协议细节。

## 5. Swift / Xcode 特殊约束

这是一类需要单独处理的 adapter 场景，但不应主导整体产品优先级。

### 5.1 当前仓库是 Xcode 工程，不是 SwiftPM 工程

当前仓库根目录有：

- `agentGui.xcodeproj`
- `agentGui.xcodeproj/project.xcworkspace`

但没有 `Package.swift`。这意味着：

- 不能把 `sourcekit-lsp` 的 SwiftPM happy path 当默认前提。
- 不能假设仅凭工作目录就能获得完整 Swift build settings。

### 5.2 SourceKit-LSP 的语义能力强依赖 build settings

SourceKit-LSP 官方设计文档明确说明：几乎所有语义功能都依赖文件如何被构建，例如 module search paths、compiler arguments 等；它通过 build server 获取这些信息。官方设计概览：<https://raw.githubusercontent.com/swiftlang/sourcekit-lsp/main/Contributor%20Documentation/Overview.md>

SourceKit-LSP README 也明确指出：如果项目最近没有 build，跨模块或全局功能会受限；要么先 build，要么启用 background indexing。官方 README：<https://raw.githubusercontent.com/swiftlang/sourcekit-lsp/main/README.md>

这对 agentGui 的含义是：

- “启动 SourceKit-LSP 就能直接工作”是不成立的。
- 必须解决 build metadata 和 index 新鲜度。

### 5.3 对 Xcode 项目，推荐通过 BSP 适配而不是硬猜 compiler flags

SourceKit-LSP 官方的 BSP 指南明确要求：

- `build/initialize`
- `build/initialized`
- `build/shutdown`
- `build/exit`

以及：

- `workspace/buildTargets`
- `buildTarget/sources`
- `textDocument/sourceKitOptions`
- `buildTarget/didChange`
- `workspace/waitForBuildSystemUpdates`

并且指出：若要支持全局 rename / call hierarchy 这类全局导航能力，build server 还应提供 `indexDatabasePath` 和 `indexStorePath`。官方文档：<https://raw.githubusercontent.com/swiftlang/sourcekit-lsp/main/Contributor%20Documentation/Implementing%20a%20BSP%20server.md>

对 `.xcodeproj` 来说，现成可用的路线是 `xcode-build-server`：

- 项目：<https://github.com/SolaWing/xcode-build-server>
- 作用：为 Xcode 工程生成 `buildServer.json` 并把 Xcode build log / DerivedData 转成 SourceKit-LSP 可消费的 build metadata。

它的 README 明确写到：SourceKit-LSP 原生不支持 Xcode project，这也是它存在的原因。

### 5.5 Phase 1 内建 profile 策略

第一阶段内建 profile 应保持保守：

- TypeScript / JavaScript：`typescript-language-server --stdio`
- Python：`pylsp --stdio`
- Swift：仅保留 `xcrun sourcekit-lsp` stub profile，作为后续 adapter seam，不进入默认自动路由

这样做的原因很直接：

- JS/TS 与 Python 可以通过通用 stdio LSP runtime 立即获得稳定收益。
- Swift 语义能力依赖 BSP / `buildServer.json` / index 新鲜度，直接纳入 Phase 1 自动路由只会制造大量假阴性与误导性失败。
- 先在 registry 中保留 Swift stub profile，有利于后续在不重构工具层的前提下接入 `SourceKitLSPAdapter`。

### 5.4 当前项目若接 Swift LSP，建议采用下述组合

推荐组合：

1. 使用 `xcrun sourcekit-lsp` 启动语言服务器。
2. 在 workspace root 准备 `buildServer.json`。
3. 对 Xcode 工程通过 `xcode-build-server config -project agentGui.xcodeproj -scheme <scheme>` 建立 BSP 绑定。
4. 当 compile info 过期时，通过 Xcode build 或 `xcodebuild` 刷新 index。

这个路径的优点是：

- 不需要自己解析 Swift 编译参数。
- 复用 SourceKit-LSP 官方支持的工作模式。
- 未来还能带上 Objective-C/C/C++。

## 6. 可选技术方案比较

### 方案 A：直接在 app 内实现通用 LSP client

做法：

- app 自己管理 stdio JSON-RPC
- 通过配置指定语言服务器命令
- 面向所有语言提供统一抽象

优点：

- 架构干净
- 可扩展到多语言
- 后续支持自定义语言 server 最自然

缺点：

- 仍然需要 server 注册、状态管理、workspace 绑定这些产品层能力
- Swift/Xcode 的 build settings 问题仍然要单独解决

适用性：高，但如果缺少 server 管理层，最终只会得到一个底层库，而不是可用产品能力。

### 方案 B：按语言逐个做专项接入

做法：

- 每种语言各自写启动、探测、工具映射逻辑
- 先接一个语言，再继续叠加第二个、第三个语言

优点：

- 单语言首版看起来推进快
- 可以快速验证某个特定 server 的协议兼容性

缺点：

- 很快出现重复逻辑
- 自定义语言接入成本高

适用性：不建议作为主路线，只适合临时验证某个单独 server。

### 方案 C：通用 LSP Runtime + Server Registry/Manager + 语言 Adapter

做法：

- 底层做通用 LSP transport/session/document store
- 中层做 server registry、workspace resolver、process supervisor、capability cache
- 上层按语言补充少量 adapter 逻辑，Swift/Xcode 只是其中之一

优点：

- 先解决多语言和自定义语言的通用问题
- 工具层保持统一
- 未来接 typescript-language-server、eslint-lsp、pyright、pylsp、clangd、自定义小说语言 server 更容易

缺点：

- 比专项接入稍重
- 需要先想清楚 server 生命周期和配置模型

适用性：这是推荐方案。

## 7. 推荐架构设计

### 7.1 服务层拆分建议

建议新增以下服务：

1. `LSPServerDefinition`
   描述服务器类型、命令、参数、支持语言、root 识别规则、能力声明与环境要求。

2. `LSPServerRegistry`
   维护内建 server 模板与用户自定义 server 配置，支持未来注册小说语言 server。

3. `LSPWorkspaceResolver`
   根据工作目录、文件类型和用户策略判断某个 workspace / document 应该绑定哪个 server。

4. `LSPProcessSupervisor`
   管理进程启动、停止、重启、崩溃恢复、超时与健康检查。

5. `LSPJSONRPCTransport`
   负责 `Content-Length` framing、请求 ID、响应匹配、通知分发。

6. `LSPDocumentStore`
   跟踪已打开文档、版本号、增量变更。

7. `LSPClient`
   暴露高层 API，例如 `definition(...)`、`references(...)`、`hover(...)`。

8. `LSPDiagnosticsStore`
   缓存 diagnostics，供 UI 和 verifier 复用。

9. `LSPServerManager`
   作为总入口管理 workspace session、server 复用、语言路由、状态广播与手动控制。

10. `SourceKitWorkspaceBuildMetadataProvider`
   仅在 Swift/Xcode adapter 中使用，处理 `.xcodeproj` / `buildServer.json` / `xcode-build-server` 检测与引导。

### 7.2 与当前代码的自然接入点

最关键的接入点如下：

1. [agentGui/Services/ToolRegistry.swift](../agentGui/Services/ToolRegistry.swift)
   新增 LSP 工具定义。

2. [agentGui/Services/ClaudeService+ToolDispatch.swift](../agentGui/Services/ClaudeService+ToolDispatch.swift)
   增加 LSP 分发分支。

3. [agentGui/Services/AgentLoopToolExecutionCoordinator.swift](../agentGui/Services/AgentLoopToolExecutionCoordinator.swift)
   无需改结构，只需要走新增 tool name。

4. [agentGui/Services/ToolsetResolver.swift](../agentGui/Services/ToolsetResolver.swift)
   新增 `ToolGroupID.lspReadOnly` / `ToolGroupID.lspRefactor` 一类的分组。

5. [agentGui/Models/AppSettings.swift](../agentGui/Models/AppSettings.swift)
   增加是否启用 LSP、默认 server 策略、自动启动、server profile、自定义 server 配置与语言绑定策略。

6. [agentGui/ContentView.swift](../agentGui/ContentView.swift)
   在工具设置区增加 LSP 开关和配置入口。当前已经有文本编辑、bash、web search、web fetch 的设置模式，LSP 可以沿用同一路径。

7. [agentGui/Services/AgentLoopVerificationCoordinator.swift](../agentGui/Services/AgentLoopVerificationCoordinator.swift)
   把 diagnostics / unresolved symbol 检查作为 verifier 的结构化证据。

8. [agentGui/Services/WorkflowAgentRunner.swift](../agentGui/Services/WorkflowAgentRunner.swift)
   让 workflow role 拿到活动文件、选区、diagnostics 摘要。

### 7.3 对模型暴露的工具建议

建议第一版只暴露以下只读工具：

1. `lsp_definition`
   输入：file path + line + column
   输出：定义位置、symbol 摘要、所在文件局部上下文

2. `lsp_references`
   输入：file path + line + column
   输出：引用列表，可分页

3. `lsp_hover`
   输入：file path + line + column
   输出：类型、签名、文档摘要

4. `lsp_document_symbols`
   输入：file path
   输出：当前文件的结构树

5. `lsp_workspace_symbols`
   输入：query
   输出：工作区符号匹配

6. `lsp_diagnostics`
   输入：file path 或 workspace
   输出：结构化 diagnostics

7. `lsp_semantic_summary`
   输入：file path
   输出：当前文件的 imports、top-level types/functions、diagnostics、相关 symbols 摘要

8. `lsp_list_servers`
   输入：可选 workspace path
   输出：当前可用 server、绑定关系、运行状态、能力摘要

9. `lsp_server_status`
   输入：server id 或 workspace path
   输出：启动状态、最近错误、重启次数、健康检查结果

其中 `lsp_semantic_summary` 很适合给 agent 做高频低成本查询，避免模型频繁串多个底层请求。

### 7.4 第二阶段再考虑的能力

以下能力不要在第一版就开放给 agent：

- rename
- code action
- workspace edit
- semantic tokens 全量输出
- completion

原因很简单：

- rename/code action 牵涉跨文件写操作和一致性验证
- completion 对 agent 价值不如 symbols/definition/references
- semantic tokens 体量大，token 性价比差

同时补充一点：server 管理相关动作不应让模型任意写命令行，而应由产品层暴露受控操作，例如 `start`、`stop`、`restart`、`rebind` 这类有限动作。

## 8. 推荐的数据流

推荐运行流如下：

1. 用户设置工作目录。
2. app 根据工作目录、文件后缀和用户配置匹配 server profile。
3. `LSPServerManager` 检查对应 server 的命令可用性、root 解析结果与 capability 缓存。
4. 若命中的是通用语言 server，直接启动对应 LSP server，完成 `initialize/initialized`。
5. 若命中的是特殊 adapter，例如 Swift/Xcode，再补充 adapter 特有前置检查，并在缺失时给出引导而不是静默失败。
6. 用户打开/编辑文件时，同步 `didOpen/didChange`。
7. agent 调用语义工具时，先经由语言路由选择 session，再走 `LSPClient`。
8. diagnostics 进入 `LSPDiagnosticsStore`，同时可供：
   - UI 展示
   - verifier 检查
   - workflow context 摘要注入
9. server 崩溃、初始化失败或 adapter 前置条件缺失时，状态回退到 degraded，并给出可执行恢复建议。

## 9. 对当前 UI/设置层的建议

建议在现有“工具”设置区中新增 LSP 子区，而不是单独做一个巨大设置面板。当前设置入口已经位于 [agentGui/ContentView.swift](../agentGui/ContentView.swift)，并按工具开关组织。

建议新增设置项：

- 启用 LSP 语义工具
- 自动启动语言服务器
- 默认 server 选择策略（按语言、按 workspace、手动绑定）
- 内建 server profiles 列表
- 自定义 server profile 管理
- 每种语言的命令路径、参数、root 检测规则
- adapter 前置条件状态，例如 Python 环境、Node 依赖、Swift BSP 状态
- 自动诊断缓存开关
- diagnostics 自动注入 verifier

建议新增状态显示：

- `LSP: Ready`
- `LSP: Routing by language`
- `LSP: Multiple servers available`
- `LSP: Index stale`
- `LSP: Waiting for build metadata`
- `LSP: Server crashed, retrying`
- `LSP: Misconfigured server profile`

这类状态信息对用户比“工具开关已打开”更重要，因为 LSP 的可用性高度依赖底层 build state。

## 10. 主要风险与应对

### 风险 1：Xcode build metadata 不完整，导致语义结果不可信

这是最大风险。

表现：

- definition/references 缺失
- diagnostics 错误
- 跨模块信息不完整

应对：

- 将 `buildServer.json` 检测设为启动前检查
- 给出一键文案提示用户运行 `xcode-build-server config ...`
- 检测 index stale 时提示执行 build

### 风险 2：LSP server 是长期进程，不是一次性命令

表现：

- 进程泄漏
- 文档版本不同步
- 崩溃恢复不充分

应对：

- 独立 `LSPProcessSupervisor`
- 请求超时与 restart 策略
- 文档 store 与 workspace session 解耦

### 风险 3：把原始 diagnostics 全量注入模型会浪费 token

应对：

- 工具返回结构化摘要
- 大结果走 payload/store 分页
- 对 verifier 注入摘要而非全量详情

### 风险 4：agent 过度依赖 LSP，忽略真实运行结果

LSP 不能替代 build/test/runtime verification。

应对：

- 报告层面明确：LSP 是语义补强，不是执行验证替代品
- verifier 继续保留 bash/build/test 证据优先级

### 风险 5：多语言工作区的 server 选择复杂度上升

应对：

- 首版就定义清楚 language-to-server 绑定模型
- 默认支持“单文档路由到单 server”，而不是整个 workspace 只能有一个 primary server
- 自定义 server 先走受限 profile 模式，避免任意配置导致不可控行为

### 风险 6：未来自定义语言 server 的协议兼容性不稳定

应对：

- 在 `LSPServerDefinition` 中记录 capability 探测结果，而不是假设所有 server 都完整实现规范
- 工具层按 capability 降级，例如没有 references 就隐藏对应工具
- 对自定义语言优先支持只读语义查询，避免一开始就做写操作

## 11. 分阶段落地建议

### Phase 1：通用 LSP runtime 与 server 管理

目标：让 agent 能在多语言工作区稳定使用统一 LSP 语义能力。

范围：

- 通用 `LSPJSONRPCTransport` / `LSPClient` / `LSPDocumentStore`
- `LSPServerRegistry` / `LSPServerManager` / `LSPWorkspaceResolver`
- JS/TS server profile
- Python server profile
- `lsp_definition`
- `lsp_references`
- `lsp_hover`
- `lsp_document_symbols`
- `lsp_workspace_symbols`
- `lsp_diagnostics`
- `lsp_list_servers`
- `lsp_server_status`

验收标准：

- agent 能稳定回答“这个方法在哪定义”“哪些地方引用了它”
- 同一套工具能在 JS、TS、Python 上工作
- verifier 能读取当前文件 diagnostics
- 用户能看见 server 已绑定到哪个语言、是否可用、失败原因是什么
- server 崩溃后可以自动恢复或手动重启

### Phase 2：工作流、验证与自定义语言 onboarding

范围：

- diagnostics 摘要注入 verifier
- workflow context 注入 active file / selection / semantic summary
- 自定义 server profile 创建与验证
- 自定义小说语言 server 的接入约束与降级策略

验收标准：

- agent 的代码变更失败率下降
- verifier 对“未定义符号/断裂引用”能给出结构化反馈
- 新增一种自定义语言 server 时，无需修改核心 runtime

### Phase 3：Swift/Xcode adapter 与其他特殊工程接入

范围：

- `sourcekit-lsp` adapter
- `buildServer.json` / BSP 状态检测
- `xcode-build-server` 引导
- 其他需要额外 metadata 的 server 接入模式沉淀

前提：

- 通用 LSP runtime 已稳定
- server 配置模型已经抽象干净

### Phase 4：更多语言与更深能力

范围：

- clangd
- 其他 JS/TS/Python 生态 server
- capability-based completion / call hierarchy 等高级只读能力

### Phase 5：受控写操作

范围：

- rename
- code action
- workspace edit

前提：

- 需要强校验、预览 diff、可撤销机制
- 不建议在没有充分 UI 预览与验证门禁前开放

## 12. 最终建议

从当前应用架构、仓库类型和工程风险来看，推荐决策如下：

1. 立项支持 LSP，目标明确定位为“给 agent 提供语义级代码上下文”。
2. 架构上采用“通用 LSP Runtime + Server Registry/Manager + 语言 Adapter”。
3. 第一版先解决多语言 server 管理和统一只读查询能力，不做自动重构类写操作。
4. JS、TS、Python 与未来自定义语言 server 应作为能力设计基线，而不是后补需求。
5. Swift/Xcode 作为特殊 adapter 单独处理，必须把 BSP / `buildServer.json` 当成一等公民，但不应反向主导整体架构。
6. 在 agent 层暴露少量高价值工具，不暴露原始 LSP 协议接口。

如果只允许给一个最务实的建议，那就是：

先把“通用 LSP runtime + server manager + JS/TS/Python 只读语义工具 + diagnostics/verifier 集成”做出来。这样能先把产品能力基座搭对，再按需接入 Swift/Xcode 和未来的自定义小说语言 server。

## 13. 附：本次调研引用的仓库内关键位置

- 工具注册：[agentGui/Services/ToolRegistry.swift](../agentGui/Services/ToolRegistry.swift)
- 主工具构建：[agentGui/Services/ClaudeService+ToolBuilder.swift](../agentGui/Services/ClaudeService+ToolBuilder.swift)
- 工具分发：[agentGui/Services/ClaudeService+ToolDispatch.swift](../agentGui/Services/ClaudeService+ToolDispatch.swift)
- 工具协调：[agentGui/Services/AgentLoopToolExecutionCoordinator.swift](../agentGui/Services/AgentLoopToolExecutionCoordinator.swift)
- workflow 工具裁剪：[agentGui/Services/ToolsetResolver.swift](../agentGui/Services/ToolsetResolver.swift)
- workflow 任务构造：[agentGui/Services/WorkflowAgentRunner.swift](../agentGui/Services/WorkflowAgentRunner.swift)
- verifier 协调：[agentGui/Services/AgentLoopVerificationCoordinator.swift](../agentGui/Services/AgentLoopVerificationCoordinator.swift)
- 设置模型：[agentGui/Models/AppSettings.swift](../agentGui/Models/AppSettings.swift)
- 工具设置 UI：[agentGui/ContentView.swift](../agentGui/ContentView.swift)
- 非沙箱 entitlements：[agentGui/agentGui.entitlements](../agentGui/agentGui.entitlements)

## 14. 附：本次调研引用的外部资料

- Language Server Protocol：<https://microsoft.github.io/language-server-protocol/>
- SourceKit-LSP README：<https://raw.githubusercontent.com/swiftlang/sourcekit-lsp/main/README.md>
- SourceKit-LSP Design Overview：<https://raw.githubusercontent.com/swiftlang/sourcekit-lsp/main/Contributor%20Documentation/Overview.md>
- SourceKit-LSP BSP Guide：<https://raw.githubusercontent.com/swiftlang/sourcekit-lsp/main/Contributor%20Documentation/Implementing%20a%20BSP%20server.md>
- SourceKit-LSP Configuration File：<https://raw.githubusercontent.com/swiftlang/sourcekit-lsp/main/Documentation/Configuration%20File.md>
- xcode-build-server：<https://github.com/SolaWing/xcode-build-server>