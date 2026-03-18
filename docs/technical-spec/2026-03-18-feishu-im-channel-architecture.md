# 2026-03-18 飞书远程会话接入技术方案

日期：2026-03-18

关联对象：`ClaudeService`、`WorkflowRuntime`、`Session`、`Message`、`agentGuiApp`、后台任务体系、后续 IM 渠道扩展

## 实施状态

截至 2026-03-18，首版链路已经在代码层完成第一轮落地：

1. 已新增 `Services/Channels` 通用层，包含渠道协议、入出站消息模型、去重、路由、远程编排和出站投递。
2. 已新增飞书适配目录，落地了 payload 模型、文本消息归一化、凭证存储边界、client 协议与 adapter 生命周期封装。
3. 已新增渠道设置页，可保存飞书启用状态、显示名和凭证，且凭证不写入普通 `AppSettings` 字段。
4. 已在 `agentGuiApp` 启动流程接入 `ChannelRuntimeBootstrap`，会为启用中的飞书 binding 自动注册并启动运行时。
5. `LiveFeishuClient` 现已接入真实 HTTP 发送接口，并新增 `FeishuLongConnectionEventSource`，支持 endpoint 获取、WebSocket 建连、protobuf `Frame` 编解码、`im.message.receive_v1` 事件接收、分包重组、ACK 回写、`card` callback 的 Base64 `data` 回包、基础 ping/pong、握手错误分类与首版自动重连。
6. 设置页现已可观测飞书渠道的运行态连接状态、最近一次错误摘要，以及最近一次握手 response header 摘要；真实 `URLSessionWebSocketTask` 链路会在 delegate 确认 `didOpen` 后才进入“已连接”。
7. 当前仍属于首轮协议实现，`handshake-status` 的协议语义已经文档化，且握手 response header 的基础运行时观测已接入，但完整线上联调验证仍未补齐，因此“主链路已实现，生产级硬化待补齐”。

## 0. 结论摘要

本次调研结论如下：

1. 如果目标是“用户在飞书里和 agent 双向聊天”，不能使用飞书群自定义机器人，必须使用**应用机器人**。
2. 飞书**支持飞书个人版用户**与机器人单聊，但前提不是“个人开发者身份直接创建个人机器人”，而是**企业自建应用**开启机器人能力与**对外共享能力**后，个人版用户作为外部用户与机器人单聊。
3. 对当前 `agentGui` 而言，最务实的第一阶段方案不是先做一套独立云服务，而是做一个**本地直连的 Feishu Channel Adapter**：
   - 通过飞书应用机器人接收消息事件。
   - 在本机触发现有 agent 执行。
   - 将执行结果回发到飞书。
4. 为了支持后续扩展到 Telegram、Slack、企业微信、Discord 等渠道，接入层必须从一开始就设计为**渠道适配器架构**，而不是把飞书逻辑写死在 `ClaudeService` 或消息 UI 中。

因此，推荐路线是：

1. 先实现 `Feishu` 渠道适配器，支持个人版用户远程单聊你的本地 agent。
2. 再抽象为统一 `IM Channel` 框架。
3. 后续按同一协议接入更多即时通讯工具。

## 1. 背景与目标

你希望实现的能力，不是简单的“从飞书推送一条通知到 agentGui”，而是：

1. 用户可以在飞书中和 agent 进行连续对话。
2. 远程消息进入后，能够映射到 `agentGui` 现有会话体系。
3. agent 在本地继续使用现有模型、工具、工作目录和记忆能力完成任务。
4. 执行结果能够回写到飞书会话。
5. 技术设计不能只适配飞书，要为更多 IM 渠道预留统一扩展面。

本方案的目标是给出一套适合 `agentGui` 当前架构的接入设计，而不是单纯罗列飞书开放平台接口。

## 2. 非目标

当前阶段不把以下内容纳入首版范围：

