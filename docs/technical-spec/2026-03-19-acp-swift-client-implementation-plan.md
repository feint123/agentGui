# ACP Swift Client 实现计划

> 状态：实施计划  
> 日期：2026-03-19

---

## 1. 结论先行

基于 `/Users/feint/Temp/feishu/.venv/lib/python3.12/site-packages/acp` 源码分析，Python 版 ACP 并不存在一个单独名为 `AgentClientProtocol` 的核心类。它的真实实现是以下几层组合：

1. `Connection`：双向 JSON-RPC 2.0 连接实现。
2. `MessageRouter`：方法名到类型化处理函数的路由与参数校验层。
3. `client/connection.py`：把“Swift 端作为 ACP Client，连到 Agent”封装成高层调用接口。
4. `agent/connection.py`：把“对端 Agent 反向调用 Client 能力”封装成高层调用接口。
5. `schema.py` + `meta.py`：协议模型和方法表。
6. `task/*`：请求、通知、写流、状态跟踪的异步调度基础设施。

对 `agentGui` 来说，最合理的目标不是照搬 Python API 形式，而是实现一个 **Swift 原生、actor 化、支持双向调用的 ACP Client 运行时**。

推荐结论如下：

1. 首期只实现 **ACP Client**，即 Swift 侧连接外部 ACP Agent，并实现 Client 侧回调能力。
2. 传输层不要复用当前 LSP 的 `Content-Length` JSON-RPC framing；ACP Python 版实际使用的是 **newline-delimited JSON**。
3. 进程拉起、PATH 解析、stdio 管理可复用现有 LSP 进程监管思路，但协议层需要单独实现。
4. 模型层不要一开始手写全量 schema；应先按 MVP 覆盖稳定主链路，再决定是否引入代码生成。
5. 当前工作区中 `ClaudeService` 已经整理到 `Services/ClaudeService/ClaudeService.swift`，ACP 可以直接落到独立的 `Services/ACP/` 目录。

---

## 2. ACP Python 源码分析摘要

### 2.1 连接与 framing

`acp.connection.Connection` 的职责非常明确：

1. `send_request` 发送 `{"jsonrpc":"2.0","id":...,"method":...,"params":...}`。
2. `send_notification` 发送无 `id` 的通知。
3. `_receive_loop` 用 `reader.readline()` 按行读取。
4. `MessageSender` 用 `json.dumps(...) + "\n"` 写出。

这说明 Python ACP SDK 当前采用的是：

1. JSON-RPC 2.0 语义。
2. newline-delimited JSON framing。
3. 双向 request/response/notification。

因此它和当前仓库的 [agentGui/Services/LSP/LSPJSONRPCTransport.swift](agentGui/Services/LSP/LSPJSONRPCTransport.swift) 不是同一种 framing，不能直接复用。

### 2.2 路由与参数绑定

`acp.router.MessageRouter` 做了三件事：

1. 按方法名匹配 request / notification route。
2. 用 Pydantic model 对 `params` 做强校验。
3. 将 `_meta` 字段拆开放到处理函数的关键字参数里。

同时它支持扩展方法：

1. 任何以 `_` 开头的方法都走扩展入口。
2. 正常方法表由 `meta.py` 固定定义。

Swift 侧要保留这个设计：

1. 核心协议方法走静态枚举或静态表。
2. 扩展方法走 `custom(method:params:)` 通道。

### 2.3 双向接口角色

ACP 不是“Client 只发请求，Agent 只回响应”的单向协议。

源码里分成两个 protocol：

1. `Agent`
   Swift Client 主动调用的对端能力，如：
   - `initialize`
   - `session/new`
   - `session/load`
   - `session/prompt`
   - `session/cancel`
   - `authenticate`
2. `Client`
   对端 Agent 反向调用 Swift 端的能力，如：
   - `session/update`
   - `session/request_permission`
   - `fs/read_text_file`
   - `fs/write_text_file`
   - `terminal/create`
   - `terminal/output`
   - `terminal/wait_for_exit`
   - `terminal/kill`
   - `terminal/release`

这意味着 Swift 版 ACP Client 不能只做一个“request sender”，必须实现：

1. 出站调用。
2. 入站路由。
3. pending request continuation 管理。
4. Client callback handler 注入。

### 2.4 并发与错误模型

