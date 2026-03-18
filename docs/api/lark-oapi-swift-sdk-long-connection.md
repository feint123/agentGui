# lark-oapi 长连接协议解析与 Swift SDK 开发文档

## 1. 文档目标

本文基于当前虚拟环境中的 `lark-oapi==1.5.3` Python 源码，对飞书开放平台长连接能力做逆向整理，重点回答三个问题：

1. Python SDK 的长连接链路到底怎么建立。
2. WebSocket 上传输的实际协议内容是什么。
3. 如果要编写对应的 Swift SDK，应该如何拆分模块、建模、实现重连与 ACK。

本文不是开放平台通用接入说明，而是面向 SDK 实现者的协议和架构说明。

关于 IM v2 接收消息事件 `im.message.receive_v1` 的单独拆解，可继续阅读 [docs/im-message-receive-v1-event.md](/Users/feint/Temp/feishu/docs/im-message-receive-v1-event.md)。

## 2. 分析范围

主要依据以下源码与文档：

- `venv/lib/python3.9/site-packages/lark_oapi/ws/client.py`
- `venv/lib/python3.9/site-packages/lark_oapi/ws/const.py`
- `venv/lib/python3.9/site-packages/lark_oapi/ws/enum.py`
- `venv/lib/python3.9/site-packages/lark_oapi/ws/model.py`
- `venv/lib/python3.9/site-packages/lark_oapi/ws/pb/pbbp2_pb2.py`
- `venv/lib/python3.9/site-packages/lark_oapi/event/dispatcher_handler.py`
- 飞书开放平台 Python SDK 文档中的“处理事件”“处理回调”章节

结论里会明确区分：

- 源码已明确体现的事实
- 从源码行为推导出的实现约束
- 对 Swift 版本的工程建议

## 3. 总体链路

Python SDK 的长连接不是直接拿 `app_id/app_secret` 去连 WebSocket，而是两阶段：

1. 先通过 HTTP `POST /callback/ws/endpoint` 申请一个一次性的 WebSocket 连接地址。
2. 再用返回的 `wss://...` 地址建立 WebSocket 长连接。
3. WebSocket 的二进制消息体不是 JSON，而是 protobuf `Frame`。
4. `Frame.payload` 中承载业务 JSON，控制信息在 `headers` 里。
5. SDK 收到事件后执行本地 handler，然后把处理结果再封成 `Frame` 原样回写给服务端，作为 ACK/回包。

从 Python 实现看，开放平台把“握手鉴权”前置到了 endpoint 申请和 WebSocket 握手阶段，业务收发阶段则走私有 protobuf 帧协议。

## 4. 连接建立流程

### 4.1 获取 WebSocket 地址

Python SDK 在 `Client._get_conn_url()` 中先发起：

```http
POST {domain}/callback/ws/endpoint
Content-Type: application/json
locale: zh

{
  "AppID": "<app_id>",
  "AppSecret": "<app_secret>"
}
```

返回体被反序列化为：

```json
{
  "code": 0,
  "msg": "success",
  "data": {
    "URL": "wss://...?...",
    "ClientConfig": {
      "ReconnectCount": 10,
      "ReconnectInterval": 120,
      "ReconnectNonce": 30,
      "PingInterval": 120
    }
  }
}
```

其中：

- `URL` 是实际连接地址。
- `ClientConfig` 是服务端下发的连接参数，Python 端直接覆盖本地默认值。

### 4.2 endpoint 接口错误语义

Python SDK 明确处理了以下错误码：

- `0`: 成功
- `1`: `system busy`
- `403`: forbidden
- `514`: auth failed
- `1000040343`: internal error
- `1000040344`: 缺少 `app_id` 或 `app_secret`
- `1000040350`: 超过连接数限制

结合官方文档，可确认：

- 长连接仅支持企业自建应用。
- 单应用最多 50 个连接。

### 4.3 WebSocket URL 中的重要查询参数

Python SDK 在真正连接之前会从 URL query 中取出：

- `device_id`
- `service_id`

