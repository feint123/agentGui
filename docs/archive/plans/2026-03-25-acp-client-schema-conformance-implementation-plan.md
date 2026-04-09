# ACP Client Schema Conformance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 按照 ACP 官方 schema 与协议章节，对当前 ACP client 实现做逐项对照和干净重构，移除非标准核心接口，补齐 typed schema、capability gating、session update、terminal 与 extensibility 语义，使 ACP core 只表达官方协议，provider 特有行为全部降到扩展层。

**Architecture:** 这次改造分成两层。第一层是“协议核心收口”：`agentGui/Services/ACP` 里的方法目录、请求/响应模型、wire/runtime/router 只能包含官方 ACP schema 中定义的标准 surface，以及 `_` 前缀的通用扩展机制，不再把 provider 私有方法伪装成标准 ACP。第二层是“provider 适配分层”：OpenCode、GitHub Copilot、Claude Adapter 等 provider 的非标准能力通过显式扩展适配器和 capability 广告来接入，feature projection、permission、tool normalization 只消费 typed ACP model。

**Tech Stack:** Swift 6, Foundation Codable, Swift Testing, 现有 ACP runtime stack (`ACPTransport`, `ACPConnection`, `ACPClientRuntime`, `ACPExternalAgentRuntimeClient`, `ACPExternalExecutionProviderBase`), terminal runtime (`TerminalTaskRuntime`), SwiftData 持久化绑定。

---

## 0. Design Constraints

- 我正在使用 writing-plans skill 来创建这份 implementation plan。
- 严格按 @test-driven-development 执行：先补 conformance 测试，再做最小实现，再跑 focused tests。
- 官方真相源只有以下文档：
  - `https://agentclientprotocol.com/protocol/`
  - `https://agentclientprotocol.com/protocol/schema`
  - `initialization`, `session-setup`, `prompt-turn`, `content`, `tool-calls`, `terminals`, `extensibility` 各章节。
- 不考虑 legacy 和迁移。凡是不在官方 schema 的核心方法或字段，一律从 ACP core 删除或下沉到显式扩展层；不做兼容桥，不保留“双轨实现”。
- provider-specific 行为必须满足两条规则：
  1. 方法名必须以下划线 `_` 开头，符合 ACP extensibility 规范。
  2. 能力必须通过 capability `_meta` 或 provider adapter 显式广告，不能从标准 capability 字段做宽泛推断。
- ACP core 必须保持 typed：`ACPJSONValue` 只能用于 `_meta`、原始扩展载荷和真正开放的 JSON 字段，不能继续作为标准 schema 的主表达方式。
- 本期优先修正协议语义，不顺手做 UI 美化或 unrelated runtime 重构。
- 完成所有任务后，使用 @requesting-code-review 做最终 review，重点检查协议收口是否彻底、是否仍有 provider 私有字段泄漏到 ACP core。

## 1. Official Protocol Comparison

下面是按官方协议章节逐项对照后的当前差异摘要。这一节既是实施范围，也是后续测试矩阵。

