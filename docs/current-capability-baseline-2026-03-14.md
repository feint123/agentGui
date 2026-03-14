# agentGui 当前能力基线

日期：2026-03-14

## 1. 文档目的

本文档用于冻结 2026-03-14 时点 agentGui 已落地的产品能力基线，作为后续需求评审、实现计划拆分和文档归档的参照面。

这里的“基线”只覆盖当前仓库中已经形成稳定代码路径、可被现有 UI/服务/测试直接佐证的能力；仍在方案推进、尚未完成闭环、或仅停留在研究/规划层的内容，不计入本次基线。

## 2. 基线结论

当前 agentGui 已经不是单纯的 Claude 聊天壳，而是一套具备多轮执行、工具调用、工作区上下文、统一记忆运行时、RMS 认知面板、Git/LSP 辅助、质量基线脚本与多子代理协作能力的 macOS 原生 AI Agent 客户端。

本次基线将当前能力收敛为以下 8 个一级能力域：

1. 聊天与会话
2. Agent Loop 与验证/反思闭环
3. 工具系统与受管执行
4. 工作区、文件、Git 与 LSP
5. 统一记忆运行时与 RMS 认知展示
6. 工作流与子代理协作
7. 设置、配置与运行期开关
8. 质量、恢复与可观测性

## 3. 已实现能力范围

### 3.1 聊天与会话

- 支持 SwiftAnthropic 驱动的流式对话。
- 支持本地会话持久化、多会话切换与消息历史回放。
- 支持用户消息、Agent 消息、思考内容、工具调用结果等多种消息形态。
- 输入区已集成 Todo 卡片展示与斜杠命令相关状态投影。

代表性证据：

- `agentGui/Views/ChatView.swift`
- `agentGui/Services/ClaudeService+Messaging.swift`
- `agentGui/Models/Message.swift`
- `agentGuiTests/ClaudeServiceMessagingTests.swift`
- `agentGuiTests/ChatComposerTodoCardPresentationTests.swift`

### 3.2 Agent Loop 与验证/反思闭环

- 已形成 round-based Agent Loop 主链，包含 planning、tooling、verifying、reflecting 等阶段化执行。
- 已具备 Hook 化的主循环扩展点，并覆盖 memory bootstrap、tool audit、business observability、failure classification、stream projection 等能力。
- 已具备 verification coordinator、reflection hook 和执行保护相关能力。
- 验证仍以当前实现为准，尚未升级到新的 agent-first verification control loop。

代表性证据：

- `agentGui/Services/AgentLoopRunner.swift`
- `agentGui/Services/AgentLoopRoundExecutor.swift`
- `agentGui/Services/AgentLoopVerificationCoordinator.swift`
- `agentGuiTests/AgentLoopIntegrationTests.swift`
- `agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`
- `agentGuiTests/AgentLoopExecutionGuardTests.swift`

### 3.3 工具系统与受管执行

- 已具备统一工具定义与注册主链。
- 已支持文件编辑、Todo、Web Fetch、Web Search、图片分析、PDF 读取、用户提问、子代理委派等工具。
- Bash 工具已升级为受管终端运行时，支持前台/后台/交互模式、提示词自动处理、状态归纳与 UI 投影。
- 已具备大文本预算治理和超大工具输出的 payload store。

代表性证据：

- `agentGui/Services/ToolRegistry.swift`
- `agentGui/Services/ClaudeService+BashTool.swift`
- `agentGui/Services/BashSession.swift`
- `agentGui/Services/ToolPayloadStore.swift`
- `agentGuiTests/BashToolSchemaTests.swift`
- `agentGuiTests/BashToolCallPresentationTests.swift`

### 3.4 工作区、文件、Git 与 LSP

- 已具备工作区侧栏、文件树、文件编辑器与外部刷新相关能力。
- 已具备 Git 状态读取、分支切换、Diff 查看和中文路径场景支持。
- 已具备 LSP 进程监督、工作区状态投影与诊断展示。
- 当前实现已经满足“基础工作区辅助能力”基线，但不把更深层的 LSP 可靠性增强计入本次基线。

代表性证据：

- `agentGui/Views/WorkspacePanelView.swift`
- `agentGui/Views/FileEditorView.swift`
- `agentGui/Views/GitPanelView.swift`
- `agentGui/Services/GitService.swift`
- `agentGui/Services/LSP/LSPProcessSupervisor.swift`
- `agentGuiTests/ClaudeServiceWorkspaceContextTests.swift`

### 3.5 统一记忆运行时与 RMS 认知展示

- 已具备 unified memory store、runtime coordinator、prompt assembler 和治理相关基础设施。
- 任务记忆已进入统一运行时主链，旧 TaskMemory 路径已不再是核心读路径。
- 产品主路径中的 memory UI 已收敛为 RMS 认知面板，围绕 frontiers、counterexamples、constraints、verification debt、influence trace 与建议动作展示当前认知状态。
- 当前基线认可“RMS 认知面板已落地”，但不把 2026-03-14 新提出的 agent-first memory / phase 1-3 gap closure 计划计入已完成能力。

代表性证据：

- `agentGui/Services/MemoryRuntimeCoordinator.swift`
- `agentGui/Services/EpistemicStateCoordinator.swift`
- `agentGui/ViewModels/RMSCognitionPanelViewModel.swift`
- `agentGui/Views/Memory/RMSCognitionPanel.swift`
- `agentGuiTests/EpistemicStateCoordinatorTests.swift`
- `agentGuiTests/EpistemicStateTests.swift`

