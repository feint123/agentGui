# agentGui 大模型网络网关模块化架构设计

日期：2026-03-19

## 1. 文档目的

本文档用于解决当前 agentGui 在大模型访问层上的几个根问题：

1. 网络访问层没有统一抽象，当前主链基本绑定在 Anthropic / SwiftAnthropic。
2. 缺少统一日志监控与可观测性，难以定位请求失败、限流、超时、重试与性能瓶颈。
3. 缺少并发控制，多个会话、后台任务、工作流、子代理同时发起请求时没有全局治理。
4. 缺少可靠失败重试与熔断机制，当前错误更多是直接冒泡到上层。
5. 缺少 provider 扩展层，后续接 OpenAI、OpenRouter、Ollama、Gemini、Azure OpenAI 等时会继续复制 Claude 接入方式。

目标不是仅仅把 `ClaudeService` 再包一层，而是引入一个真正可扩展、可观测、可治理的“模型网关层”，让 UI、Agent Loop、Workflow、Background Task 依赖稳定内部协议，而不是依赖某一家 SDK 的具体类型。

## 2. 当前现状与问题归纳

结合现有代码，可以确认当前结构有以下特征：

1. 设置模型与连接信息主要围绕 `AppSettings.apiKey`、`baseURL`、`selectedModel` 展开，产品语义仍然是单一 Anthropic 主链。
2. `ClaudeService` 内部直接持有 `any AnthropicService`，并作为消息、Agent Loop、Background Task、Workflow 等链路的服务入口。
3. `ConfigurableHTTPClient` 只解决了 URLSession + proxy 组装问题，没有承载日志、限流、重试、观测、熔断等横切能力。
4. `ConnectionValidationService` 只有非常轻量的连通性探测，不具备 provider 级认证校验、能力发现、速率限制探测和错误分类。
5. 当前“支持更多模型 API”的方式，本质上只能继续往设置页和业务层添加 provider 特判，长期会导致 `ClaudeService` 继续膨胀。

这意味着现阶段最大问题不是“缺某个 SDK”，而是缺一个稳定的中间架构。

## 3. 设计目标

新方案应满足以下目标：

1. 上层业务只依赖统一的模型网关协议，不直接依赖 Anthropic SDK 类型。
2. Provider 接入增量成本局部化，新增一家模型厂商不需要改动消息主链核心逻辑。
3. 所有请求经过统一中间管线，统一承载日志、指标、trace、并发控制、重试、熔断、限流与审计。
4. 同时支持普通请求与流式请求，不能因为抽象层升级破坏当前流式 UI 和 Agent Loop。
5. 支持按 provider、model、workspace、session、task lane 做资源治理。
6. 支持逐步迁移，不要求一次性替换现有 `ClaudeService` 主链。

非目标：

1. 不在第一阶段追求统一所有厂商所有高级能力的最小公倍数。
2. 不要求马上替换现有业务层的全部 Anthropic 语义。
3. 不把模型网关做成外部微服务，当前仍以本地 macOS App 内部模块为主。

## 4. 总体设计思路

建议新增一个四层结构：

1. Capability Layer：统一抽象“聊天 / 流式聊天 / embeddings / token count / files / tools”等模型能力。
2. Provider Layer：每家厂商一个 adapter，把厂商 SDK / HTTP API 适配到统一能力协议。
3. Gateway Pipeline Layer：统一中间件链，承载日志、指标、并发、重试、熔断、限流、鉴权、审计。
4. Application Facade Layer：给 `ClaudeService`、Workflow、Background、RMS 等上层提供稳定入口。

核心判断：

最适合这里的不是单一设计模式，而是“Facade + Adapter + Strategy + Decorator / Interceptor + Factory + Policy Object”的组合。

## 5. 推荐模块划分

建议新增以下核心模块。

### 5.1 Gateway Public API

对上层暴露统一协议：

```swift
protocol LLMGateway: Sendable {
    func execute(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMStreamEvent, Error>
    func countTokens(_ request: LLMTokenCountRequest) async throws -> LLMTokenCountResponse
    func listModels(query: ModelCatalogQuery) async throws -> [LLMModelDescriptor]
}
```