1. 不设计完整的多租户 SaaS 网关。
2. 不在首版中实现飞书卡片交互工作流、审批流、群管理自动化等高级能力。
3. 不在首版中支持“任何陌生人都能直接发消息调用本地 agent”。
4. 不在首版中把所有 IM 渠道一次性接入。

首版重点是把“飞书远程聊天 -> 本地 agent 执行 -> 回写飞书”这条主链路做通，并保证架构可扩展。

## 3. 飞书平台调研结论

### 3.1 机器人类型结论

飞书机器人分为两类：

1. **应用机器人**：支持接收消息事件、向用户单聊发消息、响应群内 `@机器人` 消息、调用消息接口。
2. **自定义机器人**：只能通过 webhook 向所在群单向推送消息，不能接收并响应用户消息，也不能与用户单聊。

因此，本项目如果要做“聊天对话”，必须选择**应用机器人**。

### 3.2 个人用户可行性结论

飞书官方文档明确说明：

1. 开启**对外共享能力**的应用机器人，支持与外部用户单聊。
2. “外部用户单聊是否支持飞书个人版”这一问题的官方答案是：**支持**。

但需要注意边界：

1. 这里的“支持个人版用户”是指个人版用户作为**外部用户**接入一个**企业自建应用机器人**。
2. 不是说你可以仅靠个人版账号、没有企业自建应用，就直接开发一个完整可对话的机器人。
3. 开启对外共享能力还要求企业侧满足飞书认证条件，并通过应用发布流程。

### 3.3 消息接收与发送能力

实现双向对话至少需要这些飞书能力：

1. `im.message.receive_v1` 事件，用于接收用户发给机器人的消息。
2. `im:message.p2p_msg:readonly`，读取用户发给机器人的单聊消息。
3. `im:message.group_at_msg:readonly`，接收群聊中 `@机器人` 的消息。
4. `im:message:send_as_bot` 或 `im:message`，以机器人身份回发消息。

如果后续需要支持外部群、外部用户单聊，还需要：

1. 应用开启机器人能力。
2. 应用开启对外共享能力。
3. 用户在首次单聊时完成飞书客户端确认，进入机器人的可用范围。

### 3.4 对当前项目最重要的现实约束

对 `agentGui` 来说，真正关键的不是“飞书能不能发消息”，而是“飞书事件如何可靠到达本地正在运行的 macOS 应用”。

这个问题有两条路径：

1. **长连接模式**：本地应用主动与飞书建立事件长连接，不需要公网回调地址，适合 MVP。
2. **Webhook 网关模式**：飞书把事件推送到开发者服务器，再由服务器转发给本地 agent 或云端 agent，适合长期稳定运行。

对于你当前“想远程和自己的 agent 聊天”的目标，推荐先走**长连接模式**，因为它最符合本地 agent 的执行场景。

## 4. 设计原则

本方案遵守以下原则：

1. **渠道解耦**：飞书只是一个渠道，不应侵入 `ClaudeService` 的核心对话逻辑。
2. **会话复用**：远程 IM 会话应复用现有 `Session` / `Message` 体系，而不是另造一套聊天模型。
3. **统一消息模型**：所有外部渠道消息都先归一化，再进入 agent 运行时。
4. **可靠投递**：入站事件需要去重、幂等、可重试；出站消息需要状态跟踪。
5. **渐进部署**：先支持单用户远程聊天，再扩展常驻服务、多渠道和企业级能力。
6. **权限隔离**：远程触发的 agent 会话不能默认获得无限制工具权限，需要显式策略约束。

## 5. 推荐总体架构

### 5.1 总体方案

推荐新增一层 `IM Channel Runtime`，位于渠道接入与现有 agent 运行时之间。

职责拆分如下：

1. **Channel Adapter**：负责和飞书、Telegram、Slack 等外部平台交互。
2. **Inbound Normalizer**：把平台事件归一化为统一入站消息模型。
3. **Conversation Router**：将外部会话映射到本地 `Session`。
4. **Remote Agent Orchestrator**：触发现有 agent 执行流程。
5. **Outbound Delivery Coordinator**：把本地输出投递回外部平台。
6. **Receipt / Dedup Store**：记录事件去重、投递状态和外部消息 ID。