这两个值不是本地生成，而是由服务端写进 endpoint 返回的 URL。

其中：

- `service_id` 会在客户端主动发送 ping 时写入 protobuf `Frame.service` 字段。
- `device_id` 仅用于日志和连接标识，Python SDK 保存到 `_conn_id`。

### 4.4 WebSocket 握手失败的 header 协议

如果 `websockets.connect()` 返回非 101，Python SDK 会读取这些 response header：

- `handshake-status`
- `handshake-msg`
- `handshake-autherrcode`

从 Python、Go、Java 三个官方 SDK 的实现交叉对照看，`handshake-status` 目前在客户端代码里明确枚举到的值只有两个：

| `handshake-status` | 含义 | 客户端处理 |
| --- | --- | --- |
| `403` | forbidden / 被禁止连接 | 视为客户端错误 |
| `514` | auth failed | 继续结合 `handshake-autherrcode` 判断 |

其中 `514` 的细分规则是：

| `handshake-status` | `handshake-autherrcode` | 含义 | 客户端处理 |
| --- | --- | --- | --- |
| `514` | `1000040350` | 超过连接数限制 | 视为客户端错误 |
| `514` | 其他值或缺失 | 其他鉴权失败 | 视为服务端错误 |

错误映射规则总结为：

- `handshake-status == 514` 且 `handshake-autherrcode == 1000040350`，视为客户端错误，含义是超过连接数限制。
- `handshake-status == 514` 但 auth errcode 不是上面的值，视为服务端鉴权错误。
- `handshake-status == 403`，视为客户端无权限。
- 其他则视为服务端错误。

这里的“其他”要理解成两层含义：

1. 如果服务端未来新增了新的 `handshake-status` 值，当前 SDK 会统一按服务端错误处理。
2. 如果响应里根本没有 `handshake-status` / `handshake-msg`，Python SDK 会直接把原始 WebSocket 握手异常继续抛出，而不是强行映射成飞书私有错误。

Swift SDK 应保留这套 header 级错误解析，而不是只暴露“握手失败”。

## 5. WebSocket 线协议

### 5.1 帧格式总览

WebSocket 二进制消息体是 protobuf `Frame`，定义可从 `pbbp2_pb2.py` 反推出对应 proto：

```proto
syntax = "proto2";

package pbbp2;

message Header {
  required string key = 1;
  required string value = 2;
}

message Frame {
  required uint64 SeqID = 1;
  required uint64 LogID = 2;
  required int32 service = 3;
  required int32 method = 4;
  repeated Header headers = 5;
  optional string payload_encoding = 6;
  optional string payload_type = 7;
  optional bytes payload = 8;
  optional string LogIDNew = 9;
}
```

注意：Python SDK 实际只使用了 `SeqID`、`LogID`、`service`、`method`、`headers`、`payload`，其余字段仅在协议层保留，没有业务逻辑。

### 5.2 method 字段

`method` 在 Python SDK 中被解释为 `FrameType`：

- `0`: `CONTROL`
- `1`: `DATA`

所以整个协议先分两类：

- 控制帧：ping/pong、服务端下发客户端配置
- 数据帧：事件、卡片回调等业务消息

### 5.3 header 字段语义

Python 代码中出现的 header key 如下：

- `type`
- `message_id`
- `sum`
- `seq`
- `trace_id`
- `biz_rt`

各字段的实际含义：

| Header | 含义 | 方向 | 说明 |
| --- | --- | --- | --- |
| `type` | 消息类型 | 双向 | 见下节 |
| `message_id` | 业务消息唯一 ID | 服务端 -> 客户端 | 用于分包重组 |
| `trace_id` | 链路追踪 ID | 服务端 -> 客户端 | 用于日志/排障 |
| `sum` | 分包总数 | 服务端 -> 客户端 | 大于 1 时表示 payload 被拆包 |
| `seq` | 当前分片序号 | 服务端 -> 客户端 | Python 实现按 0-based 索引处理 |
| `biz_rt` | 业务处理耗时，毫秒 | 客户端 -> 服务端 | ACK 时追加 |