这里的关键点是：

1. 上层依赖 `LLMGateway`，而不是 `AnthropicService`。
2. 请求与响应使用内部模型 `LLMRequest` / `LLMResponse`，不直接泄漏厂商 SDK 类型。
3. `stream(_:)` 必须是一等公民，因为当前产品大量依赖流式消息。

### 5.2 Provider Registry

负责 provider 注册、发现、实例化：

```swift
protocol LLMProviderFactory: Sendable {
    var providerID: LLMProviderID { get }
    func makeProvider(configuration: LLMProviderConfiguration) throws -> any LLMProvider
}

protocol LLMProvider: Sendable {
    var descriptor: LLMProviderDescriptor { get }
    func supports(_ capability: LLMCapability) -> Bool
    func execute(_ request: ProviderRequestContext) async throws -> ProviderResponseContext
    func stream(_ request: ProviderRequestContext) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error>
    func countTokens(_ request: ProviderTokenCountContext) async throws -> ProviderTokenCountResult
}
```

职责：

1. 让 Anthropic、OpenAI、OpenRouter、Ollama、Gemini 以插件式注册。
2. 让 provider 自己声明支持的能力与模型目录。
3. 让上层网关按 provider ID + model routing policy 做动态路由。

### 5.3 Gateway Pipeline

所有请求统一走一条 pipeline：

```swift
protocol LLMGatewayMiddleware: Sendable {
    func handle(
        _ request: GatewayRequestContext,
        next: @escaping @Sendable (GatewayRequestContext) async throws -> GatewayResponseContext
    ) async throws -> GatewayResponseContext
}
```

推荐默认中间件顺序：

1. `RequestNormalizationMiddleware`
2. `CredentialResolutionMiddleware`
3. `RoutingMiddleware`
4. `RateLimitAdmissionMiddleware`
5. `ConcurrencyControlMiddleware`
6. `ObservabilityMiddleware`
7. `RetryMiddleware`
8. `CircuitBreakerMiddleware`
9. `ProviderExecutionMiddleware`
10. `ResponseNormalizationMiddleware`

其中流式请求需要复用同一套治理逻辑，但 `RetryMiddleware` 只允许在“尚未产生首个有效流事件前”自动重试，避免流式内容重复注入 UI。

### 5.4 Observability Center

建议拆出独立可观测性中心，而不是把日志散落在 service 内：

```swift
protocol LLMGatewayTelemetrySink: Sendable {
    func emit(_ event: LLMGatewayTelemetryEvent)
}
```

至少输出三类数据：

1. 结构化日志：请求开始、结束、失败、重试、熔断、限流、降级。
2. 指标：QPS、P95 延迟、首 token 延迟、重试率、provider 错误率、并发占用、超时率。
3. Trace 字段：`requestID`、`sessionID`、`workflowID`、`roundID`、`providerID`、`modelID`、`taskLane`。

### 5.5 Reliability Control Center

统一承载：

1. 并发控制
2. 重试策略
3. 限流
4. 熔断
5. 退避策略
6. 降级策略

这里不要把策略硬编码进 provider，而是抽成 policy object。

## 6. 最适合的设计模式组合

### 6.1 Facade

`LLMGateway` 作为统一门面，屏蔽 provider 差异。

适用原因：

1. 当前上层调用方很多，已经不适合让它们分别理解不同厂商 SDK。
2. 可以把复杂的治理逻辑统一收敛到一个入口。

### 6.2 Adapter

每个 provider 通过 adapter 适配到内部协议。

例如：

1. `AnthropicProviderAdapter`
2. `OpenAIProviderAdapter`
3. `OpenRouterProviderAdapter`
4. `OllamaProviderAdapter`

适用原因：

1. 各家 SDK / HTTP 字段差异明显。
2. 流式协议可能是 SSE、chunked JSON、WebSocket，不应该泄漏给上层。

### 6.3 Strategy

以下策略必须可插拔：

1. 路由策略 `RoutingStrategy`
2. 重试策略 `RetryStrategy`
3. 并发配额策略 `ConcurrencyPolicy`
4. 熔断策略 `CircuitBreakerPolicy`
5. 限流策略 `RateLimitPolicy`

