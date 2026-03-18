# im.message.receive_v1 事件详解

## 1. 文档目标

本文专门说明飞书 IM v2 接收消息事件 `im.message.receive_v1` 的结构、触发条件、字段语义，以及在 Swift SDK 中建议如何建模和消费该事件。

本文聚焦事件本身，不重复解释长连接的 protobuf `Frame` 传输层。传输层协议可参考同目录下的长连接总文档。

## 2. 事件定位

`im.message.receive_v1` 是飞书消息能力里最常用的入站事件之一。机器人接收到用户发送的消息后，会触发这个事件。

从 Python SDK 模型可知，该事件在 SDK 中映射为：

- 顶层类型：`P2ImMessageReceiveV1`
- 业务数据：`P2ImMessageReceiveV1Data`
- 主要字段：`event.sender`、`event.message`

这说明它属于：

- P2，即事件 2.0 结构
- `im` 业务域
- 事件类型 `im.message.receive_v1`

## 3. 触发条件与权限

根据官方文档，这个事件要能收到，至少满足以下前提：

1. 应用开启机器人能力。
2. 在开发者后台订阅 `接收消息 v2.0` 事件。
3. 应用具备匹配的消息权限。

权限影响推送范围：

- 具备 `im:message.p2p_msg` 或只读版本时，可收到用户发给机器人的单聊消息。
- 具备 `im:message.group_msg` 时，可收到机器人所在群聊中的普通消息，但不包含机器人自己发送的消息。
- 具备 `im:message.group_at_msg` 或只读版本时，可收到群聊中 @ 机器人的消息。
- 具备 `im:user_agent:read` 时，事件中才会返回 `user_agent`。

这意味着 Swift SDK 不应把某些字段视为绝对必返，尤其是 `user_agent` 和某些 ID 字段，需要按可选值处理。

## 4. 顶层事件结构

官方文档和 Python SDK 一致表明，事件体采用统一的 P2 格式：

```json
{
  "schema": "2.0",
  "header": {
    "event_id": "5e3702a84e847582be8db7fb73283c02",
    "event_type": "im.message.receive_v1",
    "create_time": "1608725989000",
    "token": "rvaYgkND1GOiu5MM0E1rncYC6PLtF7JV",
    "app_id": "cli_xxx",
    "tenant_key": "xxx"
  },
  "event": {
    "sender": {},
    "message": {}
  }
}
```

### 顶层字段说明

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `schema` | string | 固定为 `2.0` |
| `header.event_id` | string | 本次事件实例 ID |
| `header.event_type` | string | 固定为 `im.message.receive_v1` |
| `header.create_time` | string | 事件创建时间，毫秒时间戳字符串 |
| `header.token` | string | 事件 token |
| `header.app_id` | string | 应用 app_id |
| `header.tenant_key` | string | 租户标识 |
| `event.sender` | object | 发送者信息 |
| `event.message` | object | 消息本体 |

## 5. sender 结构

Python SDK 中 `event.sender` 映射为 `EventSender`：

```python
class EventSender(object):
    _types = {
        "sender_id": UserId,
        "sender_type": str,
        "tenant_key": str,
    }
```

### 字段说明

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `sender_id` | object | 发送者 ID 集合 |
| `sender_type` | string | 发送者类型 |
| `tenant_key` | string | 发送者所属租户 |

其中 `sender_id` 是一个复合对象，不是单个字符串。Swift 侧应继续保持复合模型，而不要只保留一种 ID。

常见实现方式：

```swift
struct UserIDSet: Decodable, Sendable {
    let unionID: String?
    let userID: String?
    let openID: String?

    enum CodingKeys: String, CodingKey {
        case unionID = "union_id"
        case userID = "user_id"
        case openID = "open_id"
    }
}
```

即便某些字段在当前租户下经常为空，也不建议删掉，因为跨租户、商店应用和不同权限组合下返回值会变化。

## 6. message 结构

Python SDK 中 `event.message` 映射为 `EventMessage`：

