# 2026-03-23 ACP Runtime 会话调度重构设计

日期：2026-03-23

目标：彻底替换当前外部 ACP provider 的 runtime 会话调度与状态管理，消除 Copilot 与 OpenCode 跨 provider、跨会话切换时的初始化污染、会话恢复错乱与生命周期耦合问题，建立模块化、可扩展、可验证的新调度层。

关联对象：

1. `ACPExternalExecutionProviderBase`
2. `ACPExternalAgentRuntimeClient`
3. `ACPExternalProviderContracts`
4. `ACPExternalSessionBindingStore`
5. `ACPExternalSessionTurnRouter`
6. `ACPExternalUpdateProjector`
7. `GitHubCopilotCLIExecutionProvider`
8. `OpenCodeCLIExecutionProvider`
9. change review / permission / feature projection 相关调用链

关联文档：

1. `docs/plans/2026-03-20-github-copilot-cli-integration-implementation-plan.md`
2. `docs/plans/2026-03-20-opencode-acp-integration-implementation-plan.md`
3. `docs/plans/2026-03-21-acp-session-load-replay-fix.md`
4. `docs/plans/2026-03-22-external-acp-provider-abstraction-implementation-plan.md`

---

## 1. 结论先行

当前问题不是单点的 initialize 参数串线，也不是某个 provider 特有的 CLI bug，而是现有外部 ACP 会话管理从根上缺少单一事实源。

具体表现为：

1. runtime identity 被拆散在 provider base 字典、runtime client 内部握手状态、内存 bridge、SwiftData binding store 和远端 ACP 进程多个层次。
2. session activation、restore、live turn、feature extraction、projector flush、cancel、teardown 分别由不同对象管理，没有统一状态机。
3. provider base 既是 provider facade，又是 runtime supervisor，又是 session router，又是 projection coordinator，职责过载。
4. 现有实现实际上隐含了“一个 runtime 只附着一个远端 session”和“每个 provider 同时只保留一个活跃 runtime”的约束，但这些约束没有被上升为正式调度模型。

这也是为什么：

1. 同一个 provider 在不同本地会话之间切换看起来大体可用。
2. 两个不同 provider 的会话来回切换时，却会出现 initialize 卡死、attach 失败、binding 污染、restore replay 错投影等异常。

推荐方案是放弃当前“provider base 内部若干字典 + bridge + binding store + runtime client 局部缓存”的混合模式，改为新的三层模型：

1. `ACPProviderRuntimeSupervisor`：provider 级监督器，只负责 provider 域内 activation 生命周期与资源预算。
2. `ACPSessionRuntimeRegistry`：以 `(providerID, localSessionID)` 为键的 session activation 注册表，是本地事实源。
3. `ACPSessionRuntimeActor`：单 session 单写者执行体，独占管理 restore、prompt、cancel、projection、binding、teardown。

本质上，这是把“让 provider base 临时拼接 runtime/session 状态”改为“每个 provider-session identity 拥有一个正式 activation”。

## 2. 问题定义

### 2.1 用户可见故障

当前已观测到的故障模式包括：

1. 会话 A 选择 Copilot，会话 B 选择 OpenCode，来回切换后其中一方无法再次 initialize。
2. session/load 恢复后 replay 的历史 update 会污染当前 live turn 投影。
3. 同一 provider 的旧 runtime 被关闭后，残留的 remote session、feature store、pending update task、session context 仍可能影响下一次激活。
4. provider 激活切换、工作目录切换、cancel 和 teardown 的边界不一致，导致某些状态被重置，另一些状态残留。

### 2.2 根因诊断

对当前实现的代码审查后，可以把根因归纳为五类。

#### A. 缺少统一 identity 模型

当前至少存在五种“谁代表当前会话”的来源：

1. `runtimeClients[localSessionID]`
2. `remoteSessionIDs[localSessionID]`
3. `sessionContexts[localSessionID]`
4. `ACPExternalSessionBindingStore` 中的 `(localSessionID, providerID) -> remoteSessionID`
5. `ACPExternalAgentRuntimeClient.attachedSessionHandshake`

这五处状态没有一个被声明为唯一真相，因此系统只能依靠“调用顺序碰巧正确”。

#### B. 生命周期边界被拆散

当前 restore/live/cancel/close 的所有权分散在：

1. provider base
2. runtime client
3. turn router
4. update projector
5. binding store

这会导致状态迁移不是原子的。例如 runtime 已替换，但 feature store 未替换；binding 已落盘，但 session context 仍是旧值；turn router 已进入 live turn，但 pending update 仍属于 restore 阶段。