适用原因：

1. 不同 provider、不同模型、不同任务 lane 的可靠性策略不同。
2. 后台任务和前台交互的超时、重试、并发阈值也不同。

### 6.4 Decorator / Interceptor

中间件链最适合用 decorator 或 interceptor 模式实现。

适用原因：

1. 日志、指标、重试、熔断都是典型横切关注点。
2. 后续加缓存、审计、红线策略时可以继续沿用同一机制。

### 6.5 Abstract Factory

`ProviderFactory` 和 `GatewayFactory` 负责按配置生成 provider、policy、middleware pipeline。

适用原因：

1. 设置项会变复杂，不能把对象拼装逻辑散落在 App 根节点。
2. 方便测试注入 fake provider、fake limiter、fake telemetry sink。

### 6.6 Bulkhead + Circuit Breaker

这两个不是 GoF 经典模式，但对这里非常关键：

1. Bulkhead：不同 provider / lane / session 有隔离配额，防止一个高流量任务拖垮全局。
2. Circuit Breaker：某 provider 持续超时或 5xx 时快速失败，减少雪崩。

## 7. 核心领域模型

### 7.1 统一请求模型

```swift
struct LLMRequest: Sendable {
    let requestID: UUID
    let sessionID: String?
    let workflowID: String?
    let taskLane: LLMTaskLane
    let providerPreference: ProviderPreference
    let modelSelection: ModelSelection
    let messages: [LLMMessage]
    let tools: [LLMToolDefinition]
    let outputMode: LLMOutputMode
    let options: LLMRequestOptions
}
```

其中：

1. `providerPreference` 支持指定 provider、指定 provider 集合、自动路由。
2. `taskLane` 用于区分 `interactive`、`background`、`workflow-subagent`、`verification`。
3. `options` 收纳超时、重试级别、幂等键、预算等元数据。

### 7.2 统一响应模型

```swift
struct LLMResponse: Sendable {
    let requestID: UUID
    let providerID: LLMProviderID
    let modelID: String
    let content: [LLMContentBlock]
    let stopReason: LLMStopReason?
    let usage: LLMUsage
    let rawMetadata: [String: String]
}
```

### 7.3 流式事件模型

```swift
enum LLMStreamEvent: Sendable {
    case responseStarted(LLMResponseHeader)
    case thinkingDelta(String)
    case textDelta(String)
    case toolCallDelta(LLMToolCallDelta)
    case usageDelta(LLMUsageDelta)
    case completed(LLMResponse)
}
```

目标不是覆盖所有 provider 的全部细节，而是覆盖当前产品真正消费的公共语义。

## 8. Provider 层设计

### 8.1 Anthropic Provider

第一阶段建议先把当前 `SwiftAnthropic` 接入包成 `AnthropicProviderAdapter`。

职责：

1. 把 `LLMRequest` 映射为 `MessageParameter`。
2. 把 `MessageResponse` / `MessageStreamResponse` 映射为内部统一模型。
3. 把 Anthropic 特有字段，如 thinking、tool choice、beta header，保留在 provider option 中。

### 8.2 OpenAI / Azure OpenAI Provider

建议将 chat completion / responses API 适配到统一模型。

注意点：

1. tool schema 与 Anthropic 不同。
2. 流式 delta 结构不同。
3. token usage 返回时机不同。

### 8.3 OpenRouter Provider

OpenRouter 更适合作为“兼容 provider”，但也需要独立 adapter。

原因：

1. 虽然很多接口兼容 OpenAI，但模型目录、路由 header、计费与 metadata 不一致。
2. 未来可能承接多模型 fallback。

### 8.4 Ollama Provider

本地模型 provider 应特别考虑：

1. 模型预热时间长。
2. 首 token 延迟不稳定。
3. 并发能力远弱于云端 API。

因此应给 Ollama 独立的并发与重试策略，而不是复用云端默认值。

## 9. 并发控制设计

### 9.1 目标

并发控制不能只靠一个全局 semaphore。需要分层治理：