```python
class EventMessage(object):
    _types = {
        "message_id": str,
        "root_id": str,
        "parent_id": str,
        "create_time": int,
        "update_time": int,
        "chat_id": str,
        "thread_id": str,
        "chat_type": str,
        "message_type": str,
        "content": str,
        "mentions": List[MentionEvent],
        "user_agent": str,
    }
```

### 字段说明

| 字段 | 类型 | 必要性 | 说明 |
| --- | --- | --- | --- |
| `message_id` | string | 高 | 消息唯一 ID，幂等应优先用它去重 |
| `root_id` | string | 中 | 话题根消息 ID |
| `parent_id` | string | 中 | 父消息 ID，回复场景常见 |
| `create_time` | int | 高 | 消息创建时间，毫秒时间戳 |
| `update_time` | int | 中 | 消息更新时间 |
| `chat_id` | string | 高 | 会话 ID |
| `thread_id` | string | 中 | 话题 ID |
| `chat_type` | string | 高 | 会话类型，如单聊/群聊 |
| `message_type` | string | 高 | 消息类型，如 `text`、`image` |
| `content` | string | 高 | 消息内容，注意它本身仍然是 JSON 字符串 |
| `mentions` | array | 中 | 被 @ 用户列表 |
| `user_agent` | string | 低 | 用户代理信息，需要额外权限 |

## 7. `content` 字段的关键语义

`content` 是这个事件里最容易踩坑的字段。

它虽然类型是 `string`，但语义上不是普通文本，而是“二次编码的 JSON 字符串”。也就是说，完整解析流程通常是：

1. 先把整个事件 JSON 解成 `P2ImMessageReceiveV1`。
2. 取出 `event.message.content`，它还是一个字符串。
3. 再根据 `message_type`，把这个字符串二次反序列化成对应的消息内容模型。

例如文本消息通常会呈现为：

```json
"content": "{\"text\":\"hello\"}"
```

而不是：

```json
"content": {
  "text": "hello"
}
```

所以 Swift SDK 里不要把 `content` 直接设计成 `[String: Any]` 或泛型 `Decodable` 字段；更稳妥的做法是：

```swift
struct IMEventMessage: Decodable, Sendable {
    let messageID: String
    let messageType: String
    let content: String
}
```

然后再提供二段式解析 API：

```swift
func decodeContent<T: Decodable>(_ type: T.Type) throws -> T
```

## 8. `mentions` 结构

被 @ 信息在 Python SDK 中映射为 `MentionEvent`：

```python
class MentionEvent(object):
    _types = {
        "key": str,
        "id": UserId,
        "name": str,
        "tenant_key": str,
    }
```

字段含义：

- `key`: 原消息内容里的 mention 占位 key
- `id`: 被 @ 对象的多种 ID
- `name`: 展示名称
- `tenant_key`: 所属租户

如果你要做文本渲染、命令机器人或权限判断，`mentions` 往往比自己正则解析文本更可靠。

## 9. 幂等与去重

官方文档明确指出：

- 特殊情况下可能会收到重复推送。
- 有幂等需求时应使用 `message_id` 去重。
- 不要依赖 `event_id` 去重。

这点非常重要，因为：

- `event_id` 描述的是某次推送实例。
- `message_id` 描述的是业务消息实体。

如果 SDK 需要提供高层消费接口，建议直接支持一个 message-level dedupe hook，而不是让业务方重复实现。

## 10. 长连接模式下与协议层的关系

在 Python 长连接客户端中，`im.message.receive_v1` 最终是按 `event` 类型的数据帧进入统一事件分发器的。也就是说，这个事件在传输层没有任何 IM 专用优化，处理路径是：

1. WebSocket 收到 protobuf `Frame`
2. `headers.type == event`
3. 提取 `payload` UTF-8 JSON
4. 统一反序列化为 P2 事件上下文
5. 根据 `header.event_type == im.message.receive_v1` 路由到具体 handler

因此 Swift SDK 中最好把它看成“标准事件类型”，不要为它单独造一套不同的收包流程。

## 11. Swift 建模建议

### 11.1 顶层模型