现有 `ClaudeService`、`WorkflowRuntime`、`runCoreAgentLoop(...)` 不直接感知飞书。它们只处理“某个本地会话里来了一条用户消息，需要继续执行”这件事。

### 5.2 为什么不把飞书逻辑写进 ClaudeService

如果把飞书 API 调用、事件验签、聊天映射、外部消息状态直接写进 `ClaudeService`，会产生三个问题：

1. `ClaudeService` 从“模型服务”膨胀为“外部平台编排器”。
2. 未来接入第二个 IM 渠道时会重复堆叠条件分支。
3. 本地 UI 会话和远程渠道会话的边界会变得混乱，测试成本也会快速上升。

因此，飞书必须作为**外部渠道层**接入，而不是核心 agent 服务层的一部分。

## 6. 分层设计

### 6.1 Channel Adapter 层

建议定义统一协议：

```swift
@MainActor
protocol IMChannelAdapter {
    var kind: IMChannelKind { get }
    func start(configuration: IMChannelConfiguration) async throws
    func stop() async
    func send(_ message: OutboundChannelMessage) async throws -> OutboundDeliveryResult
}
```

飞书适配器 `FeishuChannelAdapter` 负责：

1. 使用飞书应用凭证建立连接。
2. 接收飞书消息事件。
3. 把飞书消息转换为统一的 `InboundChannelMessage`。
4. 调用飞书发送消息接口回发文本、富文本或卡片。

后续新增渠道时，只新增新的 adapter，不修改 agent 核心。

### 6.2 Inbound Normalizer 层

建议统一入站消息结构：

```swift
struct InboundChannelMessage: Sendable {
    let channelKind: IMChannelKind
    let externalConversationID: String
    let externalMessageID: String
    let externalUserID: String
    let text: String
    let mentionsBot: Bool
    let rawPayload: String
    let receivedAt: Date
}
```

这层的价值是：

1. 上层不再关心飞书的字段名和事件结构。
2. 统一支持单聊、群聊、回复、引用、后续多平台适配。
3. 后续权限判断、去重和路由逻辑都基于统一模型处理。

### 6.3 Conversation Router 层

这层负责把“外部会话”映射到本地 `Session`。

建议策略：

1. 单聊场景：一个外部会话绑定一个本地 `Session`。
2. 群聊场景：可以按“群 ID -> Session”绑定，也可配置为禁用。
3. 首次收到消息时自动创建绑定，后续复用已有会话。

这样飞书中的连续聊天，会自然落入本地同一个 `Session`，也能复用现有消息列表与历史上下文。

### 6.4 Remote Agent Orchestrator 层

这层负责把归一化后的远程消息转成 `agentGui` 现有的执行动作。

建议职责：

1. 将入站消息写入 `Message.userMessage(...)`。
2. 选择目标 `Session`。
3. 读取该远程渠道绑定的执行策略。
4. 触发 `ClaudeService` / `WorkflowRuntime` 继续对话。
5. 收集最终文本输出。
6. 写回本地 `Message.agentMessage(...)`。

这意味着远程聊天本质上仍然是本地会话的一种输入源，而不是另起一套执行器。

### 6.5 Outbound Delivery Coordinator 层

这层负责把本地 agent 输出回发到外部 IM 平台。

建议统一出站结构：

```swift
struct OutboundChannelMessage: Sendable {
    let channelKind: IMChannelKind
    let externalConversationID: String
    let replyToExternalMessageID: String?
    let text: String
    let presentation: ChannelMessagePresentation
}
```

其中 `presentation` 用于决定：

1. 纯文本。
2. 富文本。
3. 平台卡片。
4. 错误消息。
5. 长输出是否截断并附带下载/查看入口。