1. 全局并发上限：保护 App 整体资源。
2. Provider 级上限：保护某个 provider 不被打爆。
3. Model 级上限：高成本模型与低成本模型分开治理。
4. Task lane 级上限：前台交互优先，后台任务让路。
5. Session 级上限：同一会话内避免无穷并发风暴。

### 9.2 推荐实现

建议引入 `ConcurrencyGovernor` actor：

```swift
actor ConcurrencyGovernor {
    func acquire(_ permit: ConcurrencyPermitRequest) async throws -> ConcurrencyLease
}
```

Permit 维度建议包含：

1. `global`
2. `provider:<id>`
3. `model:<provider>/<model>`
4. `lane:<interactive|background|workflow|verification>`
5. `session:<id>`

### 9.3 调度原则

建议默认优先级：

1. `interactive`
2. `verification`
3. `workflow-subagent`
4. `background`

原因：

1. 用户正在看的前台交互最需要首 token 延迟可控。
2. 验证链路往往决定一次任务是否收尾。
3. 后台任务允许等待与排队。

### 9.4 防止饥饿

需要引入简单 aging 机制，避免后台任务在高峰期一直饿死。

## 10. 失败重试设计

### 10.1 错误分类

必须先做错误分类，再决定是否重试：

1. `authenticationFailed`：不重试。
2. `authorizationFailed`：不重试。
3. `invalidRequest`：不重试。
4. `rateLimited`：按 `Retry-After` 或指数退避重试。
5. `serverUnavailable`：有限次重试。
6. `networkTimeout`：有限次重试。
7. `connectionReset`：有限次重试。
8. `streamInterruptedBeforeFirstEvent`：允许重试。
9. `streamInterruptedAfterFirstEvent`：默认不自动重试，由上层决定是否重发。

### 10.2 重试策略

建议默认采用“指数退避 + 抖动”：

$$
delay = min(base \times 2^{attempt-1} + jitter, maxDelay)
$$

建议默认值：

1. 前台交互：最多 2 次自动重试。
2. 后台任务：最多 4 次自动重试。
3. 验证 / 批处理：最多 3 次自动重试。

### 10.3 幂等性

若 provider 支持 `idempotency-key`，应统一写入。

若不支持，也要在本地日志中记录 `requestFingerprint`，至少保证排障时能区分“同一次重试”与“用户重复发送”。

## 11. 熔断与降级设计

### 11.1 熔断状态

每个 provider / model 维护：

1. `closed`
2. `open`
3. `halfOpen`

打开熔断的典型条件：

1. 连续 5 次网络超时
2. 连续 5 次 5xx
3. 最近 30 秒错误率高于阈值且请求数达到最小样本

### 11.2 半开探测

半开阶段只允许少量探测请求通过，防止恢复期间再被压垮。

### 11.3 降级策略

建议支持三类降级：

1. provider fallback：例如 Anthropic 不可用时切 OpenRouter 同模型映射。
2. model fallback：例如从高成本模型切到同 provider 的次级模型。
3. behavior fallback：例如关闭 thinking、缩减 max tokens、禁用非必要工具。

降级必须显式记录到 telemetry 中，不能静默改变用户结果而不可见。

## 12. 日志监控与可观测性设计

### 12.1 结构化日志字段

建议每次请求至少记录：

1. `requestID`
2. `sessionID`
3. `workflowID`
4. `providerID`
5. `modelID`
6. `taskLane`
7. `isStreaming`
8. `attempt`
9. `queueWaitMs`
10. `timeToFirstByteMs`
11. `timeToFirstTokenMs`
12. `totalLatencyMs`
13. `inputTokens`
14. `outputTokens`
15. `stopReason`
16. `failureCategory`
17. `circuitState`
18. `fallbackApplied`

### 12.2 UI 可视化建议

建议在现有 Reliability / Diagnostics 方向上新增模型网关面板，至少支持：

1. 最近请求列表
2. provider 健康状态
3. 熔断状态
4. 当前并发占用
5. 重试统计
6. 最近错误摘要
7. 请求详情 drill-down

### 12.3 敏感信息治理

日志默认不能直接落明文：

1. API Key
2. Authorization header
3. 用户原始 prompt 全文
4. 原始文件内容

推荐做法：