| 官方章节 / 条目 | 官方要求 | 当前实现状态 | 计划动作 |
| --- | --- | --- | --- |
| Overview / JSON-RPC | 仅区分 request / notification / response；标准错误对象；通知无响应 | `ACPWireMessage` 与 `ACPConnection` 基本符合 | 保留现有 wire 架构，补 conformance tests，重点验证 error shape 与 extension method 行为 |
| Overview / Argument requirements | 所有 path 必须是绝对路径；line number 1-based | `ACPLocalClientHandler` 已校验绝对路径，但行号语义和相关 typed location/diff 尚未统一 | 统一 path/line 语义到 typed model 与 handler tests |
| Initialization | capability omitted = unsupported；client/agent info SHOULD 提供 | `initialize` 基本存在，但 `mcpCapabilities`、`sessionCapabilities` 仍是 `ACPJSONValue` | 将 capability 全部 typed 化，去掉宽泛推断 |
| Session Setup | `session/new`、`session/load` 标准；`loadSession` 必须先 capability gate | `session/load` 已 gate，但 core 仍存在 `session/fork`、`session/resume` | 从 core 删除非标准方法；保留纯标准 session lifecycle |
| Prompt Turn | `session/prompt` / `session/update` / `session/cancel` 生命周期明确；取消后仍要接受最终 update | 基本流程存在，但 update 变体不完整，取消与 feature 流仍混合 | 补齐 typed `SessionUpdate` 全量变体，校正 cancel/permission/test coverage |
| Content | baseline 支持 `text`、`resource_link`；可选 `image`、`audio`、`resource` | 当前 prompt/content 仅部分 typed，`image`/`audio` 缺失 | 补齐 content union typed model 与 prompt capability gate |
| Tool Calls | `kind`、`status`、`content`、`locations` 有标准 union/enum | 当前大量字段仍是 `String` / `ACPJSONValue` | 改成 typed enum/union，并保留 unknown extension 容器 |
| Session Updates | 包含 `plan`、`available_commands_update`、`current_mode_update`、`config_option_update`、`session_info_update` 等 | 当前只有部分 typed，后三类仍落入 `.other` | 补齐 typed update，并调整 normalizer / feature extractor |
| File System | `fs/read_text_file`、`fs/write_text_file` 为 client optional methods | handler 已实现 | 补 tests 验证 line/limit、绝对路径和错误码语义 |
| Terminals | `terminal/create` 使用结构化 `command`、`args`、`env`；`outputByteLimit` 按字符边界截断；`release` 生命周期明确 | 当前把 command/args/env 拼成 shell 字符串交给 `TerminalTaskRuntime.startDetached(command:)`，协议语义不干净 | 改为结构化 terminal launch path，避免 shell 拼接破坏协议语义 |
| Extensibility | 只有 `_meta` 可附加扩展数据；自定义方法必须 `_` 前缀 | 当前 `session/set_model` 直接挂在标准方法目录；`models` 字段也混入标准响应 | 从 ACP core 删除非标准字段/方法；provider 扩展显式下沉到 `_vendor/...` adapter |

## 2. Verified Current Non-Conformances

以下问题已经通过代码阅读确认，属于这次计划的硬范围：

1. `ACPMethodCatalog.Agent` 仍包含非官方 schema 方法：`session/fork`、`session/resume`、`session/set_model`。
2. `ACPClientRuntime` 公开了这些非标准方法，导致 ACP core API 已经和官方 surface 脱节。
3. `ACPModels.swift` 中多个标准 schema 仍用 `ACPJSONValue` 擦除：`mcpCapabilities`、`sessionCapabilities`、`configOptions`、`modes`、tool call payload、tool locations 等。
4. `ACPNewSessionResponse` / `ACPLoadSessionResponse` / `ACPForkSessionResponse` / `ACPResumeSessionResponse` 混入 `models` 这类非标准字段，不符合官方 schema 的 response shape。
5. `ACPSessionUpdate` 还没有 typed 覆盖 `current_mode_update`、`config_option_update`、`session_info_update`。
6. `ACPExternalAgentRuntimeClient` 用 `response.agentCapabilities?.sessionCapabilities != nil` 推断 `supportsSessionModelOverride`，这是把标准 capability 误当成 provider 私有能力。
7. `ACPLocalClientHandler.handleCreateTerminal` 将 `command`、`args`、`env` 拼成 shell 字符串，破坏 ACP terminal/create 的结构化请求语义，并引入 shell escaping 偏差。
8. provider 测试与 runtime 仍把 `session/set_model` 当成标准 ACP 方法，而不是 extension request。

## 3. Target File Inventory

### Create

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSchemaExtensions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderExtensionMethod.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProtocolConformanceTests.swift`

### Modify

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPMethodCatalog.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPClientRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPClientHandler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPLocalClientHandler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPWireMessageTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPClientHandlerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPLocalClientHandlerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

### Delete (No Legacy Cleanup)

- 从 `ACPMethodCatalog.Agent` 删除 `sessionFork`、`sessionResume`、`sessionSetModel`
- 从 `ACPClientRuntime` 删除 `forkSession(...)`、`resumeSession(...)`、`setSessionModel(...)`
- 从 `ACPModels.swift` 删除以标准 response 形式暴露的 `ACPForkSession*`、`ACPResumeSession*`，以及标准 schema 上不存在的 `models` 字段

## 4. Verification Commands

优先使用 focused `xcodebuild test`；如果本地再次被 UITest target 签名噪声干扰，退回 `build-for-testing` 验证编译健康。

### Focused conformance suite

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-acp-schema-conformance \
  -only-testing:agentGuiTests/ACPProtocolConformanceTests \
  -only-testing:agentGuiTests/ACPModelTests \
  -only-testing:agentGuiTests/ACPWireMessageTests \
  -only-testing:agentGuiTests/ACPClientHandlerTests \
  -only-testing:agentGuiTests/ACPLocalClientHandlerTests \
  -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests \
  -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: 所有 ACP schema conformance、terminal/file-system、provider extension tests 通过。

### Compile-health fallback

```bash
xcodebuild build-for-testing \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-acp-schema-build \
  CODE_SIGNING_ALLOWED=NO
