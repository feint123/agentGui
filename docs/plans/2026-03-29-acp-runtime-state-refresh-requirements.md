# ACP Runtime、后台状态同步与消息刷新优化需求文档

日期：2026-03-29

状态：待评审

适用范围：ACP 外部 provider 执行链路、会话执行 runtime 生命周期、后台状态投影、消息列表刷新、恢复摘要、相关测试与可观测性

## 1. 背景

当前 ACP 执行链路已经从“单次直接 send 调用”演进到了“job + scheduler + runtime retention + projection store”的中间态，基础方向是对的，但系统仍然同时存在以下三种模型：

1. 以 `ConversationExecutionOrchestrator` 为中心的作业编排。
2. 以 `ConversationExecutionRuntimeCoordinator` 为中心的运行时保活与释放。
3. 以 `SessionExecutionRegistry` / `SessionExecutionController` 为代表的遗留会话状态同步层。

这使得 ACP 的执行状态、后台运行状态和 UI 刷新状态还没有收敛到单一事实源，导致功能可用但结构脆弱，继续叠加功能会放大复杂度。

## 2. 调研范围

本次调研重点检查了以下代码：

1. [agentGui/Services/Execution/ConversationExecutionOrchestrator.swift](agentGui/Services/Execution/ConversationExecutionOrchestrator.swift#L5)
2. [agentGui/Services/ConversationExecutionRuntimeCoordinator.swift](agentGui/Services/ConversationExecutionRuntimeCoordinator.swift#L5)
3. [agentGui/Services/Execution/ExecutionProjectionStore.swift](agentGui/Services/Execution/ExecutionProjectionStore.swift)
4. [agentGui/Services/Execution/SessionExecutionRegistry.swift](agentGui/Services/Execution/SessionExecutionRegistry.swift#L6)
5. [agentGui/Services/Execution/SessionExecutionController.swift](agentGui/Services/Execution/SessionExecutionController.swift)
6. [agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift](agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift#L38)
7. [agentGui/Views/ChatView+MessageList.swift](agentGui/Views/ChatView+MessageList.swift)
8. [agentGui/Services/RuntimeRecoveryService.swift](agentGui/Services/RuntimeRecoveryService.swift#L7)
9. [agentGui/Services/Execution/ExecutionPersistenceStore.swift](agentGui/Services/Execution/ExecutionPersistenceStore.swift)
10. [agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift](agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift)

同时参考了已有设计与实施文档：

1. [docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-design.md](docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-design.md)
2. [docs/plans/2026-03-23-acp-runtime-session-scheduler-design.md](docs/plans/2026-03-23-acp-runtime-session-scheduler-design.md)
3. [docs/plans/2026-03-28-session-runtime-acp-observability-implementation-plan.md](docs/plans/2026-03-28-session-runtime-acp-observability-implementation-plan.md)

## 3. 现状评审结论

### 3.1 P0: 执行状态仍然不是单一事实源

`ConversationExecutionOrchestrator` 在入队、恢复、开始执行、结束执行、清理非法 job 时都直接手工构造并写入 `SessionExecutionProjection`，入口分散在 [agentGui/Services/Execution/ConversationExecutionOrchestrator.swift](agentGui/Services/Execution/ConversationExecutionOrchestrator.swift#L54)、[agentGui/Services/Execution/ConversationExecutionOrchestrator.swift](agentGui/Services/Execution/ConversationExecutionOrchestrator.swift#L105)、[agentGui/Services/Execution/ConversationExecutionOrchestrator.swift](agentGui/Services/Execution/ConversationExecutionOrchestrator.swift#L414)、[agentGui/Services/Execution/ConversationExecutionOrchestrator.swift](agentGui/Services/Execution/ConversationExecutionOrchestrator.swift#L463)。

与此同时，`SessionExecutionController` 仍然会维护自己的 `projection` 副本，并在变更后反向写回 store；`SessionExecutionRegistry.projection(for:)` 又依赖显式 `syncFromStore()` 才能避免陈旧数据，见 [agentGui/Services/Execution/SessionExecutionController.swift](agentGui/Services/Execution/SessionExecutionController.swift) 与 [agentGui/Services/Execution/SessionExecutionRegistry.swift](agentGui/Services/Execution/SessionExecutionRegistry.swift#L28)。

这意味着系统存在“双写 + 显式补同步”的状态模型。当前还能工作，主要依赖调用顺序正确，而不是依赖状态收敛设计正确。

### 3.2 P0: runtime 生命周期决策依赖同步投影读取，边界分散

`ConversationExecutionRuntimeCoordinator` 在激活和收敛阶段都通过 `projectionStore.projection(for:)` 判断是否应该保护某个 runtime，相关入口位于 [agentGui/Services/ConversationExecutionRuntimeCoordinator.swift](agentGui/Services/ConversationExecutionRuntimeCoordinator.swift#L28)、[agentGui/Services/ConversationExecutionRuntimeCoordinator.swift](agentGui/Services/ConversationExecutionRuntimeCoordinator.swift#L71)、[agentGui/Services/ConversationExecutionRuntimeCoordinator.swift](agentGui/Services/ConversationExecutionRuntimeCoordinator.swift#L185)。

问题不在于逻辑错误，而在于它依赖的是 UI 投影结果，而不是调度层内部真值。换言之，runtime retention 目前建立在“projection 已经被正确更新”的前提上，一旦 projection 写入滞后、遗漏或被遗留 registry 覆盖，就会出现 runtime 保护或释放时机异常。

### 3.3 P1: 大量执行路径仍在 MainActor 上，后台状态更新与恢复存在主线程热点

`ConversationExecutionOrchestrator`、`ExecutionProjectionStore`、`RuntimeRecoveryService`、`ChatMessageListProjectionModel` 都在 `@MainActor` 上运行，见 [agentGui/Services/Execution/ConversationExecutionOrchestrator.swift](agentGui/Services/Execution/ConversationExecutionOrchestrator.swift#L5)、[agentGui/Services/RuntimeRecoveryService.swift](agentGui/Services/RuntimeRecoveryService.swift#L7)、[agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift](agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift#L74)。

其中 `RuntimeRecoveryService.refresh(from:)` 会全量 fetch `Message` 和 `RecoverySnapshot`，并在主线程上做 upsert、删除、排序，见 [agentGui/Services/RuntimeRecoveryService.swift](agentGui/Services/RuntimeRecoveryService.swift#L20)。这会和启动时 bootstrap、会话切换、消息刷新竞争主线程预算。

### 3.4 P1: 消息列表刷新是“主线程增量缓存”，不是“后台可约简投影”

`ChatMessageListProjectionRefreshCoordinator` 只是先做 trigger 比较，再由 `ChatMessageListSnapshotBuilder.build` 顺序遍历所有 message 构建 snapshot；`ChatMessageListProjectionModel.refresh` 依然跑在主线程，只做了一次 `Task.yield()`，见 [agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift](agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift#L45)、[agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift](agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift#L79)、[agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift](agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift#L113)。

这套机制在中小消息量时足够，但在以下场景会放大开销：

1. agent round/tool call 丰富、fingerprint 结构越来越重。
2. streaming 期间最后一条消息频繁变化。
3. 工作目录变化导致所有 fingerprint 带着 `workspaceRoot` 失效。
4. 会话恢复或大量历史消息加载时需要一次性重建快照。

### 3.5 P1: ACP provider base 仍承担过多会话级职责

`ACPExternalExecutionProviderBase` 同时持有 runtime supervisor、feature extractor、update projector、turn router、session state store 和 update queue，并直接编排 `ensureRemoteSessionPrepared -> setSessionConfigOption -> prompt -> drainPendingUpdates -> flushProjectedUpdates -> finalizeAssistantMessage` 整条链路，见 [agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift](agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift)。

这说明 ACP provider 目前仍是“provider facade + runtime supervisor + session actor + projection coordinator”的混合体。短期可维护，长期不利于：

1. provider 间共享统一执行语义。
2. 后台状态事件化。
3. session 级恢复与可观测性独立演进。

### 3.6 P2: WorkspaceState 仍保留遗留 execution registry，迁移尚未完成

`WorkspaceState` 默认持有 `SessionExecutionRegistry`，`WorkbenchShellView` 启动时还会重新注入一个绑定到 `ExecutionProjectionStore` 的实例，见 [agentGui/Utilities/WorkspaceState.swift](agentGui/Utilities/WorkspaceState.swift#L76) 与 [agentGui/Views/Workbench/WorkbenchShellView.swift](agentGui/Views/Workbench/WorkbenchShellView.swift#L78)。

这说明 direct-store UI 虽然已存在，但应用层还没有彻底删除 registry 兼容层，未来每加一个执行态展示点，都有再次接回旧模型的风险。

## 4. 需求目标

### 4.1 核心目标

1. 执行 runtime、后台状态和 UI 展示都从单一事实源派生，不再存在双写补同步。
2. runtime retention 与 provider release 决策直接依赖运行时真值，而不是依赖 UI projection 是否恰好最新。
3. 消息列表刷新从“主线程构建全量快照”演进到“后台可约简、主线程只发布结果”。
4. 启动恢复、后台状态恢复、会话切换不会明显阻塞主线程。
5. ACP provider 会话级状态从 provider base 中剥离，逐步收敛成独立 session runtime 单元。
6. 相关行为必须有 focused tests 覆盖，避免再依赖复杂手工 fixture 和隐式共享 store。

### 4.2 非目标

1. 本轮不重写整个聊天 UI。
2. 本轮不引入完整 event sourcing 平台替换所有现有持久化。
3. 本轮不改 ACP 协议本身，只改本地 runtime 管理与状态流。
4. 本轮不要求一次性删光所有历史实现，但必须按 feature 明确收敛方向和删减节点。

## 5. 需求原则

1. 单一事实源优先于兼容层保留。
2. actor 真值优先于 MainActor 上的派生状态。
3. reducer / projection 负责 UI 可读性，不负责 runtime 生命周期决策。
4. 恢复链路和实时链路必须共享同一套状态转移规则。
5. 消息刷新、运行状态刷新、恢复摘要刷新都要具备可测量的性能指标。

## 6. 小 Feature 拆分

### Feature 1: 执行投影单写口收敛

目标：把 `SessionExecutionProjection` 的写入入口从“编排器多点手写 + controller 回写”收敛成一个 reducer 或 command bus。

范围：

1. 抽出统一的 projection reducer，输入为 execution lifecycle event。
2. `ConversationExecutionOrchestrator` 不再直接拼 projection 结构体。
3. `SessionExecutionController` 只读或删除，不允许继续反向写 store。

验收标准：

1. 代码仓库中不再存在 5 处以上手工 `SessionExecutionProjection(...)` 组装。
2. 任一 job 的 enqueue、start、finish、prune 都通过同一条 reducer 路径更新投影。
3. 相关测试覆盖 queued、running、cancelled、failed、recovering 五种路径。

依赖：无。

### Feature 2: 删除 SessionExecutionRegistry 兼容层

目标：清理遗留 execution registry，让 `ExecutionProjectionStore` 成为唯一会话执行展示来源。

范围：

1. 梳理 `WorkspaceState`、shell、命令面板、会话列表等剩余 consumer。
2. 将所有调用迁移到 direct-store 或新的 projection facade。
3. 删除 `SessionExecutionRegistry` 与 `SessionExecutionController`。

验收标准：

1. 应用层不再持有 `executionRegistry`。
2. 所有执行态 UI 只读取 `ExecutionProjectionStore` 或其替代 facade。
3. 现有 projection 同步回归测试可转化为“无 registry 仍正确”的测试。

依赖：Feature 1。

### Feature 3: runtime retention 真值下沉

目标：runtime 保活与释放直接依赖 execution runtime 真值，而不是依赖同步 projection 快照。

范围：

1. 为 runtime coordinator 引入独立的 session runtime state 输入。
2. 把 `shouldProtectRuntime` 依赖从 UI projection 切到 runtime state snapshot。
3. 明确 foreground、dispatch lease、running lease、release plan 的优先级规则。

验收标准：

1. selection 切换、dispatch、finish、provider 切换的 retain/release 规则只由 runtime snapshot 决定。
2. 即便 UI projection 延迟发布，runtime 也不会被错误释放。
3. 现有 runtime coordinator focused tests 保留并补充 projection 滞后场景。

依赖：Feature 1。

### Feature 4: session runtime 状态总线

目标：在 orchestrator、runtime coordinator、recovery service 之间建立统一的 session runtime event / snapshot 总线。

范围：

1. 定义 session runtime snapshot DTO。
2. enqueue/start/finish/recover/cancel 都产出统一事件。
3. runtime coordinator、projection store、diagnostics 面板从同一 snapshot 派生。

验收标准：

1. enqueue、dispatch、finish、recover 至少 4 类动作都能产出一致 snapshot。
2. 启动恢复后 UI 和 runtime coordinator 看到的是同一份状态。
3. 测试中不再需要额外共享多个 projection store 才能让断言成立。

依赖：Feature 1，Feature 3。

### Feature 5: RuntimeRecoveryService 异步化与增量化

目标：把恢复摘要刷新从主线程全量扫描改为异步、增量、可合并更新。

范围：

1. 把 `RuntimeRecoveryService.refresh(from:)` 的全量 fetch / upsert 拆到后台 actor 或后台协调器。
2. 引入增量恢复源，只处理新增或仍未结项的 pending message / task。
3. 为启动阶段增加节流与批处理策略。

验收标准：

1. 启动进入聊天页时恢复刷新不阻塞首屏消息渲染。
2. 大量历史消息存在时，恢复刷新时间与“当前未完成项数量”近似相关，而不是与“全量消息数”线性相关。
3. 有专门性能基线测试或 smoke 指标。

依赖：Feature 4。

### Feature 6: 消息列表后台投影构建

目标：把消息列表 snapshot 构建从主线程搬到后台可计算路径，主线程只接受已经完成的快照结果。

范围：

1. 将 `ChatMessageListSnapshotBuilder.build` 改造成后台 builder 或 reducer。
2. 引入 generation / cancellation 机制，避免过期快照覆盖新结果。
3. 将 `workspaceRoot` 变化造成的全量失效限制在必要字段范围内。

验收标准：

1. 大会话切换时主线程不会因为 snapshot build 明显卡顿。
2. streaming 更新期间最后一条消息可持续刷新，且不会造成全量重建风暴。
3. 现有刷新测试保留，并新增“大量消息 + 高频增量”场景。

依赖：无。

### Feature 7: 消息刷新触发器瘦身

目标：降低 `MessageRowFingerprint` 的失效面，避免和业务无关的字段导致整行重复投影。

范围：

1. 重新审视 fingerprint 字段，把纯展示配置与语义数据分离。
2. tool call / round 的 fingerprint 引入分层比较，避免深层 JSON 字段频繁传播。
3. 对工作目录变化采用局部派生，而不是把 `workspaceRoot` 直接并入所有 row identity。

验收标准：

1. 改动工作目录时，不会无意义重建未依赖路径展示的消息行。
2. tool call 附带的大字段更新不会导致整页频繁重建。
3. 指纹字段数量和比较成本有明确上限说明。

依赖：Feature 6。

### Feature 8: ACP session actor 单写入口落地

目标：先把单个 `(provider, localSession)` 的发送主路径收敛到一个 session actor，建立最小可用的单写入口。

范围：

1. `send` 主路径中的 live turn 写操作统一从 session actor 进入。
2. session actor 独占 begin prompt、flush projected updates、finalize assistant message 等顺序敏感动作。
3. provider base 停止直接编排一次完整 live turn 的可变状态变更。

验收标准：

1. 单个 `(provider, localSession)` 的 live turn 写操作只通过一个 actor 串行进入。
2. `send` 路径上的主流程 focused tests 可以断言 begin prompt、flush、finalize 由 session actor 执行。
3. provider base 在 live turn 主路径上的直接状态突变明显减少，且不再承担单次发送的完整阶段推进。

依赖：Feature 4。

### Feature 9: ACP session bootstrap 与配置变更内聚

目标：把 remote session bootstrap、session mode/config 变更一起收进 session actor，避免 restore 之后仍回退到 base class 多点写入。

范围：

1. `ensureRemoteSessionPrepared`、restore gate、bootstrap feature events 的会话级流程统一经由 session actor 协调。
2. `updateSessionMode`、`updateSessionConfigOption` 等入口通过 session actor 触发，而不是绕开 actor 直接改 runtime/client。
3. permission resolution、session config draft、activation 关联状态不再散落在 base class 多处拼接。

验收标准：

1. mode/config 更新在测试中会先命中 restore/bootstrap，再进入对应变更动作。
2. session restore 与首次发送使用同一套会话级状态转移规则。
3. provider base 只保留 provider 级配置解析和 runtime supervisor 接线，不再直接维护会话 bootstrap 时序。

依赖：Feature 8。

### Feature 10: ACP session update 投影链路迁移

目标：把 update queue、turn router、update projector、session state store 这一整条会话更新链路从 base class 逐步迁到 session actor 内部或其专属协作者。

范围：

1. live turn / restore phase 判断不再由 base class 直接维护。
2. projected updates 的节流、flush、reset 改为 session actor 内聚管理。
3. 会话级 feature store、pending mutation batch、active turn 归属收敛到单 session 写者模型。

验收标准：

1. provider base 不再直接持有多种 session 级可变状态容器。
2. session update 的投影/flush/reset 顺序可以通过 focused tests 稳定断言。
3. update projector、turn router、session state store 至少不再由 base class 直接驱动主流程。

依赖：Feature 8，Feature 9。

### Feature 11: ACP cancel、release 与重试生命周期收敛

目标：把 cancel、releasePreparedRuntime、warmup retry/reset 等易出错生命周期边界并入 session actor 状态机，避免缓存 actor 被脏状态污染。

范围：

1. cancel、release、provider 切换、会话失焦后的清理规则由 session actor 统一执行。
2. warmup / prepare 失败后的 runtime state machine 与 session actor phase 必须一起复位。
3. 明确 activation 失效、stale update 丢弃、runtime rebuild 后重新进入 restore 的规则。

验收标准：

1. warmup retry 后不会残留 `.startingRuntime`、`.restoring` 等脏 phase 导致后续 invalid transition。
2. stale activation update 不会污染新的 session actor 状态。
3. cancel、release、跨 provider 切换路径具备 focused tests，且生命周期错误能被稳定复现和防回归。

依赖：Feature 9，Feature 10。

### Feature 12: ACP 运行时可观测性补齐

目标：为 runtime 激活、release、attach、restore、prompt、flush、cancel 建立统一诊断事件，方便定位后台状态不同步问题。

范围：

1. 引入统一 trace / session diagnostics snapshot。
2. 对 runtime coordinator、orchestrator、provider session actor 打统一日志标签。
3. 为 UI 或 diagnostics 面板暴露最近一次状态迁移链路。

验收标准：

1. 任一 session 可以追踪最近一次 activation 到 finish 的关键事件序列。
2. release 错误、projection 滞后、recovery replay 都能在诊断层被区分。
3. 测试可断言关键事件序列，而不是只断言最终 UI 状态。

依赖：Feature 4，Feature 11。

### Feature 13: ACP runtime 测试夹具去脆弱化

目标：降低当前 ACP focused tests 对共享 store、长寿命 fixture 进程、隐式初始化顺序的依赖。

范围：

1. 标准化 runtime fixture 生命周期。
2. 为 projection/runtime snapshot 提供统一 harness。
3. 把“必须共享同一个 projection store 才会通过”的测试前提显式化，并在重构后删除。

验收标准：

1. runtime retention、provider isolation、recovery 场景都可以通过统一 harness 构建。
2. fixture 失败能明确报出生命周期错误，而不是表现为挂起或随机失败。
3. focused tests 可以稳定在干净 derived data 下通过。

依赖：Feature 4，Feature 11。

## 7. 推荐实施顺序

建议顺序如下：

1. Feature 1：先收敛 execution projection 单写口。
2. Feature 2：删除 registry 兼容层，切断双写回路。
3. Feature 3：让 runtime retention 从 UI projection 脱钩。
4. Feature 4：建立 session runtime snapshot / event 总线。
5. Feature 5：处理 recovery 主线程热点。
6. Feature 6：处理消息列表后台投影构建。
7. Feature 7：缩小 fingerprint 失效面。
8. Feature 8：先落地 ACP session actor 单写入口。
9. Feature 9：再把 bootstrap 与配置变更并入 actor。
10. Feature 10：迁移 session update 投影链路。
11. Feature 11：收敛 cancel、release 与重试生命周期。
12. Feature 12：补齐 runtime observability。
13. Feature 13：统一和加固测试夹具。

这个顺序的原因是：先收敛状态真值，再做后台化和可观测性，否则只是把现有复杂度换个线程继续保留。

## 8. 验收指标

### 功能指标

1. 多会话并行执行时，切换 foreground session 不会错误释放后台运行 runtime。
2. 会话执行状态在会话列表、聊天页、恢复摘要之间保持一致。
3. 恢复后 queued/running job 的状态重建与实时路径一致。

### 性能指标

1. 聊天页首屏渲染不应被恢复摘要刷新明显拖慢。
2. 大消息会话切换时，消息列表刷新耗时应显著低于当前主线程全量构建方案。
3. streaming 高频更新期间，消息列表刷新应避免整页重复重建。

### 工程指标

1. `SessionExecutionRegistry` 与 `SessionExecutionController` 最终删除。
2. 运行态生命周期关键决策有 focused tests。
3. ACP runtime 关键路径具备可追踪诊断事件。

## 9. 风险与注意事项

1. 如果先做 ACP provider actor 化而不先收敛 execution projection，复杂度会叠加而不是下降。
2. 如果先把消息列表搬到后台，但 fingerprint 设计不收敛，后台计算量仍然会被无意义字段放大。
3. 如果 recovery 仍依赖全量 SwiftData 扫描，即便 runtime 主链路 actor 化，启动卡顿问题仍会保留。
4. 如果测试夹具不先标准化，后续任何 runtime 重构都容易被伪回归噪音掩盖。

## 10. 建议输出物

本需求文档之后，建议拆出三份实施文档：

1. `execution-projection-single-source`：覆盖 Feature 1-4。
2. `chat-message-projection-performance`：覆盖 Feature 5-7。
3. `acp-session-runtime-actorization`：覆盖 Feature 8-13。

这样可以把“状态真值收敛”“消息刷新性能”“ACP session 管理剥离”三条主线分开推进，避免一个超大重构同时横穿所有层。