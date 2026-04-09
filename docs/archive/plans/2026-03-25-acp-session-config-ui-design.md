# 2026-03-25 ACP 会话配置与 UI 交互重构设计

日期：2026-03-25

目标：修正当前 external ACP provider 在模型切换上的协议使用错误，改为基于 ACP 标准的 `session/set_config_option` 与 `session/set_mode`；同时重构会话创建与会话内配置 UI，让执行器在建会话时确定、会话内只切换 mode / model / approvals，并把可选模型列表从远端 `session/new` / `session/load` / `session/update` 动态获取，而不是本地硬编码。

关联对象：

1. `agentGui/Views/SessionListView.swift`
2. `agentGui/Views/ChatView+Toolbar.swift`
3. `agentGui/Views/ChatView+InputArea.swift`
4. `agentGui/Views/ChatView+Actions.swift`
5. `agentGui/Models/Session.swift`
6. `agentGui/Models/SessionExecutionPreferences.swift`
7. `agentGui/Services/ACP/ACPExternalProviderContracts.swift`
8. `agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
9. `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
10. `agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift`
11. `agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
12. `agentGui/Services/ACP/ACPSchemaExtensions.swift`
13. `agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
14. `agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
15. `agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`
16. `agentGui/Models/ACPExternalAgentDescriptor.swift`

关联文档：

1. `docs/plans/2026-03-20-acp-composer-preferences-implementation-plan.md`
2. `docs/plans/2026-03-21-acp-session-load-replay-fix.md`
3. `docs/plans/2026-03-23-acp-runtime-session-scheduler-design.md`
4. `docs/plans/2026-03-24-qoder-cli-acp-integration-design.md`

---

## 1. 结论先行

当前问题不是单纯把 `_github_copilot/session/set_model` 换一个方法名就结束，而是整个 external ACP 会话配置链路还停留在“provider-specific model override”思路，尚未真正切到 ACP 标准会话配置模型。

这导致三类问题同时存在：

1. 协议层错误：GitHub Copilot 已明确不支持 `_github_copilot/session/set_model`，模型切换应通过 `session/set_config_option` 完成。
2. 数据层错误：可选模型列表本来应来自远端 `configOptions`，但当前 UI 仍使用本地写死列表，无法反映 provider 实际支持项。
3. 交互层错误：执行器目前可以在会话内切换，导致一个本地会话可能在生命周期中绑定不同 provider，这与 external ACP runtime 的远端 session 绑定、恢复、能力协商和 feature cache 模型相冲突。

推荐方案是把 external ACP 会话配置分成两层：

1. `执行器选择`：建会话时确定，写入 `Session.defaultExecutionProviderID`，进入会话后不可修改。
2. `会话配置项`：进入会话后由远端 ACP 广告驱动，UI 只呈现当前 provider 暴露的 `modes` 与 `configOptions`，并通过 `session/set_mode` / `session/set_config_option` 回写远端。

其中：

1. `model` 不再是特殊字段，而是一个 category 为 `model` 的 config option。
2. `approvals` 不再依赖本地固定枚举直连 UI，而是优先走远端 config option；仅 built-in agent 保留本地逻辑。
3. `mode` 成为会话内一级可切换项，由远端 `modes.availableModes` 驱动。

本质上，这是把当前“会话内本地覆盖设置”模型升级为“会话创建时确定 provider、会话运行时消费远端声明式配置”。

## 2. 问题定义

### 2.1 当前实现与 ACP 协议的偏差

当前仓库虽然已经定义了以下 ACP 类型：

1. `ACPSetSessionModeRequest`
2. `ACPSetSessionConfigOptionRequest`
3. `ACPSessionConfigOption`
4. `ACPSessionModeState`
5. `ACPConfigOptionUpdatePayload`
6. `ACPCurrentModeUpdatePayload`

但 external ACP 运行时接口仍然只有：

1. `ensureSession(...)`
2. `setModel(...)`
3. `prompt(...)`
4. `cancel(...)`
5. `close()`

也就是说，协议模型已经具备“标准配置项”和“mode 切换”能力，运行时抽象却仍把 `model` 当成唯一可变项，并通过 provider descriptor 中的 `_xxx/session/set_model` extension method 处理。

这套抽象现在已经不成立，至少对 GitHub Copilot 明确不成立。

### 2.2 当前 UI 与 runtime 模型的冲突

当前输入区上方控件存在两个结构性问题：

1. `ExecutionOptionPicker` 允许在会话内切换 provider。
2. `composerExecutionPreferencesControls` 把 model / approval 视为本地静态配置，而不是远端会话状态的一部分。

但 external ACP provider 的事实模型是：

1. 一个本地 session 在某个 provider 下会绑定一个远端 session。
2. restore/load、feature store、runtime activation、pending updates、permission source 都按 `(providerID, localSessionID)` 建模。
3. 会话内改 provider，等价于把当前会话切到另一个远端协议域，会破坏现有 remote binding 与 runtime 调度假设。

因此“会话内切执行器”与 external ACP 架构本身不兼容。

### 2.3 当前数据来源错误

当前可选模型来源存在三种不一致：

1. built-in agent 使用 `AppSettings.availableModelOptions(...)`。
2. Copilot 使用 `ACPCLIConfiguration.copilotModelOptions(...)`。
3. OpenCode / Claude Adapter 仍复用本地写死模型选项。

这会带来两个后果：

1. UI 展示的可选项不一定被远端 provider 接受。
2. 远端实际返回的新模型、新 mode、新 approvals 策略无法透传到 UI。

对于 ACP provider，正确的数据源必须是远端 session 级配置广告，而不是 app 侧静态枚举。

## 3. 设计目标与非目标

### 3.1 设计目标

1. 建立“建会话时选择执行器、进会话后锁定执行器”的一致交互模型。
2. 让 external ACP provider 的 model / mode / approvals 全部由远端 `configOptions` / `modes` 驱动。
3. 用 `session/set_config_option` 替代现有 provider-specific `setModel` 扩展调用。
4. 补齐 `mode` 的会话内切换能力。
5. 保持 built-in agent 的本地配置逻辑不被 external ACP 改造牵连。
6. 让 session/load replay 后的 `configOptions` / `modes` 能恢复 UI 状态，而不是只恢复远端 session ID。
7. 为后续更多 ACP provider 预留一致扩展点，不再把 model 视为特殊 case。

### 3.2 非目标

1. 不在本轮改动 built-in Claude 直连执行器的模型协议。
2. 不在本轮重做 Settings 中各 provider 的全局默认配置页结构。
3. 不在本轮实现 provider 间会话迁移。
4. 不在本轮引入新的跨 session 配置同步机制。
5. 不在本轮处理非 ACP provider 的动态模型拉取。

## 4. 方案备选

### 4.1 方案 A：保留现有本地 UI，只把 setModel 改成 set_config_option

做法：

1. 保留会话内 provider picker。
2. 保留本地静态模型列表。
3. 仅把 `setModel` 的底层 RPC 改为 `session/set_config_option`。

优点：

1. 改动最小。
2. 可以快速修掉当前报错。

缺点：

1. UI 仍与 ACP 数据源脱节。
2. mode 仍缺失。
3. provider 仍可会话内切换，架构问题没有解决。
4. approvals 仍是本地语义优先，无法反映远端广告。

结论：不推荐。这只是热修，不是正确设计。

### 4.2 方案 B：在会话内继续允许切 provider，但切换时重建远端 runtime

做法：

1. 保留当前会话对象。
2. 用户切换 provider 时，清空旧 binding，重建新 provider 的 runtime 与 remote session。

优点：

1. UI 变化少。
2. 用户自由度看起来更高。

缺点：

1. 一个 session 的身份不再稳定，消息历史会混入多个 provider 语义。
2. restore、permissions、feature store、slash commands 都会变得复杂。
3. 与现有 `Session.defaultExecutionProviderID`、runtime activation、binding store 的设计方向冲突。
4. 用户很难理解“为什么同一个会话中前半段是 Copilot，后半段是 OpenCode”。

结论：不推荐。这会放大当前 external ACP 的复杂度。

### 4.3 方案 C：建会话选 provider，运行中消费远端 configOptions/modes

做法：

1. 新建会话入口改为 Picker / Menu 型建会话交互，先选 provider 再创建 session。
2. 会话进入后隐藏 provider 切换，仅显示当前 provider 的动态会话配置项。
3. 外部 ACP runtime 增加 `setSessionMode` 与 `setSessionConfigOption` 标准接口。
4. feature store 新增 `modes` / `configOptions` 的 session 级缓存与恢复。

优点：

1. 符合 ACP 协议语义。
2. 符合当前 external ACP runtime 的单 provider 单会话绑定模型。
3. UI、数据源、运行时抽象三层一致。
4. 未来新 provider 接入时不必重复发明 model 切换逻辑。

缺点：

1. 需要调整新建会话交互。
2. 需要补 feature store 与状态绑定。
3. 需要梳理 provider-specific 全局默认值与远端动态配置的边界。

结论：推荐。

## 5. 推荐方案

推荐采用方案 C，并按以下原则落地。

### 5.1 Provider 选择属于会话创建阶段

创建 session 时用户需要明确本次会话的执行器：

1. built-in agent
2. GitHub Copilot CLI
3. OpenCode CLI
4. Claude Adapter CLI

创建完成后：

1. `Session.defaultExecutionProviderID` 视为会话身份的一部分。
2. Chat 页不再提供修改入口。
3. 复制本地会话时保留 provider。
4. 如果用户想换执行器，应新建会话，而不是重写当前会话。

这与现有 `Session` 模型兼容，不需要新增 provider history 概念。

### 5.2 会话内配置全部按“远端声明，客户端渲染”处理

对 external ACP provider：

1. `mode` 来自 `modes.availableModes` + `modes.currentModeID`。
2. `model` 来自 category 为 `model` 的 `configOptions`。
3. `approvals` 来自 category 为 `approval_mode`、`approval` 或 provider 自定义但带 category/meta 标识的 `configOptions`。

客户端不再硬编码某个 provider 支持哪些模型，只负责：

1. 识别哪些 config option 适合在主输入区展示。
2. 把选中值回写给 `session/set_config_option`。
3. 接受 `config_option_update` / `current_mode_update` 并刷新 UI。

### 5.3 model 不再是特殊协议操作

新的 runtime 抽象中不再保留 “model 是专有 RPC” 这个假设。

正确设计应是：

1. provider 若要选模型，需要先从远端找到对应 config option。
2. 然后用 `session/set_config_option(configId:value:)` 设置。
3. 若某 provider 没有广告 model config option，客户端就不展示 model picker。

这样 GitHub Copilot、OpenCode、Claude Adapter 都落在同一条标准链路上。

## 6. 运行时与数据模型设计

### 6.1 新的 runtime client 接口

`ACPExternalProviderRuntimeClient` 与 `ACPExternalProviderRuntimeTransportClient` 需要从“单一 model override”升级为“通用 session config 控制”。

建议替换为：

1. `ensureSession(workingDirectory:remoteSessionID:)`
2. `setSessionMode(modeID:sessionID:)`
3. `setSessionConfigOption(configID:value:sessionID:)`
4. `prompt(text:sessionID:)`
5. `cancel(sessionID:)`
6. `close()`

其中原有 `setModel(...)` 删除。所有上层 provider 一律改为通过 config option 做模型切换。

### 6.2 握手结果需要携带 session 配置快照

当前 `ACPExternalAgentSessionHandshake` 只包含：

1. `remoteSessionID`
2. `capabilities`

这对动态配置 UI 不够。因为：

1. `session/new` 返回 `configOptions` 与 `modes`。
2. `session/load` 也返回 `configOptions` 与 `modes`。

推荐新增会话配置快照对象，例如：

1. `ACPExternalAgentSessionConfigurationSnapshot`
2. 字段包含 `configOptions`、`modes`、`lastUpdatedAt`。

然后握手或 activation 结果中持有该快照，使 provider base 在 prepare/send 完成后能立即把远端配置写入 session feature store，而不是等后续 notification。

### 6.3 Session feature store 扩展

当前 `ACPExternalSessionFeatureStore` 只缓存：

1. commands
2. plan

需要新增：

1. `sessionConfigCache[(sessionID, providerID)] -> ACPExternalSessionConfigPresentation`
2. 内容包括：
   - `configOptions`
   - `modes`
   - 当前 mode
   - 推荐展示顺序

这使得 UI 在以下场景都能拿到同一份数据：

1. 新建远端会话后首次进入
2. session/load 恢复后
3. 远端发来 `config_option_update`
4. 远端发来 `current_mode_update`

### 6.4 Session 持久化偏好保留边界

现有 `SessionExecutionPreferences` 不应整体删除，但需要缩小职责。

保留项：

1. built-in agent 的本地 model / approval 偏好。
2. external ACP provider 的“创建会话前默认值”或“用户最近一次显式选择的本地回显值”，如果后续仍需要。

不再作为 truth source 的项：

1. external ACP provider 的可选模型列表。
2. external ACP provider 的当前 mode。
3. external ACP provider 的当前 approvals 配置状态。

这些值都应以后端 session 广告为准。

## 7. UI 交互设计

### 7.1 新建会话交互

当前入口有三处：

1. `SessionListView` 右上角 `+`
2. `ChatView+Toolbar` 里的 `+`
3. `WorkbenchConversationPane` 的新建入口

这三处应统一为同一种“带执行器选择的新建会话交互”。

推荐交互：

1. 点击 `+` 后弹出简洁菜单或下拉 Picker。
2. 菜单项直接展示各执行器名称与可用性状态。
3. 选择某项后立即创建 session，并把对应 `defaultExecutionProviderID` 写入 session。

不推荐额外多一步 modal 表单，因为本次只需选择执行器，不值得引入更重的建会话流程。

### 7.2 会话内顶部配置区

当前输入区第一行包含：

1. provider picker
2. model picker
3. approval picker

重构后应变为：

1. 只读 provider badge，显示当前执行器名称，不可切换。
2. 若当前 provider 是 built-in agent，保留现有本地 model / approvals picker。
3. 若当前 provider 是 external ACP：
   - 若存在 `modes`，显示 mode picker。
   - 若存在 category 为 `model` 的 config option，显示 model picker。
   - 若存在 approvals 相关 config option，显示 approvals picker。
   - 其他 config options 首期不在主输入区展示。

### 7.3 控件展示策略

对 external ACP provider，主输入区只展示高频核心项：

1. `mode`
2. `model`
3. `approvals`

其余 config options：

1. 首期忽略，不展示。
2. 后续可扩展到更多会话设置面板。

这样能避免把输入区变成通用配置面板。

### 7.4 加载与降级态

当会话刚进入、远端尚未完成 warmup / load / new 时：

1. provider badge 正常显示。
2. mode / model / approvals 位置显示 skeleton 或“读取中”。
3. 若当前 provider 未广告某项，则该控件不出现，而不是显示禁用空 picker。

## 8. ACP 通信与状态流

### 8.1 session/new / session/load 阶段

`ACPExternalAgentRuntimeClient` 在以下两个路径都要提取配置快照：

1. `createSession(...)` 从 `ACPNewSessionResponse` 读取 `configOptions`、`modes`。
2. `loadSessionIfPossible(...)` / `restoreSessionIfPossible(...)` 从 `ACPLoadSessionResponse` 读取 `configOptions`、`modes`。

然后：

1. 更新本地 activation 内存态。
2. 写入 `ACPExternalSessionFeatureStore`。
3. 触发 UI 刷新。

### 8.2 用户切换 mode

用户在 mode picker 选择新值时：

1. ChatView action 调用 provider runtime 的 `setSessionMode(modeID:sessionID:)`。
2. runtime 发送 `session/set_mode`。
3. 成功后等待远端 `current_mode_update` 或直接使用 response + 本地 optimistic update 同步 UI。

推荐策略：

1. 允许 optimistic update。
2. 以远端后续 update 作为最终真相覆盖。

### 8.3 用户切换 model / approvals

用户在 config picker 选择新值时：

1. UI 找到对应 `configId`。
2. 调用 `setSessionConfigOption(configID:value:sessionID:)`。
3. runtime 发送 `session/set_config_option`。
4. 使用 response 中返回的 `configOptions` 直接刷新 feature store。
5. 若之后收到 `config_option_update`，再以远端事件覆盖。

这样 response path 和 notification path 都能收敛到同一数据源。

## 9. 配置项识别策略

### 9.1 首期识别规则

由于不同 provider 对 config option 的命名可能不完全一致，首期建议采用“category 优先，meta / type / id 次之”的分层识别：

1. 若 `category == model`，视为模型选择项。
2. 若 `category` 指向 approval 相关枚举，视为 approvals 项。
3. 若无法从 category 判断，则读取 `_meta` 中的展示 hint。
4. 若仍无法判断，则不在主输入区展示。

mode 不需要猜测，直接来自 `modes`。

### 9.2 为什么不按 option label 猜测

不推荐用标题字符串猜测 `model` / `approval`，因为：

1. 文案可能本地化。
2. 不同 provider 用词可能不同。
3. 这会把协议问题重新变成 fragile UI heuristics。

因此首期必须以 schema 字段和 meta 为主，而不是标题匹配。

## 10. 对现有 provider 子类的影响

### 10.1 GitHub Copilot

需要移除：

1. `_github_copilot/session/set_model` 相关 descriptor 与 fallback 假设。
2. `supportsSessionModelOverrideByDefault` 这类围绕旧扩展方法的默认判断。

需要新增：

1. 使用 `configOptions` 找到模型配置项。
2. approvals 也优先走远端配置项，而不是只映射本地 `defaultApprovalMode`。

### 10.2 OpenCode / Claude Adapter

这两个 provider 当前虽然也走 `_opencode/session/set_model` / `_claude_adapter/session/set_model`，但从协议一致性出发，同样应并入 `session/set_config_option`。

是否保留扩展方法兼容层可作为实现时决策，但设计上不再把它作为主链。

## 11. 错误处理与回退策略

### 11.1 config option 缺失

如果 UI 需要展示 model / approvals，但远端没有返回匹配 config option：

1. 不显示对应 picker。
2. 不做本地伪造。
3. 记录调试日志，帮助判断 provider 广告是否缺失。

### 11.2 set_config_option 失败

如果远端返回错误：

1. UI 回滚到上一个已知值。
2. 展示简洁错误消息。
3. 不修改 session 本地持久化 truth。

### 11.3 session/load 恢复后配置为空

若 `session/load` 返回空配置，但后续 update 能补齐：

1. UI 先显示加载态。
2. 等待首批 `config_option_update` / `current_mode_update`。
3. 不提前显示本地硬编码默认项。

## 12. 测试设计

需要补以下测试面：

1. `ACPExternalAgentRuntimeClient`：`session/new` / `session/load` 能提取 `configOptions` 和 `modes`。
2. `ACPExternalAgentRuntimeClient`：`setSessionConfigOption` 发送标准 ACP 请求而不是 extension request。
3. `ACPExternalAgentRuntimeClient`：`setSessionMode` 发送 `session/set_mode`。
4. `ACPExternalSessionFeatureExtractor`：识别 `config_option_update` 与 `current_mode_update`。
5. `ACPExternalSessionFeatureStore`：缓存和读取 session 级配置快照。
6. provider tests：发送前 warmup / restore 后能拿到远端模型列表。
7. `ChatView`：external ACP provider 不再显示 provider picker，而显示只读 badge。
8. `SessionListView` / `ChatView+Toolbar`：新建会话会先选择执行器，并把 provider 正确写入 session。
9. UI tests：进入会话后无法切换 provider，但可以切换 mode / model / approvals。

## 13. 实施顺序建议

建议按以下顺序实施：

1. 先重构 runtime contracts，补齐 `setSessionMode` / `setSessionConfigOption`。
2. 再让 `session/new` / `session/load` 把 `configOptions` / `modes` 带回 activation 与 feature store。
3. 再改 feature extractor/store，打通 update path。
4. 再重构 ChatView 输入区，把 external ACP 控件切到动态渲染。
5. 最后改新建会话入口，移除会话内 provider 切换。

这个顺序能保证数据层先稳定，避免 UI 先改完却没有真实远端数据源。

## 14. 残留问题与待确认项

当前仍有两项实现前需要在代码层确认，但不影响本设计结论：

1. ACP schema 中 approvals 对应的 `category` 与 `_meta` 在各 provider 上是否足够稳定，是否需要一层 provider adapter 映射。
2. external ACP provider 的全局默认 `defaultModel` / `defaultApprovalMode` 在新设计下是继续作为建会话前默认值，还是仅作为 provider settings 的启动偏好。

这两项属于实现细节与 provider 兼容层问题，不改变本设计的主方向。

## 15. 最终设计结论

本次重构应明确建立以下产品与架构边界：

1. `执行器` 是会话身份，创建时选择，进入会话后锁定。
2. `mode / model / approvals` 是会话运行态配置，进入会话后可改。
3. external ACP 的这些运行态配置全部来自远端 `modes` 与 `configOptions`，客户端不再写死模型列表。
4. 协议交互统一使用 `session/set_mode` 与 `session/set_config_option`，不再把模型切换设计成 provider-specific extension RPC。

如果按这个方向实施，当前 GitHub Copilot 的协议错误、mode 缺失、以及写死模型列表这三个问题会在同一轮重构中一次性被正确解决，而不是继续以局部补丁方式积累债务。