```

Expected: app target 与 unit-test target 编译通过；若 UITest 签名噪声存在，仅记录为环境问题。

## 5. Target Protocol Shapes

目标状态下，ACP core 里的标准协议类型要尽量接近 schema，而不是继续依赖 `ACPJSONValue` 大面积擦除。

```swift
struct ACPMcpCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var http: Bool?
    var sse: Bool?
}

struct ACPSessionCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var list: ACPSessionListCapabilities?
}

enum ACPToolKind: String, Codable, Equatable, Sendable {
    case read, edit, delete, move, search, execute, think, fetch, switchMode = "switch_mode", other
}

enum ACPToolCallStatus: String, Codable, Equatable, Sendable {
    case pending, inProgress = "in_progress", completed, failed
}
```

provider 私有扩展不再挂进 `ACPMethodCatalog.Agent`，而是走单独 adapter：

```swift
struct ACPProviderExtensionMethod: Equatable, Sendable {
    let method: String

    init(_ method: String) {
        precondition(method.hasPrefix("_"), "ACP extension methods must start with underscore")
        self.method = method
    }
}
```

## 6. Task Breakdown

### Task 1: 建立“官方 schema 才是 ACP core”的失败测试

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProtocolConformanceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPWireMessageTests.swift`

**Step 1: Write the failing test**

写 conformance tests 覆盖以下断言：

- `ACPMethodCatalog.Agent` 只包含官方标准方法：`authenticate`、`initialize`、`session/cancel`、`session/list`、`session/load`、`session/new`、`session/prompt`、`session/set_config_option`、`session/set_mode`
- 扩展方法必须以下划线 `_` 开头
- `ACPNewSessionResponse` / `ACPLoadSessionResponse` 不能再解码非标准根字段为标准模型
- 标准 capability model 可解码 `mcpCapabilities`、`sessionCapabilities.list`

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task1 -only-testing:agentGuiTests/ACPProtocolConformanceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前 core 仍暴露 `session/fork`、`session/resume`、`session/set_model` 且模型仍混有非标准字段。

**Step 3: Write minimal implementation**

- 新增 `ACPProtocolConformanceTests`
- 在测试里直接钉死官方 method 名单，避免后续再次把 provider 私有方法塞回 core
- 为 extension method 建立前缀断言 helper

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGuiTests/ACPProtocolConformanceTests.swift agentGuiTests/ACPModelTests.swift agentGuiTests/ACPWireMessageTests.swift
git commit -m "test: lock acp core to official schema"
```

### Task 2: 删除非标准 ACP core surface，建立 extension adapter 边界

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderExtensionMethod.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPMethodCatalog.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPClientRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

补测试断言：

- `ACPClientRuntime` 不再提供 `forkSession` / `resumeSession` / `setSessionModel`
- provider 模型切换必须通过 extension request 发送，比如 `_opencode/session/set_model`
- 如果 provider 没有广告对应扩展能力，client 直接视为 unsupported，而不是推断支持

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task2 -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前实现仍调用标准方法 `session/set_model`。

**Step 3: Write minimal implementation**

- 从 `ACPMethodCatalog.Agent` 删除三个非标准方法常量
- 从 `ACPClientRuntime` 删除对应公开 API
- 新建 `ACPProviderExtensionMethod`，作为 provider adapter 的唯一扩展方法入口
- 在 provider descriptor / adapter 中声明扩展方法名，强制 `_` 前缀
- `ACPExternalAgentRuntimeClient` 改为通过 `sendExtensionRequest(...)` 发送 provider-specific model override

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS，日志与 fixture 不再出现裸 `session/set_model`。

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPMethodCatalog.swift agentGui/Services/ACP/ACPClientRuntime.swift agentGui/Services/ACP/ACPProviderExtensionMethod.swift agentGui/Services/ACP/ACPExternalProviderContracts.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift
git commit -m "refactor: move provider methods out of acp core"
```