1. header 脱敏
2. prompt 摘要化
3. 可选 debug mode 下仅对本地开发开启原文 capture

## 13. 设置模型与配置演进

当前 `AppSettings` 明显是单 provider 结构，需要升级为 provider-aware 配置。

建议演进为：

```swift
struct LLMGatewaySettings: Codable {
    var defaultRoutingPolicy: RoutingPolicyRecord
    var providers: [ProviderConfigRecord]
    var concurrency: ConcurrencyPolicyRecord
    var retry: RetryPolicyRecord
    var observability: ObservabilityPolicyRecord
}
```

其中 `ProviderConfigRecord` 至少包含：

1. `providerID`
2. `displayName`
3. `isEnabled`
4. `baseURL`
5. `apiKeyRef`
6. `organizationID`
7. `defaultModels`
8. `capabilityToggles`
9. `customHeaders`

### 13.1 设置存储层演进原则

设置层改造需要同时满足两件事：

1. 数据结构必须支持多个 provider、多种能力和多条路由策略。
2. 设置 UI 不能为了支持 provider 扩展而破坏当前设置页已经形成的交互习惯。

因此建议把“数据模型升级”和“UI 信息架构升级”一起设计，而不是只改 `AppSettings` 字段。

### 13.2 设置 UI 的信息架构改造

当前设置页已经有清晰的组织方式：

1. 左侧 `NavigationSplitView` 导航。
2. 右侧 `Form` + `.grouped` 表单。
3. 每个页面通过 `Section` 拆分“当前状态 / 配置输入 / 说明 footer”。

新方案应明确要求继续沿用这套结构，不引入新的复杂管理台式 UI，不改成卡片仪表盘主界面，也不把 provider 配置塞进弹窗堆叠流程。

建议保持现有一级导航不剧烈变化，仍以当前设置窗口的整体骨架为主，只对右侧内容做 provider-aware 升级：

1. `连接` 保留为一级导航，但语义从“Anthropic API 配置”升级为“模型提供商与路由配置”。
2. `工具` 保留为一级导航，但工具可用性说明改为依赖当前 provider capability，而不是默认假设 Claude 主链。
3. `智能` 保留为一级导航，但其中与模型行为相关的选项需要声明“按 provider / model 生效”还是“全局默认策略”。
4. `诊断 / 可靠性` 相关展示继续放在既有产品方向中，不把调试信息混入主连接配置页。

### 13.3 `连接` 页的推荐改造方案

当前 [agentGui/Views/Settings/SettingsConnectionView.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsConnectionView.swift) 的结构是：

1. 启动就绪状态
2. API 配置
3. 代理
4. 模型选择

建议升级为以下分区，但仍保留同样的 `Section` 风格。

#### A. 启动就绪状态

继续保留在页首，且文案从单一 Anthropic 条件改为 provider-aware 条件，例如：

1. 是否至少启用了一个可用 provider。
2. 默认路由是否能解析到有效 provider。
3. 至少一个聊天模型是否可选。
4. 当前代理/网络配置是否可用。

#### B. 默认提供商与路由策略

新增专门分区，不再把“Base URL + API Key + 模型”视为同一层级。

该分区建议包含：

1. 默认路由策略 Picker：`固定提供商` / `按能力自动选择` / `按模型映射`。
2. 默认聊天提供商 Picker。
3. 默认验证 / 后台 / 子代理 lane 的 provider policy。
4. 当主 provider 不可用时的 fallback policy 摘要。

这样可以把“如何选 provider”从“某个 provider 的表单字段”里解耦出来。

#### C. 提供商列表

建议在 `连接` 页中新增“提供商”分区，使用和当前设置页一致的列表式分组视图，而不是打开独立复杂管理页面。

每个 provider row 建议展示：

1. provider 名称与类型，例如 Anthropic、OpenAI、OpenRouter、Ollama。
2. 启用状态。
3. 健康状态摘要：已配置 / 未配置 / 认证失败 / 连接异常 / 熔断中。
4. 默认模型摘要。
5. 一个“展开配置”或进入 detail sheet / push detail 的入口。

这里推荐的交互模式是：