Python 实现把读循环、写循环、请求处理、通知处理分开：

1. `MessageSender` 保证写流串行。
2. `DefaultMessageDispatcher` 负责把入站消息投递给后台任务。
3. `MessageStateStore` 负责 pending outgoing request 映射。
4. `TaskSupervisor` 负责统一回收和错误传播。

错误层面使用标准 JSON-RPC code：

1. `-32700` parse error
2. `-32600` invalid request
3. `-32601` method not found
4. `-32602` invalid params
5. `-32603` internal error
6. `-32000` auth required
7. `-32002` resource not found

Swift 实现应保持相同语义，而不是把所有错误压成单一 `NSError`。

### 2.5 协议版本与稳定性

`meta.py` 中当前可见：

1. `PROTOCOL_VERSION = 1`
2. 部分方法受 `use_unstable_protocol` 控制

当前不稳定方法主要包括：

1. `session/list`
2. `session/fork`
3. `session/resume`
4. `session/set_model`

因此 Swift 端应把方法分层：

1. 稳定主链路默认开启。
2. 不稳定能力通过 feature flag 或 capability 开关暴露。

---

## 3. 与 agentGui 当前架构的关系

### 3.1 可复用部分

当前仓库里最接近的现成基础设施是 LSP 相关实现：

1. [agentGui/Services/LSP/LSPProcessSupervisor.swift](agentGui/Services/LSP/LSPProcessSupervisor.swift)
2. [agentGui/Services/LSP/LSPClient.swift](agentGui/Services/LSP/LSPClient.swift)
3. [agentGui/Services/LSP/LSPJSONRPCTransport.swift](agentGui/Services/LSP/LSPJSONRPCTransport.swift)

可复用的不是协议本身，而是以下经验：

1. 进程启动与 PATH 解析。
2. `Process` + `Pipe` 管理方式。
3. stdout / stderr 生命周期监控。
4. request/response continuation 管理思路。

### 3.2 不应直接复用的部分

以下部分不应直接沿用：

1. `LSPJSONRPCTransport` 的 `Content-Length` framing。
2. LSP 特有方法和 capability 协商模型。
3. LSP 假设“Client 主动发，Server 主要通知”的 API 外形。

ACP 需要的是：

1. 双向对等 RPC。
2. newline JSON 帧解析器。
3. 通知与请求的统一入站路由。
4. 可插拔的 Client callback provider。

### 3.3 当前代码库中的实现落位

当前工作区里，`ClaudeService` 已经位于 [agentGui/Services/ClaudeService/ClaudeService.swift](agentGui/Services/ClaudeService/ClaudeService.swift)，因此 ACP 的实现可以直接落到独立目录：

1. `Services/ACP/` 承载协议层与运行时。
2. `ClaudeService`、LSP、Terminal 继续作为被桥接的业务能力。

---

## 4. Swift 版 ACP Client 目标边界

### 4.1 首期目标

首期 Swift ACP Client 只解决以下问题：

1. 启动或附着一个外部 ACP Agent 进程。
2. 完成 `initialize` 握手。
3. 创建 / 加载 session。
4. 发起 `session/prompt`。
5. 接收 `session/update` 增量更新。
6. 响应 Agent 发来的 permission / fs / terminal 回调。
7. 提供取消、关闭与错误恢复基础能力。

### 4.2 非目标

首期不做以下内容：

1. ACP Agent 端实现。
2. 全量 schema 一次性覆盖。
3. UI 层完整集成。
4. 多传输形态同时支持。
5. 自动代码生成流水线。

### 4.3 推荐 MVP 方法面

建议 MVP 按“能跑完整对话主链路”来收敛：

1. Agent methods
   - `initialize`
   - `session/new`
   - `session/load`
   - `session/prompt`
   - `session/cancel`
   - `authenticate`
2. Client callbacks
   - `session/update`
   - `session/request_permission`
   - `fs/read_text_file`
   - `fs/write_text_file`
   - `terminal/create`
   - `terminal/output`
   - `terminal/wait_for_exit`
   - `terminal/kill`
   - `terminal/release`

`session/list`、`session/fork`、`session/resume`、`session/set_model` 建议放到第二阶段。

---

## 5. 推荐架构

### 5.1 目录结构建议

建议新建独立目录：

