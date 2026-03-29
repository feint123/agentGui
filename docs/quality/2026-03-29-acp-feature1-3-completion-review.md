# ACP Feature 1-3 完成度审查

日期：2026-03-29

范围：对 [docs/plans/2026-03-29-acp-runtime-state-refresh-requirements.md](docs/plans/2026-03-29-acp-runtime-state-refresh-requirements.md) 中 Feature 1 到 Feature 3 的实现现状做代码审查，并整理仍未完成的部分。

## 结论摘要

| Feature | 结论 | 说明 |
| --- | --- | --- |
| Feature 1: 执行投影单写口收敛 | 已完成 | orchestrator 已改为只发 lifecycle event，projection 由 reducer 统一收敛，测试覆盖 queued、running、cancelled、failed、recovering。 |
| Feature 2: 删除 SessionExecutionRegistry 兼容层 | 已完成 | `SessionExecutionRegistry` 与 `SessionExecutionController` 已删除，聊天输入区与消息列表的执行态也已收敛到 `ExecutionProjectionStore`。 |
| Feature 3: runtime retention 真值下沉 | 已完成 | runtime coordinator 已改为读取 `SessionExecutionRuntimeStateStore`，且已有 projection 滞后场景测试。 |

## Feature 1 审查结果

已核实项：

1. 统一 reducer 已落地，见 [agentGui/Services/Execution/SessionExecutionProjectionReducer.swift](agentGui/Services/Execution/SessionExecutionProjectionReducer.swift)。
2. `ConversationExecutionOrchestrator` 的 enqueue、recover、start、finish、prune 路径都通过 `projectionWriter.apply(...)` 发出统一事件，见 [agentGui/Services/Execution/ConversationExecutionOrchestrator.swift](agentGui/Services/Execution/ConversationExecutionOrchestrator.swift)。
3. `ExecutionProjectionStore` 已成为 reducer 的单写入口，见 [agentGui/Services/Execution/ExecutionProjectionStore.swift](agentGui/Services/Execution/ExecutionProjectionStore.swift)。
4. `SessionExecutionProjection(...)` 的手工组装在业务代码中已收敛，只剩模型默认值、reducer 内部构造和测试夹具各 1 处；未发现需求文档中所描述的“5 处以上手工组装”现象。
5. reducer 测试已覆盖 queued、running、cancelled、failed、recovering 五类路径，见 [agentGuiTests/SessionExecutionProjectionReducerTests.swift](agentGuiTests/SessionExecutionProjectionReducerTests.swift)。

结论：Feature 1 当前无需补实现。

## Feature 2 审查结果

已核实项：

1. `SessionExecutionRegistry.swift` 与 `SessionExecutionController.swift` 已从仓库中删除。
2. `WorkspaceState` 已改为绑定 `ExecutionProjectionStore`，不再持有 execution registry，见 [agentGui/Utilities/WorkspaceState.swift](agentGui/Utilities/WorkspaceState.swift)。
3. `WorkbenchShellView` 启动时直接注入 `ExecutionProjectionStore`，见 [agentGui/Views/Workbench/WorkbenchShellView.swift](agentGui/Views/Workbench/WorkbenchShellView.swift)。
4. 会话列表、聊天页、Agent Studio 等执行态展示入口均已直接读取 projection store 或 `WorkspaceState.executionProjection(...)` facade，见 [agentGui/Views/SessionListView.swift](agentGui/Views/SessionListView.swift)、[agentGui/Views/ChatView.swift](agentGui/Views/ChatView.swift)、[agentGui/Views/Studio/AgentStudioWindowView.swift](agentGui/Views/Studio/AgentStudioWindowView.swift)。
5. “无 registry 仍正确”的回归测试已存在，见 [agentGuiTests/WorkspaceStateTests.swift](agentGuiTests/WorkspaceStateTests.swift)。

后续完成情况（2026-03-30）：

1. `ChatComposerExecutionPresentation.resolve(...)` 已删除 `legacyIsStreaming` 参数，composer 的 disabled / stop-button / send-button 状态完全由 `SessionExecutionProjection` 决定。
2. [agentGui/Views/ChatView+InputArea.swift](agentGui/Views/ChatView+InputArea.swift) 已不再向 presentation 传入 `claudeService.isStreaming`。
3. [agentGui/Views/ChatView.swift](agentGui/Views/ChatView.swift) 的 `effectiveStreamingState` 已直接读取 `sessionExecutionProjection.isRunning`，消息列表与相关交互不再依赖 legacy streaming fallback。
4. [agentGuiTests/ChatComposerExecutionPresentationTests.swift](agentGuiTests/ChatComposerExecutionPresentationTests.swift) 已补充空闲 projection 场景，锁定无 legacy fallback 时的 composer 展示行为。

结论：Feature 2 现已完成。

## Feature 3 审查结果

已核实项：

1. `ConversationExecutionRuntimeCoordinator` 已注入独立的 `SessionExecutionRuntimeStateStore`，见 [agentGui/Services/ConversationExecutionRuntimeCoordinator.swift](agentGui/Services/ConversationExecutionRuntimeCoordinator.swift)。
2. `shouldProtectRuntime(...)` 已改为读取 `runtimeStateStore.state(for:)`，不再读取 UI projection。
3. `SessionExecutionLifecycleFanoutWriter` 会把同一批 lifecycle event 同时写入 projection store 和 runtime state store，见 [agentGui/Services/Execution/SessionExecutionLifecycleFanoutWriter.swift](agentGui/Services/Execution/SessionExecutionLifecycleFanoutWriter.swift)。
4. runtime snapshot reducer/store 测试已经存在，见 [agentGuiTests/SessionExecutionRuntimeStateReducerTests.swift](agentGuiTests/SessionExecutionRuntimeStateReducerTests.swift) 与 [agentGuiTests/SessionExecutionRuntimeStateStoreTests.swift](agentGuiTests/SessionExecutionRuntimeStateStoreTests.swift)。
5. runtime coordinator focused tests 已覆盖 projection 滞后场景，见 [agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift](agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift)。

结论：Feature 3 当前无需补实现。

## 最终遗漏清单

当前未再确认 Feature 1 至 Feature 3 范围内的剩余缺口。