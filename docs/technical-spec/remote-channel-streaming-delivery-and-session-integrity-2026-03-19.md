# Remote Channel 流式投递与会话绑定治理技术方案

> 状态：草案  
> 日期：2026-03-19

---

## 1. 背景与结论

当前 Remote Channel 的执行链路，仍然是“先完整跑完 agent loop，再一次性把最终文本发给渠道”。这直接导致两个问题：

1. Channel 侧首包延迟完全等于整轮 loop 完成时间，用户几乎看不到实时反馈。
2. Channel 会话删除后，`RemoteConversationBinding` 等资源不会随 `Session` 清理，后续相同远端会话会不断生成新的本地 session。

本方案的结论是：

1. 不应继续把 Remote Channel 当作“最终结果落盘后顺手发一条消息”的尾处理器，而应把它提升为 loop 运行时的一个独立投影目标。
2. 不应把增量投递逻辑塞进现有 `IMChannelAdapter.send` 单接口里，而应引入“会话级投递运行时 + 渠道驱动”的分层结构。
3. Session 删除问题不能只在 router 上打补丁，必须同时补齐数据模型关系、删除路径清理、运行时自愈和完整性检查。

推荐方案：

1. 在 agent loop 侧引入统一的增量投递事件面。
2. 在 Remote Channel 侧引入 `RemoteTurnDeliveryCoordinator` 与 `ChannelProjectionSession`。
3. 在持久化层新增投影绑定与投递审计模型，并把 `RemoteConversationBinding` 改成真实关系模型。
4. Feishu 首期支持两种策略：
   - 非卡片：增量追加发送。
   - 卡片：首次发送卡片，后续对同一 `message_id` 做卡片更新。

---

## 2. 现状 Review

### 2.1 当前 inbound 到 outbound 的实际链路

基于代码现状，当前 Remote Channel 的主链路如下：

1. `ChannelRuntimeBootstrap.startEnabledChannels` 为启用的渠道注册 `inboundMessageHandler`。
2. `FeishuChannelAdapter.start` 从长连接事件中归一化出 `InboundChannelMessage`，交给 `configuration.inboundMessageHandler`。
3. `ChannelEventDeduplicator.acceptInbound` 仅按 inbound `externalMessageID` 去重，并写入一条 `RemoteMessageReceipt(direction: .inbound)`。
4. `RemoteAgentOrchestrator.handleInbound`：
   - 调 `RemoteConversationRouter.resolveSession` 找或建本地 `Session`。
   - 立即落一条用户消息。
   - 调 `executor.execute(...)` 执行远端 turn。
   - 等 `execute` 返回完整文本后，才创建 agent/system 消息并调用 `OutboundDeliveryCoordinator.deliver`。
5. `OutboundDeliveryCoordinator.deliver` 只会调用 `IMChannelAdapter.send(_:)` 一次，并记录一条 outbound receipt。

这条链路说明，当前 outbound 是典型的“final-only delivery”。

### 2.2 loop 侧其实已经有流式事件，但 Remote Channel 没接上

`AgentLoopRoundExecutor.executeStreamingRound` 在模型流式返回期间已经持续发出：

1. `didReceiveTextDelta`
2. `didReceiveThinkingDelta`
3. `didResolveStopReason`

而 `StreamProjectionHook` 已经把这些事件投影到：

1. 本地 UI `Message`
2. workflow action 简报

但 `ClaudeService.executeRemoteTurn` 当前把 `streamProjectionTarget` 设为 `.none`，所以 Remote Channel 完全绕过了这组增量事件。

换句话说，问题不是 loop 没流式能力，而是 Remote Channel 没有接入 loop 的流式投影面。

### 2.3 现有 channel adapter API 天然是无状态尾调用

`IMChannelAdapter` 当前只有：

1. `start(configuration:)`
2. `stop()`
3. `send(_:) async throws -> String`

这个接口只适合“发一条完整消息然后返回远端 message id”。

它缺少以下能力：

1. 开启一次远端 turn 的投递会话。
2. 处理增量文本 snapshot。
3. 区分 create / append / update / finalize / fail。
4. 持有渠道自己的远端锚点状态。