### 5.4 type 字段

Python SDK 定义了四种 `MessageType`：

- `event`
- `card`
- `ping`
- `pong`

其中：

- `ping` / `pong` 只出现在控制帧。
- `event` / `card` 出现在数据帧。

### 5.5 payload 内容类型

`Frame.payload` 本身是 bytes，但 Python SDK 的实际处理方式表明：

- 对控制帧 `pong`，payload 是 UTF-8 JSON，反序列化为 `ClientConfig`。
- 对数据帧 `event`，payload 是 UTF-8 JSON 事件体。
- 对数据帧 `card`，payload 也是 UTF-8 JSON，但当前 Python 长连接客户端没有单独在 `ws/client.py` 分支处理，而是依赖统一事件分发逻辑注册对应回调。
- 对客户端回包，payload 是 UTF-8 JSON 的 `Response` 结构。

也就是说：

- 外层传输编码是 protobuf。
- 内层业务载荷主要是 JSON。

## 6. 控制帧协议

### 6.1 客户端主动 ping

Python SDK 每隔 `PingInterval` 秒发一次控制帧：

```text
method = CONTROL(0)
headers = [{ key: "type", value: "ping" }]
service = <service_id>
SeqID = 0
LogID = 0
payload = empty
```

实现细节：

- 默认 `PingInterval = 120` 秒。
- 如果 endpoint 或 pong payload 下发了新配置，本地会热更新该值。
- ping 失败只记日志，不立即断线；真正的断线判断依赖底层 WebSocket 收发异常。

### 6.2 服务端 pong

客户端收到控制帧且 `type == pong` 时：

1. 记录日志。
2. 若 `payload` 为空，不做任何额外处理。
3. 若 `payload` 非空，则把它按 UTF-8 JSON 解析为：

```json
{
  "ReconnectCount": <int>,
  "ReconnectInterval": <int>,
  "ReconnectNonce": <int>,
  "PingInterval": <int>
}
```

然后直接更新客户端运行参数。

这说明 `pong` 同时承担两件事：

- keepalive
- 动态配置下发

### 6.3 服务端 ping

Python SDK 如果收到控制帧且 `type == ping`，当前实现直接 `return`，不会显式回 pong。

这意味着至少在 Python SDK 的当前实现里，客户端 keepalive 的主动方是客户端自己，服务端 ping 并不是必须要回应的协议步骤。

Swift 版本建议仍然兼容服务端 ping，至少提供可选自动 pong 逻辑，但默认行为应先与 Python SDK 保持一致，避免过度推测。

## 7. 数据帧协议

### 7.1 收包时必须读取的 header

Python SDK 在处理数据帧时，强依赖以下 header：

- `message_id`
- `trace_id`
- `sum`
- `seq`
- `type`

任意缺失都会抛出异常并打错误日志。

Swift SDK 应把它们建模为强类型字段，而不是裸字典直接透传。

### 7.2 分包与合包

当 `sum > 1` 时，说明单个业务消息被拆成多片发送。

Python 合包逻辑：

1. 以 `message_id` 为 key 建一个临时缓存。
2. 缓存值是长度为 `sum` 的字节数组列表。
3. 用 `seq` 作为数组索引填入当前片段。
4. 若还有空位，则继续等待其他片段。
5. 全部到齐后按数组顺序拼接为完整 payload。

实现细节：

- `seq` 明显按 0-based 使用，因为代码直接 `buf[seq] = bs`。
- 缓存 TTL 是 5 秒，超时未拼齐则自动丢弃。

Swift 版需要复制这个语义，否则大消息会解析失败。

### 7.3 `event` 类型载荷

拼好包后，如果 `type == event`，Python SDK 直接把 payload 当 UTF-8 JSON 字符串交给 `EventDispatcherHandler.do_without_validation()`。

这说明长连接事件体格式与 HTTP 回调收到的事件 JSON 基本一致。

兼容两类结构：

#### v2 事件

通过以下字段判断：

- `schema` 非空
- `header.event_type`
- `header.token`