#### C. 共享基础设施带来跨 provider 污染

仓库已有经验已经证明，外部 ACP provider 不能共享 session-only cache。当前代码虽然在持久化主键层面区分了 provider，但仍有多处 session 相关缓存和准备逻辑运行在 provider base 的共享流程里，容易在切换时相互污染。

#### D. 当前实现是隐式监督，而不是显式监督

`closeInactiveSessionRuntimes`、`deactivateAllSessionRuntimes`、`resetRuntime` 都在做类似监督器的工作，但没有：

1. 统一 child identity
2. 明确重启策略
3. 清晰的失败域
4. 标准化 shutdown 顺序

因此当前代码更像若干手写的清理分支，而不是正式的 runtime supervisor。

#### E. provider base 承担过多职责

当前 base class 同时承担：

1. runtime 创建与替换
2. 会话绑定恢复与落盘
3. send/prompt/cancel
4. turn routing
5. feature extraction
6. update projection
7. change review / permission 注入

这使得任何一个会话调度修复都必须穿过整个对象，导致耦合继续扩大。

## 3. 设计目标与非目标

### 3.1 设计目标

1. 对每个 `(providerID, localSessionID)` 建立单一 activation 事实源。
2. 消除跨 provider 的 session-only 缓存污染。
3. 把 restore、prompt、cancel、teardown 收敛到单个 session runtime 状态机。
4. 把 provider 级资源管理与 session 级执行管理解耦。
5. 保留 Copilot 与 OpenCode 的 provider-specific 差异，但不再复制会话调度逻辑。
6. 为未来增加更多 ACP provider 留出稳定扩展点。
7. 让调度层天然支持测试，尤其是 initialize timeout、restore fallback、跨 provider 切换和 replay 抑制。

### 3.2 非目标

1. 不考虑 bridge 兼容与迁移策略。
2. 不保留当前会话管理的历史兼容层。
3. 不在本轮设计中重构 UI 呈现层。
4. 不在本轮设计中重做外部 ACP 协议本身。
5. 不引入完整 event sourcing 系统。

这里的核心约束是：

新设计可以直接替换旧调度层，旧桥接和临时兼容逻辑允许被删除，而不是被包装一层继续保留。

## 4. 外部设计依据

本设计不是凭直觉拼装，而是借鉴三类成熟模式。

### 4.1 LSP 生命周期规范

Language Server Protocol 的价值不在于它和 ACP 完全相同，而在于它清晰定义了 client-runtime 之间的生命周期：

1. `initialize` 先于业务请求。
2. capability negotiation 发生在初始化阶段，而不是散落在后续请求中。
3. `shutdown` 与 `exit` 是显式、顺序化的关闭流程。
4. progress 与 cancel 是正式协议面的一部分。

对 ACP 调度层的直接启发是：

1. initialize 必须成为 activation 状态机中的正式阶段。
2. capability snapshot 只能归属于某个 activation，不能挂在全局共享缓存上。
3. shutdown 不能只是“从几个字典里删值”，而应是正式状态迁移。

### 4.2 Erlang/OTP Supervision Principles

OTP 提供了成熟的监督树思想：

1. child identity 要稳定。
2. restart strategy 要显式。
3. 失败域要隔离。
4. shutdown 顺序要标准化。
5. 监督器本身不做业务，只做生命周期管理。

对本设计的直接启发是：

1. provider 级对象应是 supervisor，而不是业务执行器。
2. session activation 应作为独立 child 被监督。
3. initialize timeout、load timeout、runtime crash 应只影响当前 activation，而不污染兄弟 activation。
4. close 顺序必须先停止输入，再 drain/丢弃更新，再释放 runtime，再清理 binding 缓存引用。

### 4.3 Orleans Virtual Actor 模型

Orleans 的关键思想是：

1. 逻辑 identity 与物理 activation 分离。
2. 某个 identity 在任意时刻只应有一个有效 activation 处理其状态。
3. entity 之间不共享内存状态。
4. runtime 负责 activation 生命周期，业务对象负责该 identity 的状态与行为。

对 ACP 调度层的直接启发是：

1. `(providerID, localSessionID)` 是逻辑 identity。
2. `ACPSessionRuntimeActor` 是该 identity 的唯一 activation。
3. activation 内部单写者串行处理 restore/prompt/cancel/update。
4. provider 之间不共享任何 session-only activation 状态。

## 5. 方案备选

### 5.1 方案 A：在现有 base class 上继续分拆字典

做法：继续保留 `ACPExternalExecutionProviderBase`，但把各种 map 和 helper 再拆成几个 manager。