1. 在同一设置窗口内进入 provider detail。
2. 复用现有 `Form`、`Section`、footer 文案风格。
3. 不做网页式多列表管理器，不引入重型表格编辑器。

#### D. Provider Detail 表单

每个 provider 的 detail 页面结构建议统一，避免每新增一个 provider 就发明一套表单。

通用分区建议为：

1. `基本信息`
    - provider 名称
    - 是否启用
    - provider 类型
2. `认证与地址`
    - API Key / token / organization
    - Base URL
    - 自定义 headers
3. `模型默认值`
    - 默认聊天模型
    - 默认推理 / 验证 / embedding 模型
4. `能力开关`
    - chat
    - streaming
    - tools
    - thinking
    - embeddings
    - token count
5. `连接验证`
    - 验证按钮
    - 最近结果
6. `高级设置`
    - timeout policy override
    - retry policy override
    - rate limit override

这样 Anthropic、OpenAI、OpenRouter、Ollama 都能共享一套主表单骨架，只在字段细节上扩展。

#### E. 网络代理

`代理` 分区应保留在 `连接` 页，并继续使用当前表单风格。

但语义需要从“主要服务 Anthropic + Web 工具”升级为：

1. provider 级网络访问共用默认代理策略。
2. 某些 provider 可以声明“继承全局代理”或“自定义代理”。
3. footer 中明确哪些 provider 走全局代理，哪些 provider 支持 provider 自己的 base URL / endpoint routing。

#### F. 模型选择

当前的静态 `Claude 模型` 分区需要替换为 `默认模型` 分区。

推荐拆为：

1. 默认聊天模型
2. 默认长上下文 / 高质量模型
3. 默认低成本模型
4. 默认验证模型

模型来源应来自 provider catalog + model catalog，而不是继续写死在 `AppSettings.availableModels`。

### 13.4 `工具` 页的兼容性改造

当前 [agentGui/Views/Settings/SettingsToolsView.swift](/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsToolsView.swift) 已经有“工具开关 + 权限说明”的结构，这个方向应该保留，但要补 provider capability 感知。

推荐改造：

1. 工具开关仍然放在 `工具` 页，不把工具能力搬到 provider 配置页里，避免用户在多个地方找不到控制项。
2. 每个工具下方增加 provider 兼容性提示，例如：
    - 当前默认 provider 支持 tool use。
    - 当前 fallback provider 不支持 thinking。
    - 当前本地 provider 不支持 web search。
3. `权限与前提说明` 分区继续保留，但要增加“依赖的 provider capability”和“当前路由是否满足”的说明。

这能保证工具页继续承担“用户要不要开这个能力”的职责，而 provider 页承担“这个 provider 本身能不能支持”的职责。

### 13.5 `智能` 页的兼容性改造

`智能` 页中涉及 thinking、模型行为、预算和策略的选项，建议按以下规则改造：

1. 明确哪些是全局默认策略。
2. 明确哪些可被 provider / model override。
3. 明确当前默认 provider 是否支持该能力。

例如 Extended Thinking 不应继续假设“适用 Claude 3.7+”，而应改为：

1. 一个通用的“深度推理偏好”设置。
2. 由 provider adapter 决定映射到 Anthropic thinking、OpenAI reasoning effort，或 provider 不支持时禁用。

### 13.6 UI 风格约束

这部分必须在方案中明确，否则实现时容易演变成一套新旧混杂的设置界面。

设置 UI 改造应遵守以下约束：

1. 保持现有 `SettingsWindowView` 的 `NavigationSplitView` 骨架，不新增第二套设置入口。
2. 保持右侧详情页使用 `Form` + `.grouped` + `Section` 的组织方式。
3. 保持现有“顶部就绪状态 + 中间表单输入 + 底部说明 footer”的信息节奏。
4. 保持当前文案风格：中文、面向功能说明、强调风险与前提，不引入过度工程化术语堆砌。
5. 尽量复用当前输入控件类型：`Toggle`、`TextField`、`SecureField`、`Picker`、`Button`、`Label`。
6. provider 增长后优先采用“统一表单骨架 + provider-specific section”扩展，不为每个 provider 重新设计独立页面风格。
7. 状态反馈继续使用当前风格，例如“已保存 ✓”“验证中...” 和小尺寸状态标签，而不是引入全屏 toast 或复杂 banner 堆叠。

