# ACP -32602 Invalid Params 与 "others" 消息分类问题分析报告

**日期**：2026-04-01  
**作者**：调试分析  
**参考版本**：ACP 官方 Schema v0.11.4 · claude-agent-acp v0.24.2

---

## 1. 问题描述

使用 ACP 外部 Agent（如 claude-agent-acp）时，日志中频繁出现：

```
[ACP][runtime-client:34f75129] connection-error request-error code=-32602 message=Invalid params
```

同时，`ACPSessionUpdate` 的 `.other(kind:payload:)` case 会收到大量消息，这些消息不能被识别为任何已知类型。

---

## 2. 错误 `-32602 Invalid params` 的完整调用链分析

### 2.1 错误传播路径

日志中的 `connection-error request-error code=-32602` 是在 `ACPExternalAgentRuntimeClient` 的 `errorObserver` 回调中打印的：

```swift
// ACPExternalAgentRuntimeClient.swift
errorObserver: { [debugLogger] (error: Error) in
    let description = ACPExternalAgentRuntimeClient.describe(error)
    print("[ACP][runtime-client:\(debugID)] connection-error \(description)")
}
```

`describe` 对 `ACPRequestError` 返回 `"request-error code=\(requestError.code) message=\(requestError.message)"`。

`errorObserver` 被调用的时机来自 `ACPConnection.swift`：

```swift
// ACPConnection.swift - process() 中处理 notification
Task.detached {
    do {
        _ = try await router.handle(method: notification.method, params: notification.params, isNotification: true)
    } catch {
        await self.dispatchErrorObservers(error)  // ← 错误到达这里
    }
}
```

因此，**任何在处理 Agent 发来的 notification 时抛出的错误，都会被 `dispatchErrorObservers` 分发，最终记录为 `connection-error`**。

### 2.2 具体根因：`ToolCall.content` 类型不匹配

当 claude-agent-acp 发送 `session/update` notification 且 `sessionUpdate` 为 `"tool_call"` 或 `"tool_call_update"` 时，`content` 字段按 **ACP 官方 Schema v0.11.4** 的定义是一个数组：

```json
// 官方 Schema（schema.json）
"ToolCall": {
  "properties": {
    "content": {
      "items": { "$ref": "#/$defs/ToolCallContent" },
      "type": "array"
    }
  }
}
```

claude-agent-acp 实际发送的消息示例：

```json
{
  "sessionUpdate": "tool_call_update",
  "toolCallId": "toolu_abc123",
  "status": "complete",
  "content": [
    { "type": "diff", "path": "/src/foo.swift", "newText": "...", "oldText": "..." }
  ]
}
```

但 agentGui 中 `ACPToolCall.content` 的类型是单个可选结构体：

```swift
// agentGui ACPModels.swift
nonisolated struct ACPToolCall: Codable, Equatable, Sendable {
    var content: ACPPromptContentBlock?  // ← 单值，非数组！
    ...
}
```

当 Swift 的自动合成 `Codable` 解码器尝试将 JSON 数组 `[{...}]` 解码为 `ACPPromptContentBlock?` 时，因为类型不匹配会抛出 `DecodingError.typeMismatch`。

此错误在 `ACPMessageRouter.decodeRequired` 中被捕获，转换为 `ACPRequestError.invalidParams`：

```swift
// ACPMessageRouter
catch {
    throw ACPRequestError.invalidParams(data: .object(["reason": .string(error.localizedDescription)]))
}
```

`ACPRequestError.invalidParams` 的 code 正是 `-32602`，最终触发 `dispatchErrorObservers`，打印出：

```
connection-error request-error code=-32602 message=Invalid params
```

### 2.3 触发时机

claude-agent-acp 在以下情况下发送带有 `content` 数组的 tool update：

| 场景 | content 内容 |
|------|-------------|
| 文件编辑工具完成 | `[{ type: "diff", path, newText, oldText }]` |
| Bash/命令工具完成（支持 terminal_output） | `[{ type: "terminal", terminalId }]` |
| Bash/命令工具完成（不支持 terminal_output） | `[{ type: "content", content: { type: "text", text: "..." } }]` |
| 工具进行中（pending）| `content` 字段不存在，不触发此问题 |

因此，**每次 Tool Call 结束并返回结果时**，都会触发此 -32602 错误。

### 2.4 `ToolCallContent` 的类型差异

官方 Schema 中的 `ToolCallContent` 是一个有 `type` 判别符的联合体：

```json
"ToolCallContent": {
  "discriminator": { "propertyName": "type" },
  "oneOf": [
    { "type": "object", "required": ["type", "content"],
      "properties": { "type": { "const": "content" }, "content": { "$ref": "#/$defs/ContentBlock" } }
    },
    { "type": "object", "required": ["type", "path", "newText"],
      "properties": { "type": { "const": "diff" }, "path": ..., "newText": ..., "oldText": ... }
    },
    { "type": "object", "required": ["type", "terminalId"],
      "properties": { "type": { "const": "terminal" }, "terminalId": ... }
    }
  ]
}
```