因此如果继续沿用 `send(_:)` 叠补丁，最终只会把渠道状态机塞进 orchestrator 或 adapter 内部，耦合会迅速失控。

### 2.4 Session 删除后会产生孤立绑定

当前数据模型有两个明显问题：

1. `RemoteConversationBinding` 只存 `sessionID: String`，不是 `Session` 关系。
2. `RemoteMessageReceipt` 只存 `messageID: UUID?`，也是弱引用值，不具备级联删除能力。

当前删除会话的路径只是直接 `modelContext.delete(session)`。`Session` 只对 `messages` 配了级联删除，Remote Channel 相关记录不会被清理。

于是会出现：

1. `RemoteConversationBinding` 仍然指向已删除的 `sessionID`。
2. 下次相同远端会话再来消息时，router 找到 binding，但找不到 session，于是创建新 session。
3. 数据库里累积越来越多 stale bindings 和 outbound receipts。

### 2.5 当前完整性检查没有覆盖 channel 资源

`DataIntegrityChecker` 目前只覆盖：

1. broken plan JSON
2. orphan message
3. orphan tool call
4. invalid workflow state

它没有检查：

1. stale `RemoteConversationBinding`
2. duplicate conversation bindings
3. orphan `RemoteMessageReceipt`
4. 后续新增的 projection binding / delivery log

所以即使数据已经漂移，系统也没有可观测面。

---

## 3. Feishu 能力约束

根据飞书开放平台文档，当前可以确定以下约束：

### 3.1 发送与回复

1. `POST /open-apis/im/v1/messages` 可发送 text / post / interactive 等消息。
2. `POST /open-apis/im/v1/messages/:message_id/reply` 可回复指定消息。
3. 发送与回复响应都返回 `message_id`，可作为后续更新锚点。

### 3.2 文本与富文本更新

1. `PUT /open-apis/im/v1/messages/:message_id` 支持更新 text / post。
2. 一条消息最多编辑 20 次。
3. 只能编辑当前操作者自己发送的消息。
4. 受企业可编辑时间窗口限制。

### 3.3 卡片更新

1. interactive 卡片不能走文本编辑接口。
2. 需要使用“更新已发送的消息卡片”接口：`PATCH /open-apis/im/v1/messages/:message_id`。
3. 调用身份必须与发送卡片时一致。
4. 更新前后都要显式声明 `config.update_multi = true`，否则共享卡片更新不成立。
5. 仅支持更新 14 天内发送的消息。
6. 单条消息更新频控为 5 QPS。

### 3.4 频控与大小限制

1. 同一用户或群的消息发送存在 5 QPS 维度限制。
2. 文本消息最大 150 KB。
3. 卡片与富文本最大 30 KB。
4. 卡片更新期间可能出现 `card action is lock` 等竞争错误。

### 3.5 对本方案的直接影响

1. Feishu 文本“理论上能编辑”，但你已经明确要求非卡片使用追加发送，因此首期不以文本编辑为主策略。
2. 由于卡片更新必须依赖先前发送得到的 `message_id`，系统必须持久化远端投递锚点。
3. 无论文本追加还是卡片更新，都必须做节流，不能把每个 token 都直接打到飞书 API。

---

## 4. 设计目标

### 4.1 目标

1. Remote Channel 在 loop 过程中即可对外产生可见反馈。
2. Channel 如何把增量反馈投递给远端，由各渠道策略自行决定。
3. 核心 loop 不写死 Feishu 规则，保持渠道无关。
4. 远端投递具备可恢复、可追踪、可清理的持久化状态。
5. Session 删除后，不再残留影响路由结果的孤立资源。

### 4.2 非目标

1. 首期不追求所有渠道统一支持 edit / patch / append 的所有组合。
2. 首期不处理跨设备远端已读、撤回等高级同步问题。
3. 首期不把本地 UI message 模型与远端 message 模型完全统一。

---

## 5. 总体方案

### 5.1 分层原则

把当前“orchestrator 直接拿最终字符串再 send”的结构，拆成四层：