### Task 3: 将标准 schema 全量 typed 化

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSchemaExtensions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPModelTests.swift`

**Step 1: Write the failing test**

补模型测试覆盖：

- `ACPAgentCapabilities` 正确解码 `mcpCapabilities.http/sse`、`sessionCapabilities.list`
- `ACPPromptContentBlock` 支持 `text`、`resource_link`、`resource`、`image`、`audio`
- `ACPToolCall` / `ACPToolCallUpdatePayload` 用 typed `kind`、`status`、`content`、`locations`
- `ACPNewSessionResponse` / `ACPLoadSessionResponse` 只保留标准字段：`sessionId`、`configOptions`、`modes`

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task3 -only-testing:agentGuiTests/ACPModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前模型仍广泛依赖 `ACPJSONValue`。

**Step 3: Write minimal implementation**

- 在 `ACPModels.swift` 引入 typed capability、mode、config option、session info、tool call、terminal content、diff、location 等结构
- 将 `ACPJSONValue` 限缩到 `_meta`、`rawInput`、`rawOutput`、unknown extension payload
- 为未知扩展保留 `.other` case，但标准 case 必须优先 typed 命中

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPSchemaExtensions.swift agentGui/Services/ACP/ACPModels.swift agentGuiTests/ACPModelTests.swift
git commit -m "refactor: type acp schema models"
```

### Task 4: 补齐 `session/update`、feature extractor 和 normalizer 的官方变体

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPClientHandlerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CopilotACPEventNormalizerTests.swift`

**Step 1: Write the failing test**

补测试断言：

- `ACPSessionUpdate` 能 typed 解码 `current_mode_update`、`config_option_update`、`session_info_update`
- `plan` 与 `available_commands_update` 继续走 feature 流，不退回 `.other`
- normalizer 不再从原始字典猜测标准字段，而是消费 typed union

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task4 -only-testing:agentGuiTests/ACPClientHandlerTests -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests -only-testing:agentGuiTests/CopilotACPEventNormalizerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前后三类 update 仍落入 `.other`。

**Step 3: Write minimal implementation**

- 在 `ACPSessionUpdate` 中补齐标准变体
- `ACPExternalSessionFeatureExtractor` 只解析 typed 标准变体和显式扩展，不再对 `.other` 做协议级猜测
- `ACPExternalAgentEventNormalizer` 统一从 typed tool content / tool status 做映射

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPModels.swift agentGui/Services/ACP/ACPExternalSessionFeatureExtractor.swift agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift agentGui/Services/ACP/ACPExternalAgentEventNormalizer.swift agentGuiTests/ACPClientHandlerTests.swift agentGuiTests/ACPExternalSessionFeatureExtractorTests.swift agentGuiTests/CopilotACPEventNormalizerTests.swift
git commit -m "refactor: complete typed session update coverage"
```

### Task 5: 修正 initialization、capability gating 与 restore 语义

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`

**Step 1: Write the failing test**

补测试断言：

- `loadSession` 只能依据 `initialize` 响应里的 `loadSession` 判定
- provider 扩展能力必须依据显式 extension 广告，而不是 `sessionCapabilities != nil`
- `session/load` replay 与 live turn 分相处理，恢复期只建立 restore-phase projection，不提前标记 live turn

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task5 -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前 `supportsSessionModelOverride` 的推断过宽。

**Step 3: Write minimal implementation**

- `ACPExternalAgentCapabilitySnapshot` 拆成标准 capability 与 provider extension capability 两部分
- 标准 capability 只映射官方字段
- provider 扩展能力从 `_meta` 广告或 descriptor 显式配置读取
- 保持 `session/load` opportunistic fallback to `session/new`，但 restore 逻辑只建立在标准 `loadSession` 之上

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/ACP/ACPExternalProviderContracts.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift
git commit -m "fix: enforce acp capability negotiation strictly"
```