### 3.6 工作流与子代理协作

- 已具备 workflow runtime、workflow instance、artifact 收集与业务观测。
- 已支持多子代理定义、权限范围与任务委派。
- 当前产品已具备面向编码类场景的基础工作流能力。

代表性证据：

- `agentGui/Services/WorkflowRuntime.swift`
- `agentGui/Services/WorkflowAgentRunner.swift`
- `agentGui/Models/WorkflowInstance.swift`
- `agentGuiTests/WorkflowBusinessObservabilityTests.swift`

### 3.7 设置、配置与运行期开关

- 已具备独立设置窗口与分区化设置导航。
- 已支持模型、连接、工具、记忆、智能与通用设置。
- Memory / RMS 相关 rollout 已进入设置页主路径。

代表性证据：

- `agentGui/Views/Settings/SettingsWindowView.swift`
- `agentGui/Views/Settings/SettingsMemoryView.swift`
- `agentGui/Views/Settings/SettingsStore.swift`
- `agentGui/Models/AppSettings.swift`

### 3.8 质量、恢复与可观测性

- 已具备数据一致性检查、备份归档、运行时恢复与业务观测能力。
- 仓库已提供 `Quality Smoke`、`Sample UI Baseline`、`Sample Unit Baseline` 脚本与 VS Code task。
- 当前工作区上下文显示最近一次 `./scripts/run_quality_smoke.sh` 退出码为 65，因此“存在 smoke gate”计入基线，但“当前 smoke 全绿”不计入本次基线结论。

代表性证据：

- `agentGui/Services/DataIntegrityChecker.swift`
- `agentGui/Services/BackupArchiveService.swift`
- `agentGui/Services/RuntimeRecoveryService.swift`
- `scripts/run_quality_smoke.sh`
- `scripts/sample_quality_baseline.sh`

## 4. 明确不纳入本次基线的内容

以下内容在仓库内已有研究、需求或计划文档，但当前不计入“已实现能力基线”：

1. agent-first verification control loop
2. RMS agent-first memory 重构与 phase 1-3 gap closure
3. 安全、密钥与权限中心
4. 更完整的能力发现与引导体系
5. 创作记忆 / Story Memory 的新一轮产品化闭环

原因只有一个：这些方向虽已有设计输入，但当前仍属于在研或持续迭代，不应与已经稳定落地的主链能力混写。

## 5. 归档判定原则

本次归档只处理两类文档：

1. 已被后续文档明确替代的旧需求/旧计划。
2. 已形成稳定实现，且不再作为当前主设计输入的早期需求/计划。

本次不归档 2026-03-14 当天新建或仍处于主线讨论中的研究、需求和实现计划，以避免与当前迭代冲突。

## 6. 本次归档清单

### 6.1 已替代或已完成的需求文档

- `docs/spec/2026-03-09-story-project-inspector-display-requirements.md`
  原因：已被 `2026-03-10-story-project-inspector-tabbed-requirements.md` 明确替代。
- `docs/spec/2026-03-10-bash-tool-redesign-requirements.md`
  原因：Bash 受管终端运行时已进入当前产品基线。
- `docs/spec/2026-03-10-chatview-agent-message-ui-requirements.md`
  原因：当前消息区 UI 主链已落地，不再作为活动需求文档。
- `docs/spec/2026-03-10-chatview-agent-message-ui-wireframes.md`
  原因：仅服务于上一轮已落地消息区 UI 设计。
- `docs/spec/2026-03-10-markdown-message-view-requirements.md`
  原因：Markdown 消息解析与渲染链已落地。
- `docs/spec/2026-03-11-basic-git-ui-requirements.md`
  原因：基础 Git UI 已进入当前产品基线。
- `docs/spec/2026-03-11-git-panel-ui-and-chinese-path-requirements.md`
  原因：GitPanel 与中文路径场景已落地。
- `docs/spec/2026-03-11-input-area-todo-list-requirements.md`
  原因：输入区 Todo 卡片与持久化链路已落地。
- `docs/spec/2026-03-11-workspace-sidebar-git-panel-layout-requirements.md`
  原因：GitPanel 布局收敛已体现到当前工作区 UI。

### 6.2 已完成或已失效的实现计划

- `docs/plans/2026-03-10-bash-tool-redesign.md`
- `docs/plans/2026-03-10-chatview-agent-message-ui.md`
- `docs/plans/2026-03-10-markdown-message-view.md`
- `docs/plans/2026-03-10-story-project-inspector-display.md`
- `docs/plans/2026-03-11-basic-git-ui-implementation-plan.md`
- `docs/plans/2026-03-11-git-panel-ui-and-chinese-path-implementation-plan.md`
- `docs/plans/2026-03-11-input-area-todo-list-implementation-plan.md`
- `docs/plans/2026-03-11-workspace-sidebar-gitpanel-simplification-implementation-plan.md`

这些计划均对应已经形成代码主链或已被后续方案替代的阶段性工作，不再适合作为当前实现输入。

## 7. 使用建议

后续新增需求或实现计划时，建议统一先对照本文档判断：

1. 这是补现有基线，还是开新能力域。
2. 这是已落地主链上的增强，还是仍在研究阶段。
3. 是否应先引用本基线，再追加增量需求，而不是重复创建全量重写式文档。