优点：

1. 变更表面较小。
2. 对现有 provider 子类影响最少。

缺点：

1. 单一事实源问题不会消失。
2. base class 仍会继续成为上帝对象。
3. activation 与 session identity 仍然是隐式的。
4. 很容易变成“换了一组对象名的同一套复杂度”。

结论：不推荐。

### 5.2 方案 B：每个 provider 一个全局 runtime pool，session 只保存 binding

做法：把 session 状态尽量压到持久化 binding，provider 只维护少量共享 runtime，切换时按需 attach。

优点：

1. runtime 数量可能更少。
2. 对资源占用有吸引力。

缺点：

1. 与当前 `ACPExternalAgentRuntimeClient` 的“一 runtime 一 remote session”事实冲突。
2. attach/detach 顺序复杂，容易再次引入跨 session 污染。
3. 不利于 restore replay 与 live turn 的隔离。

结论：不推荐。

### 5.3 方案 C：provider supervisor + session activation registry + session actor

做法：把 provider 级监督和 session 级执行彻底分层，每个 `(providerID, localSessionID)` 对应一个正式 activation，由 actor 独占其生命周期与状态。

优点：

1. identity 清晰。
2. 单写者模型适合处理 update、restore 和 cancel。
3. 失败域天然隔离。
4. 非常符合当前 runtime client 的真实约束。
5. provider-specific 差异可收敛在 runtime factory 和 capability policy。

缺点：

1. 替换范围大。
2. 需要删除旧 bridge-style 思维与若干缓存层。

结论：推荐。

## 6. 推荐架构

### 6.1 分层概览

新的外部 ACP 调度层分为四层。

#### 第一层：Provider Facade

保留 `GitHubCopilotCLIExecutionProvider` 和 `OpenCodeCLIExecutionProvider` 作为外部入口，但它们只负责：

1. 解析 provider 配置。
2. 提供 provider-specific capability policy。
3. 把请求委托给 supervisor。

它们不再保存 session runtime map，也不再直接处理 binding restore/projector/turn router。

#### 第二层：Provider Supervisor

新增 `ACPProviderRuntimeSupervisor`，职责是：

1. 持有 provider 范围内的 `ACPSessionRuntimeRegistry`。
2. 统一创建、查找、暂停、关闭 session activation。
3. 处理 provider 激活/失活时的资源策略。
4. 负责 provider 级日志、诊断和重启预算。

它不直接消费 ACP update，也不直接做 feature projection。

#### 第三层：Session Runtime Actor

新增 `ACPSessionRuntimeActor`，它是核心执行体，独占：

1. runtime client
2. capability snapshot
3. local <-> remote binding
4. turn phase
5. update routing
6. feature store
7. projector
8. active request / cancel token

所有与这个 session activation 相关的可变状态都必须只存在于这里。

#### 第四层：Durable Stores

持久化层只保留 durable 信息：

1. `ACPExternalSessionBindingStore` 保存 durable binding。
2. 业务消息与 tool output 继续走现有消息持久化链路。

持久化层不应承担 live activation cache 的角色。

### 6.2 关键 identity

新设计定义三个不同层次的标识。

1. `SessionRuntimeKey = (providerID, localSessionID)`
2. `RuntimeActivationID`：当前激活实例 ID，每次重建 runtime 时递增或重置
3. `RemoteSessionBinding`：durable 的远端 session 元数据

规则：

1. 注册表只以 `SessionRuntimeKey` 索引 activation。
2. 任何 capability snapshot、turn phase、projector、pending update 都属于某个 `RuntimeActivationID`。
3. remote session ID 只能由 session actor 持有与更新，并异步持久化到 binding store。

### 6.3 核心状态机

每个 `ACPSessionRuntimeActor` 维护正式状态机：

1. `idle`
2. `startingRuntime`
3. `initializing`
4. `restoring`
5. `ready`
6. `sendingTurn`
7. `cancelling`
8. `closing`
9. `closed`

关键规则：

1. `initialize` 只能从 `startingRuntime` 进入 `initializing`。
2. `session/load` 只能发生在 `initializing` 之后。
3. restore replay 期间 update 允许被内部消费，但不能进入 live projection。
4. `prompt` 只能从 `ready` 进入 `sendingTurn`。
5. `cancel` 只能作用于当前 activation 的 active request。
6. 任何 timeout 或 crash 都只使当前 activation 转入 `closing -> closed`，随后由 supervisor 决定是否重建。

### 6.4 restore 与 live turn 的统一路由

`ACPExternalSessionTurnRouter` 当前方向是对的，但层级放错了。新设计中它不再是 provider base 的辅助对象，而是 session actor 内部状态机的一部分。