agentGui 目前没有 `ACPToolCallContent` 类型，而是直接使用 `ACPPromptContentBlock`（对应 `ContentBlock`），这是两个不同的类型体系。

---

## 3. 消息被分类为 `.other` 的原因

### 3.1 `usage_update`：主要来源

claude-agent-acp 实现了一个**非标准扩展**的 session update 类型 `usage_update`，用于向客户端报告上下文窗口使用情况：

```typescript
// claude-agent-acp acp-agent.ts
update: {
  sessionUpdate: "usage_update",
  used: lastAssistantTotalUsage,   // 已使用 token 数
  size: contextWindowSize,          // 上下文窗口总大小
  cost: { amount: number, currency: "USD" }
}
```

这个类型**不在 ACP 官方 Schema v0.11.4 中**，是 claude-agent-acp 的私有扩展。

agentGui 中 `ACPSessionUpdate` 没有 `usage_update` case，所有此类消息都会落入：

```swift
case let .other(kind, payload):
    // kind = "usage_update"
    // payload 包含上下文用量信息，但被丢弃
```

**频率**：`usage_update` 在每次 `session/prompt` 完成后都会发送（有时在 compaction 之后也会），因此是频率最高的 "others" 消息来源。

### 3.2 官方 Session Update 类型完整性检查

将 ACP 官方 Schema 定义的 10 个 `SessionUpdate` 类型与 agentGui 对比：

| 官方类型 | agentGui | 状态 |
|---------|---------|------|
| `user_message_chunk` | `.userMessageChunk` | ✅ 已处理 |
| `agent_message_chunk` | `.agentMessageChunk` | ✅ 已处理 |
| `agent_thought_chunk` | `.agentThoughtChunk` | ✅ 已处理 |
| `tool_call` | `.toolCall(ACPToolCall)` | ⚠️ 存在，但 content 类型错误 |
| `tool_call_update` | `.toolCallUpdate(ACPToolCallUpdatePayload)` | ⚠️ 存在，但 content 类型错误 |
| `plan` | `.plan` | ✅ 已处理 |
| `available_commands_update` | `.availableCommandsUpdate` | ✅ 已处理 |
| `current_mode_update` | `.currentModeUpdate` | ✅ 已处理 |
| `config_option_update` | `.configOptionUpdate` | ✅ 已处理 |
| `session_info_update` | `.sessionInfoUpdate` | ✅ 已处理 |
| `usage_update`（非标准扩展） | `.other(kind: "usage_update", ...)` | ❌ 未处理，被丢弃 |

---

## 4. 其他协议差异（次要问题）

### 4.1 `clientCapabilities` 缺少 `_meta` 扩展字段

agentGui 发送的 `clientCapabilities` 为：

```swift
ACPClientCapabilities(
    meta: nil,
    filesystem: ACPFileSystemCapability(readTextFile: true, writeTextFile: true),
    terminal: true
)
```

但 claude-agent-acp 会检查如下字段来决定是否启用额外功能：

```typescript
// claude-agent-acp 中的能力检查
const supportsTerminalOutput = request.clientCapabilities?._meta?.["terminal_output"] === true;
const gatewayAuth = request.clientCapabilities?.auth?._meta?.gateway === true;
const terminalAuth = request.clientCapabilities?._meta?.["terminal-auth"] === true;
```

| 缺少字段 | 影响 |
|---------|------|
| `_meta.terminal_output: true` | Tool Call 结果不会嵌入 terminal 类型内容，只使用纯文本 |
| `auth._meta.gateway: true` | 不使用 gateway 认证方式 |
| `_meta["terminal-auth"]: true` | 不提供 terminal 认证方法 |

缺少 `terminal_output` 意味着客户端无法接收 `{ type: "terminal" }` 类型的 ToolCallContent，但由于 `content` 类型不匹配这个问题仍然存在（diff 类型的内容不受此影响）。

### 4.2 `ACPSessionCapabilities` 缺少 unstable 方法声明

claude-agent-acp 在 `initialize` 响应的 `agentCapabilities.sessionCapabilities` 中声明：

```json
{
  "fork": {},
  "list": {},
  "resume": {},
  "close": {}
}
```

agentGui 的 `ACPSessionCapabilities` 模型和 `ACPMethodCatalog` 仅包含 `list`，缺少 `fork`、`resume`、`close`。这些是 unstable 方法，目前未实现不影响基本功能，但无法利用。

### 4.3 `NewSessionResponse` 中缺少 `models` 字段

claude-agent-acp 在 `session/new` 响应中返回非标准的 `models` 字段：

```typescript
return { sessionId, models: SessionModelState, modes, configOptions }
```