1. `AgentLoopProjectionEvent`：loop 输出的统一增量事件面。
2. `RemoteTurnDeliveryCoordinator`：一次远端 turn 的聚合、节流与容错。
3. `ChannelProjectionDriver` / `ChannelProjectionSession`：渠道自己的投递策略运行时。
4. 投影持久化模型：保存远端锚点、投递尝试和会话绑定关系。

### 5.2 建议新增抽象

#### 5.2.1 loop 到渠道的统一事件

```swift
enum AgentLoopProjectionEvent {
    case textSnapshot(
        accumulatedText: String,
        currentRoundText: String,
        roundIndex: Int,
        isForced: Bool
    )
    case thinkingSnapshot(
        accumulatedThinking: String,
        roundIndex: Int,
        isForced: Bool
    )
    case stopReason(String?)
    case toolEvent(name: String, status: ToolCallStatus)
    case completed(finalText: String)
    case failed(summary: String)
}
```

这个事件面只描述“loop 产生了什么”，不描述“渠道该怎么发”。

#### 5.2.2 渠道无关的投递运行时

```swift
protocol ChannelProjectionDriver {
    func openSession(context: ChannelProjectionContext) async throws -> any ChannelProjectionSession
}

protocol ChannelProjectionSession: AnyObject {
    func ingest(_ event: AgentLoopProjectionEvent) async throws
    func close() async
}
```

这里的关键是 `openSession` 返回的是“有状态的投递会话”，而不是单次 `send`。

#### 5.2.3 Remote turn 级 coordinator

```swift
final class RemoteTurnDeliveryCoordinator {
    func beginTurn(...) async throws -> RemoteTurnDeliveryHandle
}

protocol RemoteTurnDeliveryHandle: AnyObject {
    func receive(_ event: AgentLoopProjectionEvent) async
    func finish(finalText: String) async
    func fail(summary: String) async
}
```

它负责：

1. 接收 loop 高频 snapshot。
2. 做文本去抖与节流。
3. 只在到达投递阈值时调用 channel session。
4. 把失败降级为最终错误摘要，而不是让 loop 主链路被渠道 API 频繁打断。

### 5.3 为什么不直接扩展 `IMChannelAdapter.send`

不推荐把 `send` 改成一个巨大的 upsert 接口，原因是：

1. `send` 的调用语义是单次动作，不适合承载整轮 turn 生命周期。
2. append / update / finalize 需要持有远端 message id 和节流状态，这本质上是“会话”，不是“调用”。
3. 不同渠道的策略差异会非常大，强行压成一个静态参数对象会很快失控。

因此保留现有 `send(_:)` 作为“简单一次性发送”能力，新增 streaming delivery 面更稳妥。

---

## 6. 推荐架构落点

### 6.1 loop 层：新增 Remote Channel 投影目标

当前 `AgentLoopStreamProjectionTarget` 只有：

1. `.none`
2. `.message(Message)`
3. `.workflowAction((String) -> Void)`

推荐升级为“多投影管线”，而不是继续往 enum 上叠分支。建议新增：

```swift
struct AgentLoopProjectionPipeline {
    let sinks: [any AgentLoopProjectionSink]
}

protocol AgentLoopProjectionSink {
    func receive(_ event: AgentLoopProjectionEvent) async
}
```

这样：

1. 本地 UI message 投影是一个 sink。
2. workflow action 投影是一个 sink。
3. Remote Channel delivery 也是一个 sink。

如果本期不想大改，也可以先保守落地：

1. 保留 `StreamProjectionHook` 给本地 UI。
2. 额外新增 `RemoteChannelProjectionHook`。
3. 只在 `runtime` 里加一个 `remoteDeliveryTarget`。

从工程风险上看，这个“并行 hook + 新 target”是第一阶段最合适的折中方案。

### 6.2 orchestrator 层：从“拿最终字符串”改为“管理 turn delivery handle”

推荐把 `RemoteAgentExecuting` 改成面向 turn 生命周期的协议：

```swift
protocol RemoteAgentExecuting {
    func execute(
        message: InboundChannelMessage,
        session: Session,
        policy: RemoteExecutionPolicy,
        authorizationPolicy: ToolAuthorizationPolicy,
        modelContext: ModelContext,
        deliveryHandle: RemoteTurnDeliveryHandle?
    ) async throws -> String
}
```