这意味着：

1. restore replay 抑制不是一个外围特判，而是 activation phase 的正式语义。
2. feature extraction、tool event、assistant delta、thinking delta 都必须先按 phase 路由，再决定是否投影。
3. 所有 pending update task 必须附着到 `RuntimeActivationID`，activation 关闭时整体取消或丢弃。

## 7. 模块拆分

### 7.1 新增模块

建议新增以下抽象。

1. `ACPProviderRuntimeSupervisor`
2. `ACPSessionRuntimeRegistry`
3. `ACPSessionRuntimeActor`
4. `ACPSessionRuntimeStateMachine`
5. `ACPSessionUpdateRouter`
6. `ACPRuntimeLifecyclePolicy`
7. `ACPProviderCapabilityPolicy`

职责说明：

1. `ACPProviderRuntimeSupervisor` 只做监督与资源策略。
2. `ACPSessionRuntimeRegistry` 只负责 activation 查找与引用计数式保活策略。
3. `ACPSessionRuntimeActor` 只负责一个 session activation 的行为。
4. `ACPSessionRuntimeStateMachine` 定义显式状态迁移。
5. `ACPSessionUpdateRouter` 统一处理 restore/live/close 阶段的 update 归属。
6. `ACPRuntimeLifecyclePolicy` 定义 timeout、重建、关闭顺序。
7. `ACPProviderCapabilityPolicy` 吸收 Copilot/OpenCode 在 model override、loadSession、fallback 等差异。

### 7.2 保留但降级职责的模块

1. `ACPExternalAgentRuntimeClient` 保留为 runtime transport client，但不再拥有 session 调度语义之外的缓存权力。
2. `ACPExternalSessionBindingStore` 保留为 durable binding store。
3. `ACPExternalUpdateProjector` 保留为纯 projection helper，由 session actor 驱动。

### 7.3 应删除的冗余结构

完成替换后，以下模式应被删除或吸收：

1. `ACPExternalExecutionProviderBase` 内按 session 分散的多个 map。
2. provider base 内部的 `closeInactiveSessionRuntimes` 风格清理逻辑。
3. provider base 内部的 `deactivateAllSessionRuntimes` 风格全局 teardown 逻辑。
4. provider base 内的 `sessionContexts` 与 `remoteSessionIDs` 镜像缓存。
5. 与新 activation registry 重复表达 session 绑定关系的内存桥接代码。

删除标准很简单：

只要某个 live session 状态没有归属于 `ACPSessionRuntimeActor`，就说明设计还没有替换干净。

## 8. provider-specific 扩展点

新设计不追求“所有 provider 行为完全一致”，而是把差异限制在有限接口。

### 8.1 Copilot 与 OpenCode 的差异保留在 policy 中

例如：

1. 是否支持 `session/load`
2. model override 是否允许 fallback
3. `session/set_model` 是否依赖 capability
4. initialize 与 load 的 timeout 默认值

这些差异由 `ACPProviderCapabilityPolicy` 决定，而不是由 session actor if-else 散落处理。

### 8.2 runtime client factory 保留

provider 仍然可以注入自己的 runtime client factory，但 factory 的输出必须满足统一 contract：

1. initialize
2. prepare session
3. send prompt
4. cancel
5. shutdown

contract 不再暴露“自己记住上次 attached session”的隐式调度语义，而只暴露明确的 activation 生命周期操作。

## 9. 生命周期细节

### 9.1 激活流程

激活流程应为：

1. supervisor 通过 `SessionRuntimeKey` 查找或创建 activation。
2. actor 创建 runtime client。
3. actor 执行 initialize，固化 capability snapshot。
4. actor 读取 durable binding。
5. 若 binding 存在且 provider policy 允许，则执行 `session/load`。
6. 若 load 失败或超时，则关闭当前 runtime，按 policy 重建并回退 `session/new`。
7. 新 binding 成功后写回 store。
8. actor 进入 `ready`。

### 9.2 发送流程

发送流程应为：

1. session actor 保证当前 activation 已 `ready`。
2. actor 切换到 `sendingTurn`。
3. update router 按当前 `RuntimeActivationID` 接管所有更新。
4. projector 和 feature store 只消费本 activation、本 turn 的 live updates。
5. 结束后 flush 投影并回到 `ready`。

### 9.3 取消流程

取消流程应为：

1. actor 校验当前是否存在 active request。
2. 仅向当前 activation 的 runtime client 发送 cancel。
3. `cancelling` 期间继续接收该请求尾部更新，但不允许新 turn 开始。
4. 尾部关闭后转回 `ready`，或按错误策略进入重建。