### Task 6: 把 file-system 和 terminal 行为对齐官方语义

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPLocalClientHandler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPLocalClientHandlerTests.swift`

**Step 1: Write the failing test**

补测试覆盖：

- `fs/read_text_file` 的 `line` / `limit` 使用 1-based 语义
- 非绝对路径返回 invalid params
- `terminal/create` 保持 `command`、`args`、`env` 的结构化语义，不通过 shell 拼接改变参数边界
- `outputByteLimit` 截断发生在字符边界

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task6 -only-testing:agentGuiTests/ACPLocalClientHandlerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前 terminal/create 仍走 shell 字符串。

**Step 3: Write minimal implementation**

- 给 `TerminalTaskRuntime` 增加结构化 detached launch API，例如 `startDetached(executable:arguments:environment:taskId:workingDirectory:)`
- `ACPLocalClientHandler` 直接透传 `command`、`args`、`env`
- 只在 terminal runtime 边界做进程启动，不在 ACP handler 层做 shell escape

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPLocalClientHandler.swift agentGui/Services/Terminal/TerminalTaskRuntime.swift agentGuiTests/ACPLocalClientHandlerTests.swift
git commit -m "fix: align acp file and terminal semantics"
```

### Task 7: provider feature projection 改为只消费标准 ACP + 显式扩展

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

断言：

- provider 的 remote commands、plan、mode、config options 都来自标准 typed `session/update`
- provider 私有行为只走 extension adapter
- 未广告扩展能力时，provider 不得继续发送私有方法

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task7 -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前 fixture 仍把 `session/set_model` 当标准方法。

**Step 3: Write minimal implementation**

- provider descriptor 声明私有扩展方法名和 capability 广告键
- feature adapter 只桥接标准 ACP surface 与已声明的 provider extension
- 更新测试 fixture 与日志断言，移除裸 `session/set_model`

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/ClaudeAdapter/ClaudeAdapterCLIExecutionProvider.swift agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift agentGuiTests/OpenCodeCLIExecutionProviderTests.swift
git commit -m "refactor: isolate provider extensions from acp core"
```

### Task 8: 做一次删除性清理，确保 ACP core 没有残余 legacy surface

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPClientRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProtocolConformanceTests.swift`

**Step 1: Write the failing test**

加一个“no legacy surface” 测试，直接扫描：

- `session/fork`
- `session/resume`
- `session/set_model`
- 标准 response 中的 `models`

这些字符串不得再出现在 ACP core 文件中。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-acp-task8 -only-testing:agentGuiTests/ACPProtocolConformanceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，直到所有残余 surface 被删净。

**Step 3: Write minimal implementation**

- 删除残余 dead types / dead APIs
- 更新 conformance tests，确保未来无法回退到旧 surface

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPModels.swift agentGui/Services/ACP/ACPClientRuntime.swift agentGuiTests/ACPProtocolConformanceTests.swift
git commit -m "refactor: remove leftover legacy acp surface"
```

## 7. Execution Notes

- 这次重构的核心不是“让现有 provider 尽量跑起来”，而是先把 ACP core 清干净，再要求 provider 通过显式 extension 重新接入。
- 如果某个 provider 当前只支持非标准方法名，又没有 `_` 扩展前缀能力，本计划下的正确结果是“该能力不可用”，而不是继续污染 ACP core。
- `session/load` replay、`plan`、`available_commands_update` 相关行为已有仓库经验，但本次要把它们建立在 typed 标准 update 之上，而不是 provider-specific 猜测。
- terminal 改造完成后，`ClaudeService+BashTool` 如复用 `TerminalTaskRuntime` 的 shell 字符串接口，应单独评估是否也要迁移到结构化 launch；这不是 ACP conformance 阻塞项，但要避免新旧 API 继续扩散。

## 8. Done Criteria

- ACP core 中不再存在任何非官方标准方法名和响应字段。
- 官方 schema 中的标准能力、content、tool call、session update 都有 typed Swift model。
- provider 私有能力全部通过 `_` 前缀扩展方法和显式 capability 广告接入。
- terminal/file-system 行为符合官方 argument 和 lifecycle 语义。
- focused conformance tests 全部通过。

Plan complete and saved to `docs/plans/2026-03-25-acp-client-schema-conformance-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按任务逐项落地实现、每步回归验证。

**2. Parallel Session (separate)** - 你开新 session，按 executing-plans 技能并行执行这份计划。

**Which approach?**