执行流程改成：

1. `RemoteAgentOrchestrator` 解析 session。
2. 创建本地 user message。
3. 向 `RemoteTurnDeliveryCoordinator` 申请一个 turn handle。
4. 把 handle 传给 `executor.execute(...)`。
5. loop 流式事件源源不断送到 handle。
6. 完成时再决定是否需要补发最终消息、补落最终 agent message、写完成态。

这样 orchestrator 仍然掌握“业务一轮 turn”的边界，但不再直接处理增量投递细节。

### 6.3 channel 层：每个渠道自己实现 `ChannelProjectionSession`

各渠道只需要回答一个问题：

“收到新的 snapshot 时，我是新发、追加、更新，还是忽略？”

这正符合你的要求：远端如何展示和回复，由各渠道自己决定。

---

## 7. Feishu 首期策略设计

### 7.1 统一上下文

Feishu 渠道投递会话建议持有以下上下文：

1. `externalConversationID`
2. inbound `externalMessageID`
3. 当前消息格式 `FeishuMessageFormat`
4. 渲染器 `FeishuOutboundMessageRenderer`
5. 首条 outbound `message_id`
6. 最近一次 outbound `message_id`
7. 最近一次已投递文本 hash / 长度
8. 节流配置：最小字符增量、最小时间间隔、最大刷新频率

### 7.2 非卡片消息：追加发送

你要求非卡片不要更新原消息，而是追加发送。推荐策略如下：

1. 第一条可见输出出现后，发送第一段文本消息。
2. 后续 snapshot 达到阈值时，再追加发送新的增量段，而不是重发全文。
3. 每次发送后记录 Feishu 返回的 `message_id`。

这里建议同时记录两个锚点：

1. `replyAnchorMessageID`：本轮默认回复锚点。
2. `latestOutboundMessageID`：最近一次机器人发出的消息 ID。

为什么值得记录：

1. 渠道未来可能改成“对上一条机器人消息继续回复”，而不是一直回复用户原消息。
2. 失败补偿、人工排查、审计都需要知道本轮已经发出去哪些消息。
3. 后续若要引入文本编辑降级策略，也必须先拿到自己的 outbound `message_id`。

首期默认建议：

1. 继续以 inbound `externalMessageID` 作为 reply anchor，保证所有流式碎片都挂在同一用户消息下。
2. 但持久化保存 `latestOutboundMessageID`，为后续策略切换留接口。

### 7.3 卡片消息：单卡片持续更新

卡片策略建议如下：

1. 首次达到投递阈值时，发送一张 interactive card。
2. 记录返回的 `message_id` 为 `primaryRemoteMessageID`。
3. 后续每次 snapshot 达到刷新阈值时，重新渲染整张 card，并调用 Feishu PATCH 接口更新同一张卡片。
4. 完成时强制再 patch 一次最终状态。

原因：

1. 卡片天然适合承载“持续展开中的 agent 输出”。
2. 对用户来说是一条稳定更新的响应，而不是连续刷多条卡片。
3. Feishu 官方对 interactive card 更新已有明确支持。

### 7.4 推荐节流策略

为了避免 Feishu API 被过量调用，建议：

1. 文本追加：至少新增 80 到 160 个字符，或距离上次发送超过 1.5 到 2 秒。
2. 卡片更新：至少新增 120 到 240 个字符，或距离上次更新超过 2 秒。
3. 强制事件：round 结束、run 完成、run 失败时强制刷新一次。

也就是说，系统消费的是高频 token delta，但对飞书输出的是低频 snapshot。

### 7.5 失败与降级

Feishu session 内部建议做如下降级：

1. 若卡片 PATCH 失败但首条卡片已存在：
   - 记录 delivery failure。
   - 降级为追加一条普通文本摘要，不阻断本地 loop。
2. 若文本追加失败：
   - 允许重试有限次数。
   - 超过次数后停止远端增量发送，但本地执行继续。
3. 若最终完成态发送失败：
   - 至少保证本地 session/message 状态正确。
   - delivery failure 留给后台重试或人工检查。