### 9.4 关闭流程

关闭顺序应固定：

1. 停止接受新请求。
2. 标记当前 activation 为 closing。
3. 取消属于该 activation 的 update tasks。
4. flush 或丢弃未完成投影。
5. 调用 runtime shutdown。
6. 清空 actor 内 live state。
7. registry 移除 activation 引用。

## 10. 持久化边界

必须明确 durable state 与 live state 的边界。

### 10.1 durable state

只应包括：

1. `(providerID, localSessionID) -> remoteSessionID`
2. remote session 元数据，例如能力快照摘要、model 信息
3. 消息历史与工具历史

### 10.2 live state

只应包括：

1. active runtime client
2. initialize 结果中的完整 capability snapshot
3. turn phase
4. projector buffer
5. feature extraction buffer
6. pending update tasks

原则：

live state 一律不持久化，也不允许在 provider base 的外层镜像缓存。

## 11. 测试策略

新设计必须先有测试面，再有替换面。

### 11.1 单元测试

1. `SessionRuntimeKey` 只产生一个 activation。
2. initialize timeout 只重建当前 activation，不影响其他 session activation。
3. restore replay 不进入 live projector。
4. load 失败后回退 new session，并覆盖 durable binding。
5. cancel 只影响当前 activation 的 active turn。
6. provider 失活不会污染其他 provider 的 activation 状态。

### 11.2 集成测试

1. 会话 A 使用 Copilot，会话 B 使用 OpenCode，反复切换后双方都能正常恢复发送。
2. 同 provider 多会话切换时，旧 binding 可恢复，但旧 activation 不残留 live updates。
3. change review 场景下工作目录切换触发 activation 重建后，远端会话与消息投影仍一致。
4. restore replay、tool call、thinking delta、assistant delta 在 UI 上不重复、不穿插。

### 11.3 回归测试

当前已有的 provider tests 需要重写为新模型下的行为测试，不再断言“provider base 内某个 map 被清空”，而是断言：

1. registry 行为
2. actor 状态迁移
3. supervisor 重建策略
4. durable binding 语义

## 12. 替换计划纲要

虽然本文件重点是设计而不是实施细节，但替换顺序需要明确，否则容易再次变成半替换。

建议顺序：

1. 先引入 `SessionRuntimeKey`、registry、session actor、supervisor。
2. 把 Copilot 和 OpenCode provider 接到 supervisor，但暂时保留旧 runtime client transport。
3. 把 restore/live routing 下沉到 session actor。
4. 把 binding store 和 projector 改为只由 session actor 驱动。
5. 删除 provider base 的 session maps 与清理分支。
6. 最后收缩或移除 `ACPExternalExecutionProviderBase`，保留仅对 provider facade 真正有价值的公共逻辑。

重要原则：

替换必须是架构替换，不接受“旧字典继续保留，只是新增一层 supervisor 包起来”的折中方案。

## 13. 风险与权衡

### 13.1 主要风险

1. 替换范围较大，短期内需要重写相当一部分测试。
2. change review、permission、feature projection 这些支线此前隐式依赖 base class 内部状态，替换时需要显式重新接线。
3. 若实施时仍保留桥接式临时状态，容易把旧问题带入新层次。

### 13.2 为什么仍值得做

因为当前问题已经不是局部 bug，而是调度层建模错误。继续补丁式修复，会不断在以下几组矛盾之间来回打架：

1. session/load 与 session/new
2. provider 切换与 runtime warmup
3. restore replay 与 live projection
4. binding durable state 与 live runtime state

只有把这些边界提升为正式 architecture，问题才会从“容易复发”变成“结构上不容易写错”。

## 14. 最终建议

最终建议如下：

1. 采用方案 C，建立 provider supervisor + session activation registry + session actor 的新调度层。
2. 明确把 `(providerID, localSessionID)` 定义为唯一逻辑 identity。
3. 所有 live session 状态统一收敛到 `ACPSessionRuntimeActor`。
4. 把 `ACPExternalExecutionProviderBase` 从会话调度中心降级，最终移除其冗余状态管理职责。
5. 不做 bridge 兼容，不保留双轨会话管理。

这份设计直接回应了当前故障的真实根因：

不是 initialize 参数偶发串了，而是整个 ACP 外部 provider 会话调度缺少正式的 activation 模型与单一事实源。

只有把 runtime 会话调度重构为显式 supervisor + actor activation 架构，Copilot 与 OpenCode 的跨 provider 切换问题才会被根治，而不是被延后。