### 6.6 Dedup 与 Delivery State 层

入站和出站都需要状态层支撑。

入站侧要解决：

1. 飞书消息事件重复投递。
2. 应用重启后重复消费历史事件。
3. 同一条外部消息不应重复触发多轮 agent 执行。

出站侧要解决：

1. 回发失败后的重试。
2. 记录外部消息 ID。
3. 建立本地消息与外部消息的关联，便于后续支持编辑、撤回、引用回复。

## 7. 数据模型建议

当前 `Session` 和 `Message` 已足够承载本地对话内容，但远程渠道还需要新增绑定与投递模型。建议新增 SwiftData 模型如下。

### 7.1 `ChannelAccountBinding`

表示某个外部渠道配置实例。

建议字段：

1. `id`
2. `channelKind`，如 `feishu`、`telegram`、`slack`
3. `displayName`
4. `isEnabled`
5. `credentialReference`
6. `connectionMode`，如 `longPolling`、`longConnection`、`webhook`
7. `createdAt` / `updatedAt`

### 7.2 `RemoteConversationBinding`

表示外部会话与本地 `Session` 的映射关系。

建议字段：

1. `id`
2. `channelKind`
3. `channelAccountID`
4. `externalConversationID`
5. `externalUserID`
6. `sessionId`
7. `remoteTitle`
8. `lastInboundAt`
9. `lastOutboundAt`
10. `isArchived`

### 7.3 `RemoteMessageReceipt`

用于去重与投递状态记录。

建议字段：

1. `id`
2. `channelKind`
3. `direction`，`inbound` / `outbound`
4. `externalConversationID`
5. `externalMessageID`
6. `localMessageID`
7. `externalEventID`
8. `deliveryStatus`
9. `failureReason`
10. `createdAt`

### 7.4 为什么不把这些字段直接塞进 `Session` / `Message`

不建议直接给 `Session` 和 `Message` 塞很多飞书字段，原因是：

1. 会污染核心对话模型。
2. 多平台字段差异大，很快会出现平台特化字段爆炸。
3. 外部绑定与投递记录本身就是独立维度，拆表更适合扩展和测试。

## 8. 首版推荐接入模式

### 8.1 MVP：本地直连模式

首版推荐使用：

1. `agentGui` 本机运行。
2. 本机维护飞书应用机器人的事件长连接。
3. 消息事件直接进入本地 `IM Channel Runtime`。
4. 本地执行现有 agent。
5. 本机直接调用飞书发送消息接口回写结果。

优势：

1. 不需要额外公网服务。
2. 最符合“远程连到我的本地 agent”这个目标。
3. 实现复杂度最低。
4. 调试路径最短。

局限：

1. 必须保证你的 Mac 处于运行状态。
2. 本地应用掉线时无法接收消息。
3. 不适合多人、多渠道、高可靠生产场景。

### 8.2 二期：可选网关模式

当你需要更稳定的常驻接入时，再引入 `Channel Gateway` 服务。

网关模式职责：

1. 接收飞书 webhook / 事件。
2. 统一做验签、去重和限流。
3. 把消息投递给本地 agent 节点或云端 agent 节点。
4. 统一记录外部消息收发状态。

这一步不应作为首版前置条件，否则会把问题从“接入一个远程聊天入口”升级成“搭建整套渠道网关平台”。

## 9. 与现有项目的集成点

### 9.1 App 启动编排

当前 `agentGuiApp` 已在启动阶段装配 `WorkflowRuntime` 和 `BackgroundActivityCoordinator`。后续可在同一位置引入：

1. `IMChannelRegistry`
2. `RemoteConversationCoordinator`
3. `FeishuChannelAdapter`

由设置项控制是否自动启动渠道连接。

### 9.2 会话与消息写入

远程入站消息进入后，仍然使用现有模型：