```swift
struct P2IMMessageReceiveV1: Decodable, Sendable {
    let schema: String
    let header: EventHeader
    let event: DataPayload

    struct DataPayload: Decodable, Sendable {
        let sender: EventSender
        let message: EventMessage
    }
}
```

### 11.2 sender / message 模型

```swift
struct EventSender: Decodable, Sendable {
    let senderID: UserIDSet?
    let senderType: String?
    let tenantKey: String?

    enum CodingKeys: String, CodingKey {
        case senderID = "sender_id"
        case senderType = "sender_type"
        case tenantKey = "tenant_key"
    }
}

struct EventMessage: Decodable, Sendable {
    let messageID: String?
    let rootID: String?
    let parentID: String?
    let createTime: Int64?
    let updateTime: Int64?
    let chatID: String?
    let threadID: String?
    let chatType: String?
    let messageType: String?
    let content: String?
    let mentions: [Mention]?
    let userAgent: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case rootID = "root_id"
        case parentID = "parent_id"
        case createTime = "create_time"
        case updateTime = "update_time"
        case chatID = "chat_id"
        case threadID = "thread_id"
        case chatType = "chat_type"
        case messageType = "message_type"
        case content
        case mentions
        case userAgent = "user_agent"
    }
}
```

### 11.3 建议的便捷接口

建议再包一层业务友好的访问器：

```swift
extension EventMessage {
    var isGroupChat: Bool { chatType == "group" }
    var isP2PChat: Bool { chatType == "p2p" }

    func decodeContent<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = .init()) throws -> T {
        guard let content else {
            throw IMMessageError.emptyContent
        }
        return try decoder.decode(T.self, from: Data(content.utf8))
    }
}
```

## 12. 建议提供的消息内容解码层

为了避免上层到处手写 `switch messageType + decodeContent`，可以提供统一内容枚举：

```swift
enum IMMessageContent {
    case text(TextContent)
    case image(ImageContent)
    case file(FileContent)
    case post(PostContent)
    case interactiveCard(RawJSON)
    case unknown(String, raw: String)
}
```

然后：

```swift
func parseContent(messageType: String, rawContent: String) -> IMMessageContent
```

这样做的好处：

- 顶层事件模型保持稳定
- 不会因为消息类型扩展频繁改动传输层模型
- `unknown` 分支可以保留前向兼容

## 13. 业务处理建议

### 建议优先做的事

1. 用 `message_id` 做幂等去重。
2. 根据 `chat_type` 分流单聊和群聊逻辑。
3. 根据 `message_type` 做二次 content 解析。
4. 在群聊中优先检查 `mentions`，不要只靠文本匹配 `@机器人`。
5. 记录 `chat_id`、`message_id`、`sender_id`、`trace_id` 到日志。

### 不建议直接假设的事

1. 不要假设 `content` 永远是纯文本。
2. 不要假设 `user_agent` 一定存在。
3. 不要假设 `event_id` 可用于去重。
4. 不要假设 `sender_id.user_id` 一定有值。

## 14. 对 Swift SDK 的直接实现建议

如果你正在写 Swift 版飞书 SDK，`im.message.receive_v1` 这部分建议按下面的顺序落地：

1. 先把顶层事件和 sender/message 模型完整解出来。
2. 再给 `content` 做二段式解析接口。
3. 再加标准消息类型的内容模型。
4. 最后再做机器人命令路由、关键词路由等高层能力。

原因很直接：

- 事件模型是稳定层。
- 内容模型是半稳定层。
- 机器人业务路由是变化最快的一层。

先把层次拆开，后续扩展不会把核心协议层弄乱。

## 15. 总结

`im.message.receive_v1` 的本质可以简化为：

- 顶层是标准 P2 事件
- 核心业务数据在 `event.sender` 和 `event.message`
- `message.content` 是 JSON 字符串，需要二次解析
- 幂等应该使用 `message_id`
- 字段返回范围受权限影响，很多字段必须按可选值处理

如果 Swift SDK 能把这五点处理正确，这个事件的接入就已经比较稳了。