1. `agentGui/Services/ACP/ACPConnection.swift`
2. `agentGui/Services/ACP/ACPTransport.swift`
3. `agentGui/Services/ACP/ACPMessageRouter.swift`
4. `agentGui/Services/ACP/ACPModels.swift`
5. `agentGui/Services/ACP/ACPMethodCatalog.swift`
6. `agentGui/Services/ACP/ACPClientRuntime.swift`
7. `agentGui/Services/ACP/ACPProcessSupervisor.swift`
8. `agentGui/Services/ACP/ACPRequestError.swift`
9. `agentGui/Services/ACP/ACPClientHandler.swift`
10. `agentGui/Services/ACP/ACPEventObserver.swift`

如果后续模型增多，再拆成 `ACPModels/` 子目录。

### 5.2 分层职责

#### 5.2.1 `ACPTransport`

职责：

1. 处理 stdio 读写。
2. 解析 newline-delimited JSON frame。
3. 输出原始 `[String: Any]` 或 typed `ACPWireMessage`。
4. 保持写流串行。

实现建议：

1. 用 `actor` 持有写队列和 pending continuation。
2. 读流可以通过 `AsyncThrowingStream<Data, Error>` 或逐行解码器实现。
3. 不要把 framing 细节泄漏到上层 API。

#### 5.2.2 `ACPConnection`

职责：

1. 管理 request id。
2. 管理 pending request continuation。
3. 分发 response / request / notification。
4. 对外提供 `sendRequest` / `sendNotification`。

这层对应 Python 的 `Connection`。

#### 5.2.3 `ACPMessageRouter`

职责：

1. 维护 method 到 handler 的映射。
2. 区分 request 与 notification。
3. 处理扩展方法 `_xxx`。
4. 将 JSON params 解码为具体 Swift model。

这层对应 Python 的 `MessageRouter`。

#### 5.2.4 `ACPClientHandler`

职责：

1. 定义 Swift 侧要实现的 Client callbacks。
2. 将 ACP 入站方法映射到 app 内部能力。
3. 隔离协议层与业务层。

建议设计成 protocol：

```swift
protocol ACPClientHandler: AnyObject {
    func sessionUpdate(_ request: ACPSessionNotification) async
    func requestPermission(_ request: ACPRequestPermissionRequest) async throws -> ACPRequestPermissionResponse
    func readTextFile(_ request: ACPReadTextFileRequest) async throws -> ACPReadTextFileResponse
    func writeTextFile(_ request: ACPWriteTextFileRequest) async throws -> ACPWriteTextFileResponse?
    func createTerminal(_ request: ACPCreateTerminalRequest) async throws -> ACPCreateTerminalResponse?
    func terminalOutput(_ request: ACPTerminalOutputRequest) async throws -> ACPTerminalOutputResponse?
    func waitForTerminalExit(_ request: ACPWaitForTerminalExitRequest) async throws -> ACPWaitForTerminalExitResponse?
    func killTerminal(_ request: ACPKillTerminalCommandRequest) async throws -> ACPKillTerminalCommandResponse?
    func releaseTerminal(_ request: ACPReleaseTerminalRequest) async throws -> ACPReleaseTerminalResponse?
    func extensionMethod(name: String, params: [String: ACPJSONValue]) async throws -> ACPJSONValue
    func extensionNotification(name: String, params: [String: ACPJSONValue]) async
}
```

#### 5.2.5 `ACPClientRuntime`

职责：

1. 提供业务友好的高层 API。
2. 封装 `initialize`、`newSession`、`loadSession`、`prompt`、`cancel`。
3. 管理进程启动、连接生命周期和状态观察。

这层是上层 UI / agent service 真正依赖的入口。

---

## 6. 模型设计建议

### 6.1 第一阶段不要追求全量 schema 生成

Python 版 `schema.py` 是生成文件，覆盖范围很大。Swift 首期如果完全手写，很容易把时间花在模型搬运上。

建议采用“两层模型”策略：

1. Wire 层
   - `ACPRequestMessage`
   - `ACPResponseMessage`
   - `ACPNotificationMessage`
   - `ACPErrorObject`
2. Protocol 层
   - 只实现 MVP 所需 request/response/update model

### 6.2 JSON 表达建议