其中 `EventHeader` 包含：

- `event_id`
- `token`
- `create_time`
- `event_type`
- `tenant_key`
- `app_id`

#### v1 事件

通过以下字段判断：

- `uuid` 非空
- `event.type`

长连接模式下 Python 走 `do_without_validation()`，不会做 HTTP 模式里的签名校验和 challenge 校验。

### 7.4 `card` 类型载荷

`MessageType` 枚举里存在 `card`，官方文档也说明长连接支持：

- `card.action.trigger`
- `url.preview.get`

但 `ws/client.py` 中 `elif message_type == MessageType.CARD: return` 看起来没有在此处分发。

从整体 SDK 行为与官方文档对照，可得到两个结论：

1. 长连接协议层确实支持卡片/链接预览回调。
2. Python 当前版本在 `ws/client.py` 这一层对 `card` 分支的处理并不完整，或者该分支只用于旧卡片类型，实际主路径依赖统一事件处理器注册的 `p2.card.action.trigger` 和 `p2.url.preview.get`。

因此 Swift SDK 不应把“只支持 `event`”当成协议事实，而应保留：

- `event`
- `card`

两种数据消息类型，并允许上层 dispatcher 决定如何解析。

## 8. ACK / 回包协议

### 8.1 Python 的 ACK 行为

收到数据帧后，Python SDK 会：

1. 保留原始 `Frame` 对象。
2. 执行本地 handler。
3. 在原始 `headers` 末尾追加 `biz_rt`。
4. 把 `frame.payload` 改写为响应 JSON。
5. 原样把整个 `Frame` 再发回服务端。

也就是说，ACK 不是另起一套结构，而是“原帧回写 + payload 改写”。

这点非常关键，Swift 版必须照做。

### 8.2 ACK payload 结构

Python 回包使用 `lark_oapi.ws.model.Response`，序列化结果等价于：

```json
{
  "code": 200,
  "headers": null,
  "data": null
}
```

字段说明：

- `code`: HTTP 风格状态码
- `headers`: 预留字段，Python 长连接当前没有实际填充
- `data`: 可选的业务返回值

### 8.3 事件成功回包

普通事件处理成功：

```json
{
  "code": 200,
  "headers": null,
  "data": null
}
```

### 8.4 回调成功回包

如果 handler 有返回值，例如：

- `card.action.trigger`
- `url.preview.get`

Python 会执行：

1. `JSON.marshal(result)`
2. UTF-8 编码
3. Base64 编码
4. 填入 `Response.data`

所以回包实际长这样：

```json
{
  "code": 200,
  "headers": null,
  "data": "<base64 of json bytes>"
}
```

注意：这里 `data` 不是直接放 JSON 对象，而是放 Base64 字符串。

这是 Swift SDK 实现里最容易漏掉的一点。

### 8.5 失败回包

如果 handler 抛异常，Python 会返回：

```json
{
  "code": 500,
  "headers": null,
  "data": null
}
```

并且同样通过原始 `Frame` 回写。

### 8.6 `biz_rt`

Python 以毫秒为单位统计 handler 执行耗时，然后追加 header：

```text
key = "biz_rt"
value = "<毫秒字符串>"
```

它是服务端评估业务处理时延的关键字段，Swift SDK 不应省略。

## 9. Python SDK 暴露出来的运行时语义

### 9.1 自动重连

Python SDK 支持自动重连，参数来自 `ClientConfig`：

- `ReconnectCount`
- `ReconnectInterval`
- `ReconnectNonce`

语义如下：

- `ReconnectNonce > 0` 时，首次重连前随机 sleep 一个 `[0, nonce)` 秒的抖动。
- `ReconnectCount >= 0` 时，最多重试固定次数。
- `ReconnectCount < 0` 时，无限重试。
- 相邻重试间隔固定为 `ReconnectInterval` 秒。

### 9.2 并发模型

Python 方案是：

- 单个 WebSocket 连接
- 一个 receive loop
- 每次收到消息后 `create_task(_handle_message(msg))`
- ping loop 独立运行
- 通过 `asyncio.Lock` 保护连接对象和写操作