官方 Schema 的 `NewSessionResponse` 只定义了 `sessionId`、`configOptions`、`modes`。agentGui 的 `ACPNewSessionResponse` 与官方一致，`models` 字段被忽略。此字段丢失不影响核心功能，但需要额外调用 `session/set_config_option` 才能设置模型。

### 4.4 `PromptResponse.usage` 字段

官方 Schema 的 `PromptResponse` 只包含 `stopReason`。agentGui 有 `var usage: ACPUsage?`，这是历史遗留字段。当前 claude-agent-acp 通过 `usage_update` notification 报告用量，不再在 `PromptResponse` 中返回 usage。

---

## 5. 修复建议（按优先级排序）

### P0 — 立即修复（阻断工具结果显示）

#### Fix-1：修复 `ACPToolCall.content` 为数组类型

**问题**：`tool_call` 和 `tool_call_update` 中 `content` 字段是 `ToolCallContent[]`（数组），但 agentGui 建模为单个 `ACPPromptContentBlock?`，导致 -32602 错误。

**方案**：新增 `ACPToolCallContent` 类型，并将 `ACPToolCall.content` / `ACPToolCallUpdatePayload.content` 改为 `[ACPToolCallContent]?`。

新类型定义：

```swift
nonisolated enum ACPToolCallContent: Codable, Equatable, Sendable {
    case content(ACPPromptContentBlock)    // type: "content"
    case diff(ACPToolCallDiffContent)      // type: "diff"
    case terminal(ACPToolCallTerminalRef)  // type: "terminal"
    case other(String, ACPJSONValue)       // 未知扩展类型

    // 对应的辅助结构体
}

nonisolated struct ACPToolCallDiffContent: Codable, Equatable, Sendable {
    var path: String
    var newText: String
    var oldText: String?
}

nonisolated struct ACPToolCallTerminalRef: Codable, Equatable, Sendable {
    var terminalId: String
}
```

修改 `ACPToolCall` 和 `ACPToolCallUpdatePayload`：

```swift
var content: [ACPToolCallContent]?   // 数组，替换原来的 ACPPromptContentBlock?
```

这样 `ACPExternalAgentEventNormalizer` 也需要相应更新，从数组中提取有用的内容（如取第一个 diff 的 path 作为文件路径）。

### P1 — 重要（改善用量可见性）

#### Fix-2：添加 `usage_update` 处理

**问题**：claude-agent-acp 定期发送 `usage_update` 通知报告 token 用量，agentGui 将其丢弃。

**方案**：在 `ACPSessionUpdate` 中添加 `usageUpdate` case（或继续使用 `.other` 但提升可见性）：

```swift
// 方案 A：专用 case（推荐）
case usageUpdate(ACPUsageUpdatePayload)

nonisolated struct ACPUsageUpdatePayload: Codable, Equatable, Sendable {
    var used: Int?     // 已使用 token 数
    var size: Int?     // 上下文窗口总大小
    var cost: ACPJSONValue?
}
```

然后在 `ACPExternalAgentEventNormalizer` 中将此信息透传给 UI 层，用于显示上下文窗口用量进度条。

#### Fix-3：在 `clientCapabilities._meta` 中声明 `terminal_output`

**问题**：缺少此声明导致 claude-agent-acp 不向客户端发送 terminal 类型的 ToolCallContent。

**方案**：

```swift
ACPClientCapabilities(
    meta: [
        "terminal_output": .bool(true)   // 新增
    ],
    filesystem: ACPFileSystemCapability(readTextFile: true, writeTextFile: true),
    terminal: true
)
```

注：在 Fix-1 完成之前，先不要加此声明，以免收到更多无法解析的 content 类型。

### P2 — 优化（完善协议兼容性）

#### Fix-4：`AvailableCommandInput.hint` 改为非可选

官方 Schema 中 `UnstructuredCommandInput.hint` 是 `required`，但 agentGui 目前有：

```swift
var hint: String?  // 应改为 var hint: String
```

#### Fix-5：添加 `session/close` unstable 方法

claude-agent-acp 声明了 `close` 能力，agentGui 应追踪并在必要时调用 `session/close` 进行会话资源释放。

---

## 6. 总结

| 问题 | 根因 | 影响 | 优先级 |
|------|------|------|--------|
| `connection-error request-error code=-32602` | `ToolCall.content` 被声明为单个 `ACPPromptContentBlock?`，但 ACP spec 定义为 `ToolCallContent[]` 数组；数组无法解码为单个结构体，导致 notification 处理失败 | 每次工具完成都触发错误日志，工具结果内容（diff/terminal/text）全部丢失 | P0 |
| 大量消息被分类为 `others` | `usage_update` 是 claude-agent-acp 的非标准扩展（不在官方 schema），agentGui 未添加此 case | 上下文窗口用量信息被丢弃，无法展示给用户 | P1 |
| terminal tool 内容不显示 | `clientCapabilities._meta.terminal_output` 未声明 | claude-agent-acp 降级为纯文本输出 | P1（依赖 Fix-1） |