1. `Session` 作为本地会话容器。
2. `Message.userMessage(...)` 持久化用户远程输入。
3. `Message.agentMessage(...)` 持久化 agent 回复。
4. 必要时用 `Message.systemMessage(...)` 标记渠道状态、失败原因和连接事件。

这样 UI 侧现有 `ChatView`、消息气泡、归档、备份逻辑基本不需要重写。

### 9.3 Agent 执行复用

远程消息不应绕开现有 agent 执行入口。

推荐做法：

1. 在 `RemoteConversationCoordinator` 内构造与本地聊天一致的执行请求。
2. 复用 `ClaudeService` 和已有 agent loop。
3. 如果需要更强的任务级隔离，可复用类似 `BackgroundAgentLoopAdapter` 的封装方式，把“远程会话执行”也抽成独立 adapter。

这能减少重复实现，也让远程会话天然继承已有工具和记忆能力。

### 9.4 权限与策略控制

远程入口比本地输入更敏感，因此建议引入“渠道级执行策略”。

建议至少支持以下配置：

1. 是否允许该渠道触发工具调用。
2. 是否允许 Bash。
3. 是否允许文件写入。
4. 是否允许网络工具。
5. 默认工作目录。
6. 单轮和总预算限制。

不要默认让飞书远程消息直接拥有和本地桌面聊天一样的全部执行能力。

## 10. 飞书首版能力范围建议

首版只做下面这组最小闭环能力：

1. 与机器人单聊。
2. 接收纯文本消息。
3. 把文本消息映射到本地 `Session`。
4. 执行 agent。
5. 以纯文本回复结果。
6. 去重和错误提示。

首版暂缓：

1. 群聊 `@机器人`。
2. 飞书卡片交互。
3. 消息编辑与撤回同步。
4. 附件上传下载。
5. 富文本引用、线程回复、审批类工作流。

这样可以先把产品价值最大的路径跑通。

## 11. 关键流程设计

### 11.1 入站流程

1. `FeishuChannelAdapter` 收到消息事件。
2. `ChannelEventDeduplicator` 检查是否已消费。
3. `InboundNormalizer` 转成 `InboundChannelMessage`。
4. `ConversationRouter` 查找或创建 `RemoteConversationBinding`。
5. 把入站内容写为本地用户消息。
6. `RemoteAgentOrchestrator` 触发 agent 执行。
7. 收集输出并生成本地 agent 消息。
8. `OutboundDeliveryCoordinator` 回发到飞书。
9. 写入 `RemoteMessageReceipt`。

### 11.2 错误流程

如果执行失败，建议分三层处理：

1. **渠道错误**：连接失败、鉴权失败、发送失败，写系统日志并标记 receipt。
2. **路由错误**：找不到绑定、会话创建失败，给用户回一条简短错误提示。
3. **agent 执行错误**：执行超时、工具拒绝、模型失败，回发用户可理解的失败摘要。

### 11.3 幂等要求

必须以 `externalMessageID` 为主键做幂等，不能只依赖临时事件 ID。原因是平台在异常情况下可能重复推送同一条消息。

## 12. 安全与合规要求

### 12.1 凭证管理

飞书接入至少涉及：

1. `app_id`
2. `app_secret`
3. 事件校验配置
4. 后续可能还有加密 key、签名校验信息

建议：

1. 凭证不进入 `Session` / `Message`。
2. 优先存入系统 Keychain，业务模型只保存引用或脱敏元数据。
3. UI 中只展示已连接状态和最后校验时间，不展示完整秘钥。

### 12.2 远程执行安全

远程 IM 入口意味着“任何能给机器人发消息的人，都可能触发本地 agent 执行”。因此必须加策略控制：

1. 只允许白名单会话或白名单用户绑定本地执行。
2. 默认只开放只读能力。
3. 需要显式开启 Bash、写文件、网络访问。
4. 对高风险操作保留人工批准或二次确认的扩展点。

### 12.3 数据暴露控制

飞书对外共享机器人可以和外部用户交互，因此必须避免：