这意味着消息处理默认允许并发，ACK 顺序不保证严格串行。

Swift 版如果用 actor，建议：

- I/O 层串行化写入
- 业务 handler 可以并发执行
- 每个入站消息独立生成 ACK

### 9.3 3 秒超时约束

官方文档明确说明：

- 长连接模式下，收到消息后需要在 3 秒内处理完成。
- 超时会触发重推。

因此 Swift SDK 需要提供超时控制和快速 ACK 能力，至少要让上层能选择：

- 同步处理后 ACK
- 先快速 ACK，再异步落库或投递内部队列

## 10. Swift SDK 建议架构

### 10.1 模块划分

建议拆成以下模块：

#### `FeishuLongConnAuth`

负责：

- 调用 `/callback/ws/endpoint`
- 解析 `EndpointResp`
- 对接 `appID/appSecret`

#### `FeishuLongConnProto`

负责：

- protobuf `Frame` / `Header` 模型
- header typed wrapper
- 数据帧、控制帧、ACK 编码解码

建议直接用 `.proto` 生成 SwiftProtobuf 代码，而不是手写 protobuf 编码。

#### `FeishuLongConnTransport`

负责：

- WebSocket 连接
- ping loop
- receive loop
- reconnect
- write serialization

#### `FeishuLongConnDispatcher`

负责：

- payload JSON 解码
- v1/v2 事件识别
- handler 路由
- 回包生成

#### `FeishuLongConnPublicAPI`

对外提供：

- `LongConnectionClient`
- handler 注册 DSL
- 连接状态回调
- 日志接口

### 10.2 建议的核心模型

#### endpoint 响应

```swift
struct EndpointResponse: Decodable {
    let code: Int
    let msg: String?
    let data: EndpointData?
}

struct EndpointData: Decodable {
    let url: String
    let clientConfig: ClientConfig?

    enum CodingKeys: String, CodingKey {
        case url = "URL"
        case clientConfig = "ClientConfig"
    }
}

struct ClientConfig: Decodable {
    let reconnectCount: Int?
    let reconnectInterval: Int?
    let reconnectNonce: Int?
    let pingInterval: Int?

    enum CodingKeys: String, CodingKey {
        case reconnectCount = "ReconnectCount"
        case reconnectInterval = "ReconnectInterval"
        case reconnectNonce = "ReconnectNonce"
        case pingInterval = "PingInterval"
    }
}
```

#### header wrapper

```swift
struct FrameHeaders {
    let type: String
    let messageID: String?
    let traceID: String?
    let sum: Int?
    let seq: Int?
    let bizRT: Int?
    let raw: [String: String]
}
```

#### ACK payload

```swift
struct AckResponse: Encodable {
    let code: Int
    let headers: [String: String]?
    let data: String?
}
```

其中 `data` 必须是 Base64 字符串，而不是任意 JSON 值。

### 10.3 actor 设计建议

Swift 6 及以后建议用 actor 做状态收敛：

- `LongConnectionClientActor`
  - 持有当前 socket
  - 持有 serviceID / deviceID
  - 持有 client config
  - 串行发送帧
  - 管理重连状态

- `MultipartAssembler`
  - 按 `message_id` 聚合分包
  - 自动超时清理

- `EventRouter`
  - 根据 schema/type 派发到具体 handler

### 10.4 上层 handler 建议

建议支持三类注册：

1. typed v2 event handler
2. customized v1 event handler
3. callback handler with response

示意：

```swift
client.onEvent("im.message.receive_v1", as: P2ImMessageReceiveV1.self) { event in
    // handle
}

client.onCustomizedEvent("message") { event in
    // handle
}

client.onCallback("card.action.trigger", as: CardActionTrigger.self) { callback in
    return CardActionTriggerResponse(...)
}
```

## 11. Swift 实现时必须保留的协议约束

### 必做项