### 13.7 推荐的数据与视图拆分

为了保证模块化和可扩展，设置 UI 也需要分层，而不是继续把所有字段塞进单个 `SettingsConnectionView`。

建议新增：

1. `ProviderConfigurationViewModel`
2. `ProviderCatalogViewModel`
3. `ProviderDetailView`
4. `ProviderRowView`
5. `DefaultRoutingPolicySectionView`
6. `ModelDefaultsSectionView`

拆分原则：

1. provider 列表视图负责展示和选择。
2. provider detail 负责编辑单个 provider 配置。
3. 路由与默认模型作为独立 section，不与某家 provider 的密钥表单耦合。
4. `SettingsStore` 继续作为顶层持久化入口，但 provider 配置读取与写回应有独立的 façade。

### 13.8 分阶段 UI 迁移建议

为了兼容当前实现，设置 UI 不应一次性硬切。

建议按三步走：

1. Phase 1：保留当前 Anthropic 表单，新增 provider-aware 数据结构与隐藏兼容读取层。
2. Phase 2：在 `连接` 页加入 `提供商列表` 和 `默认路由策略`，Anthropic 配置迁移为默认 provider 的 detail 表单。
3. Phase 3：移除“Anthropic API 配置”专有文案，全面切换到 provider-neutral 文案与 catalog 驱动模型选择。

第一阶段不一定要一次性替换 SwiftData 模型，可以先：

1. 保留现有 Anthropic 字段不动。
2. 新增一份 JSON 化 `llmGatewaySettingsJSON`。
3. 由新网关优先读取新结构，Anthropic 旧字段作为兼容导入源。

## 14. 与当前代码的兼容桥接方案

这是落地关键。

当前大量代码依赖 `any AnthropicService`，不适合直接硬切。建议采用三阶段桥接。

### 14.1 Phase 1：引入 Gateway，但不替换业务主语义

动作：

1. 新增 `LLMGateway`、`AnthropicProviderAdapter`、`GatewayFactory`。
2. 新增 `AnthropicServiceBridge`，把 `LLMGateway` 再桥接回 `any AnthropicService` 所需能力。
3. `ClaudeService.configure(...)` 不再直接创建 `AnthropicServiceFactory.service(...)`，而是先构建 Gateway，再从 Gateway 取 bridge。
4. `AppSettings` 新增 provider-aware 存储结构，但设置 UI 仍可暂时显示 Anthropic 专用表单。

收益：

1. 上层几乎不改。
2. 日志、重试、并发、熔断先在 Gateway 层生效。

### 14.2 Phase 2：新增中性 Facade，逐步去 `AnthropicService`

动作：

1. 为 `ClaudeService+Messaging`、`WorkflowAgentRunner`、`BackgroundTaskExecutionCoordinator` 等新增中性调用面。
2. 把 `AnthropicService` 依赖逐渐替换为 `LLMGateway` 或 `LLMChatClient`。
3. `连接` 页加入 provider 列表、默认路由策略和统一 provider detail 表单。
4. `工具` / `智能` 页补齐 provider capability 感知。

### 14.3 Phase 3：业务层正式 provider-neutral

动作：

1. 设置 UI 从“Anthropic API 配置”升级为“模型提供商配置”。
2. 模型选择从静态枚举升级为 provider catalog + model catalog。
3. 后台任务、workflow、verifier 可以按 lane 指定 provider routing。
4. 设置页整体文案、校验、连接测试和就绪状态全部切换到 provider-neutral 语义。

## 15. 推荐目录结构

建议新增目录：