1. 把本地仓库敏感信息默认回发给外部用户。
2. 把系统错误栈或原始工具输出无过滤回传。
3. 把本地路径、Token、环境变量直接发到外部 IM。

建议首版统一做一层出站清洗与长度裁剪。

## 13. 可扩展性设计

为了后续接 Slack、Telegram、Discord、企业微信，推荐从一开始统一以下抽象。

### 13.1 统一枚举

```swift
enum IMChannelKind: String, Codable {
    case feishu
    case telegram
    case slack
    case wecom
    case discord
}
```

### 13.2 统一能力描述

每个渠道都声明自己的能力，而不是在业务层写平台判断。

例如：

1. 是否支持单聊。
2. 是否支持群聊 `@机器人`。
3. 是否支持富文本。
4. 是否支持卡片。
5. 是否支持编辑消息。
6. 是否支持文件附件。

这样上层编排可以按能力降级，而不是写大量 `if channel == feishu`。

### 13.3 平台特化仅停留在 adapter

不同平台的：

1. 认证方式。
2. 事件格式。
3. 消息发送接口。
4. 速率限制。
5. Markdown / 富文本方言。

都应尽量留在 adapter 内部处理，不上渗到会话路由与 agent 执行层。

## 14. 推荐实施路径

### 阶段 1：飞书单聊 MVP

目标：把你自己的飞书远程聊天链路打通。

实施内容：

1. 新增飞书渠道配置模型与设置 UI。
2. 新增 `FeishuChannelAdapter`。
3. 新增 `RemoteConversationBinding` 与 `RemoteMessageReceipt`。
4. 新增 `RemoteConversationCoordinator`。
5. 支持单聊文本入站、去重、路由、本地执行、文本回发。

### 阶段 2：策略与可观测性补齐

实施内容：

1. 为渠道会话增加执行权限策略。
2. 增加连接状态、最近收发时间、失败重试状态。
3. 增加远程会话日志与错误排查面板。

### 阶段 3：群聊与富消息

实施内容：

1. 支持群聊 `@机器人`。
2. 支持飞书富文本或卡片式回复。
3. 支持更好的引用与上下文展示。

### 阶段 4：多渠道抽象收口

实施内容：

1. 接入第二个渠道，例如 Telegram。
2. 逼出通用抽象中的薄弱点并修正。
3. 形成稳定的 `IM Channel Runtime` 框架。

## 15. 风险与建议

### 15.1 最大风险

最大风险不是飞书 API 本身，而是**本地 agent 被远程触发后的可靠性和安全性**。

如果首版忽略权限控制，很容易出现：

1. 远程消息触发高风险工具。
2. 长时间任务占满本地资源。
3. 外部用户拿到不该暴露的执行结果。

### 15.2 最务实建议

最务实的落地建议是：

1. 先做飞书单聊 MVP。
2. 首版只支持文本消息。
3. 默认只读工具权限。
4. 用长连接模式直接把飞书接到本地 macOS 应用。
5. 先把“你自己远程连自己的 agent”用顺，再进入多用户、多渠道和网关化阶段。

## 16. 最终建议

综合平台能力、当前项目架构和实现成本，推荐最终方案如下：

1. **飞书侧**：使用企业自建应用机器人，不使用群自定义机器人。
2. **接收方式**：首版使用长连接事件模式，让本地 `agentGui` 直接收消息。
3. **项目结构**：新增独立 `IM Channel Runtime`，不要把飞书逻辑写死在 `ClaudeService`。
4. **数据建模**：新增渠道绑定和消息回执模型，复用现有 `Session` / `Message` 承载实际会话内容。
5. **执行策略**：远程会话默认比本地会话更严格，采用白名单与最小权限原则。
6. **扩展方向**：后续所有 IM 工具都走同一 adapter 架构接入。

这套方案既能满足你当前“通过飞书远程和本地 agent 聊天”的目标，也不会把系统锁死在飞书的专有实现上。