1. 先调 `/callback/ws/endpoint`，不能自行拼 WebSocket URL。
2. WebSocket 消息必须按 protobuf `Frame` 编解码。
3. `service_id` 需要从 URL query 提取，并写入主动 ping 帧。
4. 数据帧必须识别并重组分包。
5. ACK 必须在原帧基础上回写，而不是只发一个独立 JSON。
6. ACK payload 必须使用 `Response` JSON 结构。
7. callback 返回值必须先 JSON，再 Base64，最后塞入 `Response.data`。
8. 成功 ACK 附带 `biz_rt`。
9. 支持服务端通过 `pong.payload` 动态调整 reconnect/ping 参数。
10. 处理时延要控制在 3 秒内。

### 建议项

1. 握手失败时解析 `handshake-status` 等 response header。
2. 暴露 `trace_id` 和 `message_id` 给上层日志。
3. 提供无限重连和固定次数重连两种策略。
4. 为分包缓存增加过期回收任务。
5. 对外暴露原始 `Frame` 调试信息，便于排查协议差异。

## 12. 一个可直接照着实现的消息流程

### 12.1 启动

1. 业务方创建 `LongConnectionClient(appID, appSecret)`。
2. SDK 调 endpoint 接口拿到 `URL + ClientConfig`。
3. SDK 解析 query，提取 `device_id/service_id`。
4. SDK 建立 WebSocket。
5. SDK 启动 receive loop 和 ping loop。

### 12.2 收到事件

1. 收到二进制 WebSocket message。
2. protobuf 解码成 `Frame`。
3. 若 `method == control`，走 ping/pong 处理。
4. 若 `method == data`，提取 headers。
5. 若 `sum > 1`，先合包。
6. 将 payload 按 UTF-8 解码成 JSON。
7. 根据事件版本和事件类型分发 handler。
8. 统计处理耗时。
9. 生成 `AckResponse`。
10. 原帧追加 `biz_rt`，改写 payload，序列化后发送。

### 12.3 断线

1. receive loop 抛异常。
2. 清空当前连接状态。
3. 根据配置做随机抖动。
4. 按 `ReconnectInterval` 重试。
5. 重连成功后恢复 ping loop/receive loop。

## 13. 已知不确定点

下面这些点源码没有完全讲透，Swift 首版应按“兼容而非猜测”处理：

1. `payload_encoding` / `payload_type` / `LogIDNew` 在 Python 1.5.3 中未被业务逻辑使用，先完整透传即可，不要擅自删除 proto 字段。
2. `card` 类型在 `ws/client.py` 中的分支看起来不完整，但官方文档明确说长连接支持卡片回调与链接预览回调，因此 Swift 版应保留该消息类型并允许上层扩展解析。
3. Python 对服务端 `ping` 没有显式 `pong` 响应，Swift 版默认应保持兼容；如果后续抓包发现服务端要求响应，再增配开关。

## 14. 推荐的 Swift 首版交付范围

建议按以下顺序做 MVP：

1. endpoint 获取与错误码封装
2. protobuf `Frame` 生成
3. WebSocket 建连与二进制收发
4. ping/pong 与动态配置
5. `event` 数据帧解析
6. 分包重组
7. ACK 回写
8. typed v2 event router
9. callback response Base64 回包
10. 自动重连

如果第一版目标是尽快可用，可以暂时不做：

- `card` 特殊分支的额外抽象
- 更复杂的 backpressure 控制
- 持久化去重

## 15. 总结

`lark-oapi` Python 长连接的核心可以压缩成一句话：

“先通过 HTTP 拿一次性 WebSocket 地址，再用 protobuf `Frame` 在 WebSocket 上传输 JSON 业务消息，客户端处理后通过回写原始 `Frame` 完成 ACK。”

对 Swift SDK 来说，最关键的不是 WebSocket 本身，而是三件事：

1. 正确复刻 `Frame` 协议与 header 语义。
2. 正确复刻 ACK 结构，尤其是 `biz_rt` 和 Base64 `data`。
3. 正确复刻动态配置、分包合包和重连策略。

只要这三件事做对，Swift 版本在协议层就能与 Python SDK 保持兼容。