```text
agentGui/Services/LLMGateway/
    Gateway/
        LLMGateway.swift
        DefaultLLMGateway.swift
        GatewayFactory.swift
        GatewayRequestContext.swift
        GatewayResponseContext.swift
    Providers/
        LLMProvider.swift
        LLMProviderFactory.swift
        LLMProviderRegistry.swift
        Anthropic/
            AnthropicProviderAdapter.swift
            AnthropicRequestMapper.swift
            AnthropicResponseMapper.swift
        OpenAI/
        OpenRouter/
        Ollama/
    Middleware/
        LLMGatewayMiddleware.swift
        ObservabilityMiddleware.swift
        RetryMiddleware.swift
        ConcurrencyControlMiddleware.swift
        CircuitBreakerMiddleware.swift
        RoutingMiddleware.swift
        ResponseNormalizationMiddleware.swift
    Reliability/
        ConcurrencyGovernor.swift
        RetryStrategy.swift
        CircuitBreaker.swift
        RateLimiter.swift
    Telemetry/
        LLMGatewayTelemetryEvent.swift
        LLMGatewayTelemetrySink.swift
        LLMGatewayMetricsStore.swift
    Models/
        LLMRequest.swift
        LLMResponse.swift
        LLMStreamEvent.swift
        LLMModelDescriptor.swift
        LLMProviderDescriptor.swift
    Bridges/
        AnthropicServiceBridge.swift
```

## 16. 推荐接口边界

### 16.1 业务层应该依赖什么

建议收敛成两层：

1. 复杂业务层直接依赖 `LLMGateway`
2. 更轻量的消息类业务可依赖 `LLMChatClient`

```swift
protocol LLMChatClient: Sendable {
    func send(_ request: LLMChatRequest) async throws -> LLMChatResponse
    func stream(_ request: LLMChatRequest) async throws -> AsyncThrowingStream<LLMChatStreamEvent, Error>
}
```

这样可以减少业务层直接接触较重的网关上下文对象。

### 16.2 Provider 层不该知道什么

provider adapter 不应知道：

1. SwiftData session 模型
2. Chat UI 状态
3. Workflow 编排状态机
4. 后台任务调度策略

provider 只关心“如何调用厂商 API，并把结果映射回来”。

## 17. 测试策略

### 17.1 单元测试

至少覆盖：

1. request / response mapper
2. retry decision
3. circuit breaker state transition
4. concurrency governor permit 分配
5. routing strategy
6. telemetry event 产出

### 17.2 集成测试

至少覆盖：

1. provider fake 下的普通请求
2. provider fake 下的流式请求
3. 首 token 前失败自动重试
4. 首 token 后中断不自动重试
5. provider 熔断后快速失败
6. fallback provider 生效

### 17.3 回归测试

重点回归当前主链：

1. Chat 流式消息
2. Agent Loop round execution
3. Workflow runner
4. Background task execution
5. Connection validation

## 18. 实施优先级建议

### P0

1. 引入 `LLMGateway` 抽象与 `AnthropicProviderAdapter`
2. 引入统一 telemetry 事件模型
3. 引入并发控制 actor
4. 引入错误分类与重试策略
5. 引入 circuit breaker
6. 用 bridge 方式接入现有 `ClaudeService`

### P1

1. 增加 OpenAI / OpenRouter provider
2. 设置页升级为 provider-aware 配置
3. 诊断中心新增模型网关状态面板
4. 加入 fallback routing
5. 保持现有设置页视觉风格下完成 provider 列表、provider detail 和 capability-aware 提示改造

### P2

1. 加入 Ollama 独立策略治理
2. 支持 model catalog 动态拉取
3. 支持更细粒度预算治理与成本统计
4. 支持请求回放与匿名审计样本

## 19. 最终建议

结论很明确：

当前最需要的不是继续堆新模型入口，而是先建立一个真正的模型网关层。

最合适的总体方案是：

1. 用 `Facade` 给上层提供统一入口。
2. 用 `Adapter` 封装不同 provider。
3. 用 `Strategy` 管理路由、重试、限流、并发与熔断策略。
4. 用 `Middleware / Decorator` 承载日志监控与横切治理。
5. 用 `Factory` 管理对象组装与配置注入。
6. 用 `Bulkhead + Circuit Breaker` 保证多任务场景下的稳定性。

如果只从工程收益看，最优落地路径不是“重写 ClaudeService”，而是“先让 ClaudeService 跑在 Gateway 上”。

这样可以在不大面积破坏现有业务层的前提下，把日志监控、并发控制、失败重试、provider 扩展能力一次性纳入统一底座，并为后续多模型接入打下稳定结构。