Remote Channel 是投影面，不应成为 loop 主执行链路的单点故障。

---

## 8. 持久化模型设计

### 8.1 `RemoteConversationBinding` 从弱路由改为真实关系

建议改为：

1. `RemoteConversationBinding.session: Session?`
2. `Session.remoteConversationBindings: [RemoteConversationBinding]`
3. `Session` 删除时对 bindings 级联删除。

保留 `sessionID` 作为冗余字符串字段可以，但它不应再是唯一真相源。

### 8.2 新增 `SessionProjectionBinding`

建议新增一张“逻辑投影绑定”表，而不是把所有状态挤进 receipt：

```swift
@Model
final class SessionProjectionBinding {
    var id: UUID
    var session: Session?
    var sourceMessageID: UUID?
    var channelKind: IMChannelKind
    var externalConversationID: String
    var projectionKey: String
    var strategy: String
    var primaryRemoteMessageID: String?
    var latestRemoteMessageID: String?
    var state: String
    var createdAt: Date
    var updatedAt: Date
}
```

用途：

1. 标识“一次 turn 在某渠道上的远端投影实例”。
2. 保存 card update 需要的主 `message_id`。
3. 保存 text append 的最近一次 outbound `message_id`。
4. 为会话删除、失败补偿、恢复重试提供锚点。

### 8.3 新增 `ChannelProjectionDelivery`

建议再保留一张 append-only 投递日志：

```swift
@Model
final class ChannelProjectionDelivery {
    var id: UUID
    var projectionBinding: SessionProjectionBinding?
    var operation: String   // create / append / update / finalize / fail
    var remoteMessageID: String?
    var payloadDigest: String
    var status: String
    var errorSummary: String?
    var createdAt: Date
}
```

用途：

1. 审计远端到底发过什么。
2. 支撑重试与排障。
3. 避免把“最后一次状态”覆盖掉历史。

### 8.4 `RemoteMessageReceipt` 的定位收敛

引入上述两张表后，`RemoteMessageReceipt` 建议收敛为：

1. inbound/outbound 外部 message id 的轻量收据。
2. 去重与历史检索辅助信息。

而不再承担：

1. 流式投递状态机。
2. 投影生命周期状态。
3. 多次更新链路的唯一锚点。

---

## 9. Session 删除与自愈治理

### 9.1 删除路径必须显式治理 channel 资源

推荐新增 `SessionDeletionCoordinator`，统一负责删除：

1. `Session`
2. `RemoteConversationBinding`
3. `SessionProjectionBinding`
4. `ChannelProjectionDelivery`
5. 与 session 绑定的 `RemoteMessageReceipt`（至少 outbound 相关）

不要再让 UI 直接 `modelContext.delete(session)` 成为最终删除路径。

### 9.2 Router 仍需具备运行时自愈

即使补了关系和删除协调器，router 仍然应该做防御式清理：

1. 查到 binding 但 `binding.session == nil` 时，直接删掉该 stale binding。
2. 对同一 `(channelKind, externalConversationID)` 若存在多条绑定：
   - 保留最新且 session 存活的一条。
   - 其余重复项清理。
3. 清理后再决定复用还是新建 session。

理由很简单：线上数据永远可能在旧版本、异常退出、手工修库等场景下漂移，不能只依赖“理想删除路径”。

### 9.3 完整性检查补齐

`DataIntegrityChecker` 建议新增以下 issue 类型：

1. stale remote conversation binding
2. duplicate remote conversation binding
3. orphan projection binding
4. stale projection delivery
5. orphan remote message receipt

这样 channel 资源问题才真正进入可观测域。

---

## 10. 分阶段实施建议

### Phase 1：最小可用流式投递

目标：让 Remote Channel 在 loop 中产生可见输出。

建议改动：

1. 新增 `RemoteTurnDeliveryCoordinator`。
2. `RemoteAgentOrchestrator` 在执行前创建 delivery handle。
3. `RemoteAgentExecuting.execute` 接受 `deliveryHandle`。
4. loop 新增 `RemoteChannelProjectionHook` 或等价 sink。
5. Feishu 实现：
   - text/post 追加发送
   - interactive card 首发 + PATCH 更新