建议定义一个统一 JSON 值类型，避免 `[String: Any]` 在整个协议层蔓延：

```swift
enum ACPJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ACPJSONValue])
    case array([ACPJSONValue])
    case null
}
```

这样可以更稳定地支持：

1. `_meta`
2. 扩展方法
3. 未覆盖字段透传

### 6.3 编码策略

Python 端大量使用 camelCase alias，例如：

1. `session_id -> sessionId`
2. `client_capabilities -> clientCapabilities`
3. `_meta` 保持原样

Swift 模型建议：

1. 内部属性用 Swift 风格命名。
2. 用 `CodingKeys` 显式维护 ACP field name。
3. 对可选返回的“空对象”与 `null` 做专门适配。

这里要特别注意 Python 的 `normalize_result` 行为：

1. 某些 optional response 在 Python 中会把 `None` 转成 `{}`。
2. Swift 解码不能只接受 `null`，也要能接受空对象。

---

## 7. 并发与生命周期设计

### 7.1 actor 化原则

ACP 连接层建议整体 actor 化，至少保证以下状态不被并发破坏：

1. `nextRequestID`
2. `pendingRequests`
3. `isClosed`
4. 写流顺序

建议：

1. `ACPConnection` 用 `actor`。
2. `ACPTransport` 也可用 `actor`，或内部单独持有串行发送任务。

### 7.2 读写分离

建议保持与 Python 同样的抽象边界：

1. 读循环持续读取帧并交给连接层。
2. 写循环专门负责串行 flush。
3. 入站 request / notification 不阻塞读循环。

Swift 上的落地方式可以是：

1. `Task` 跑 read loop。
2. 单独 `Task` 跑 send loop。
3. 对每个入站 request 开子任务处理，但结果仍通过连接层统一回写。

### 7.3 关闭语义

需要与 Python 保持一致：

1. close 后拒绝新的 outgoing request。
2. 所有 pending continuation 统一 fail。
3. 读写任务被取消。
4. 进程有 graceful shutdown，再 escalate terminate / kill。

这里可直接借鉴 [agentGui/Services/LSP/LSPProcessSupervisor.swift](agentGui/Services/LSP/LSPProcessSupervisor.swift) 的进程收尾经验。

---

## 8. 分阶段实施计划

### 8.1 Phase 0: 代码位整理

目标：清理命名冲突，给 ACP 模块腾出稳定落位。

任务：

1. 处理 [agentGui/Services/ACPClientService.swift](agentGui/Services/ACPClientService.swift) 的错误命名。
2. 新建 `Services/ACP/` 目录。
3. 约定 ACP 模块与 Claude / LSP / Terminal 的依赖边界。

产出：

1. 干净的 ACP 目录结构。
2. 不再混淆的文件命名。

### 8.2 Phase 1: 最小传输与连接层

目标：能向 ACP Agent 建立稳定连接并发 request。

任务：

1. 实现 newline JSON frame reader / writer。
2. 实现 `ACPConnection.sendRequest` / `sendNotification`。
3. 实现 response 对 pending continuation 的回填。
4. 实现 `ACPRequestError`。
5. 加入 raw stream observer 便于调试。

验收：

1. 能完成 `initialize` request/response。
2. 非法 JSON、无效响应、连接关闭能正确报错。

### 8.3 Phase 2: 路由与 Client callback 层

目标：支持 Agent 反向调用 Swift Client。

任务：

1. 实现 method catalog。
2. 实现 request / notification router。
3. 接入 `session/update`。
4. 接入 permission / fs / terminal callbacks。
5. 支持 `_xxx` 扩展方法。

验收：

1. Agent 发来的 request 能正确解码、执行业务 handler、返回 result。
2. 未注册方法返回 method not found。
3. 参数不合法返回 invalid params。

### 8.4 Phase 3: 高层 ACP Client Runtime

目标：形成业务可直接调用的 Swift API。

任务：

1. 封装 `initialize`。
2. 封装 `newSession` / `loadSession`。
3. 封装 `prompt` / `cancel`。
4. 加入状态机：`idle / starting / connected / closed / failed`。
5. 加入日志与观测接口。

验收：

1. 上层代码不需要直接操作 JSON-RPC message。
2. 一次完整 prompt 能收到持续 `session/update`。

### 8.5 Phase 4: 与 agentGui 业务能力桥接

目标：把 ACP Client callbacks 接到现有业务能力。

任务：

1. `session/update` 映射到本地消息与工具调用投影。
2. `fs/*` 对接现有文件编辑 / 读取能力。
3. `terminal/*` 对接现有 Terminal runtime。
4. `request_permission` 对接现有授权策略。

验收：

1. ACP Agent 能通过 Swift Client 使用本地文件和终端能力。
2. UI 能看到流式 session 更新。

### 8.6 Phase 5: 扩展能力与硬化

目标：补齐不稳定方法、容错和兼容层。

任务：

1. 补 `session/list`、`session/fork`、`session/resume`、`session/set_model`。
2. 支持 `useUnstableProtocol` 开关。
3. 加入超时、重连、崩溃恢复。
4. 评估 schema 代码生成是否值得引入。

验收：

1. 方法覆盖率提升。
2. 边界错误更可诊断。
3. 对不同 ACP Agent 实现具有基本兼容性。

---

## 9. 测试计划

### 9.1 单元测试

至少覆盖：

1. newline frame 切包 / 粘包解析。
2. request id 匹配。
3. response 成功 / 错误回填。
4. request / notification 路由。
5. invalid params / method not found / internal error 编码。
6. close 后 pending request 失败。

### 9.2 集成测试

建议用一个最小 fake ACP Agent 进程做端到端验证：

1. `initialize -> newSession -> prompt`
2. Agent 反向发 `session/update`
3. Agent 反向请求 `fs/read_text_file`
4. Agent 反向请求 `terminal/create`
5. 取消与关闭

### 9.3 回归测试重点

重点盯以下风险：

1. 大消息跨多次 stdout 回调时的 frame 拼接。
2. 并发 request 时 continuation 串号。
3. 关闭期间 response 晚到导致的状态竞争。
4. 空对象 `{}` 与 `null` 返回差异。

---

## 10. 风险与关键决策点

### 10.1 最大技术风险

最大风险不是 JSON-RPC 本身，而是 **双向回调与本地业务能力桥接的边界**：

1. ACP protocol layer 应保持纯净。
2. 文件系统、终端、权限、UI 投影都应通过 handler 注入，不要直接耦合在连接层里。

### 10.2 第二个风险：过早追求 schema 全量化

如果一开始就试图把 `schema.py` 全量搬到 Swift，会出现两个问题：

1. 首批交付时间被模型定义吞掉。
2. 业务主链路迟迟跑不起来。

更合理的路径是：

1. 先保证运行时可用。
2. 再逐步补模型完整度。
3. 最后再决定要不要生成化。

### 10.3 一个明确的架构决策

建议现在就定下来：

1. ACP 不复用 LSP transport。
2. ACP 只复用 Process 管理经验。
3. ACP 单独建立自己的 wire/runtime/model 三层。

这是为了避免后续出现“同样都叫 JSON-RPC 就硬揉成一个抽象”的错误设计。

---

## 11. 推荐的首个编码切入点

如果下一步开始真正写 Swift 实现，建议顺序如下：

1. 先修正 [agentGui/Services/ACPClientService.swift](agentGui/Services/ACPClientService.swift) 的命名占位问题。
2. 实现 `ACPRequestError`、wire message、newline transport。
3. 实现 `ACPConnection` 和 pending request 管理。
4. 打通 `initialize` + `session/new` + `session/prompt`。
5. 再接 `session/update` 和 `request_permission`。

这个顺序的原因是：

1. 它最早能得到真实端到端反馈。
2. 它最容易暴露 framing、生命周期、错误编码问题。
3. 它能最早验证 Swift 端双向协议设计是否成立。

---

## 12. 最终建议

这件事不应被表述成“把 Python `AgentClientProtocol` 翻译成 Swift”；更准确的工程目标应该是：

**在 agentGui 中实现一个与 ACP Python SDK 语义兼容的 Swift 原生 ACP Client Runtime。**

按当前源码分析，最稳妥的执行路径是：

1. 先以 MVP 跑通稳定主链路。
2. 用 actor 化连接层保证并发安全。
3. 把协议层与业务 handler 严格分离。
4. 再逐步补全 schema 与不稳定方法。

这样做既能快速验证可行性，也能避免后续被一次性大而全的协议搬运拖死。