这一阶段先不做大规模 schema 重构，也能立刻改善用户体验。

### Phase 2：持久化与删除治理

目标：根治 stale bindings 与孤立投影资源。

建议改动：

1. `RemoteConversationBinding` 改关系模型。
2. 新增 `SessionProjectionBinding`。
3. 新增 `ChannelProjectionDelivery`。
4. 引入 `SessionDeletionCoordinator`。
5. Router 增加 stale/duplicate binding 自愈。

### Phase 3：恢复、重试与观测

目标：让远端投递从“能用”走向“可运维”。

建议改动：

1. delivery failure 重试策略。
2. 投递耗时、失败率、节流命中率指标。
3. 设置页或可靠性中心展示 channel projection 状态。

---

## 11. 测试建议

### 11.1 单元测试

1. `RemoteTurnDeliveryCoordinatorTests`
   - 高频 delta 被正确节流。
   - 完成态会强制 flush。
   - 渠道错误不会打断 loop 主链路。
2. `FeishuChannelProjectionSessionTests`
   - text 模式按阈值追加发送。
   - interactive 模式首发后走 PATCH 更新。
   - 失败时按预期降级。
3. `RemoteConversationRouterTests`
   - stale binding 自动清理。
   - duplicate binding 自动收敛。
4. `SessionDeletionCoordinatorTests`
   - 删除 session 会清理所有 channel 相关资源。

### 11.2 集成测试

1. 远端消息进入后，在 loop 尚未结束时已经产生第一条 outbound delivery。
2. 长输出在 Feishu text 模式下被拆成多次追加发送。
3. 卡片模式下只创建一条 primary message，后续都是 update。
4. 删除 session 后，相同 `externalConversationID` 再来消息时不会被 stale binding 污染。

### 11.3 回归点

1. 本地 ChatView 的流式展示不能退化。
2. workflow action 投影不能被 Remote Channel 改造破坏。
3. inbound dedupe 仍然成立。
4. 非远端 channel 的常规发送链路不受影响。

---

## 12. 风险与取舍

### 12.1 为什么不首期直接把 text 也改成“编辑同一条消息”

虽然 Feishu 文本支持编辑，但当前需求明确要求非卡片走追加发送。继续遵从这个要求有两个好处：

1. 渠道策略更一致，避免对“是否允许编辑、还能编辑几次、是否过了编辑窗口”做额外分支。
2. 追加发送更符合“渠道自行决定如何回复远端”的抽象边界。

后续若用户体验上发现文本连续多条过于打扰，再给 Feishu 单独加“文本编辑策略”即可，不影响整体架构。

### 12.2 为什么需要新增模型，而不是只在内存里记住 message id

只放内存会在以下场景全部失效：

1. App 重启
2. 长连接重连
3. 远端 turn 过程中 crash
4. 后台补偿重试

而这些场景正是 remote channel 最容易出问题的地方。

### 12.3 为什么还要保留 router 自愈，而不是全靠删除级联

因为级联只对“未来正确路径”有效，无法修复历史脏数据。Router 是最终路由入口，必须具备最后一道防线。

---

## 13. 推荐实施顺序

推荐按以下顺序推进：

1. 先做 Phase 1，把 Remote Channel 接入 loop 增量事件，立即降低响应延迟。
2. 再做 Phase 2，补齐模型关系、删除协调器和路由自愈，清理历史数据问题。
3. 最后做 Phase 3，把投递链路纳入可靠性中心与后台重试。

这是当前性价比最高、风险最可控的路径。

---

## 14. 最终建议

建议把本期改造的核心原则定成一句话：

“Remote Channel 不是最终结果的落地器，而是 agent loop 的一个可持续投影面。”

只要这个边界定清楚，后续无论接 Feishu、Slack、Discord 还是企业内部 IM，都会落在同一套结构上：

1. loop 发投影事件
2. coordinator 做节流与容错
3. channel session 决定远端呈现策略
4. persistence 记录锚点、历史与清理关系

这套结构既能解决当前飞书延迟高的问题，也能从根上解决 session 删除后的绑定漂移问题。