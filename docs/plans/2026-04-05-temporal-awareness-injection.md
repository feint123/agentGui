# Temporal Awareness Injection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 当用户提出含有相对时间表达（最近/近期/最新/latest/recent）的问题时，使 agent 能够正确锚定到系统注入的实际当前日期，而不是从训练数据推断"现在"；同时让 agent 主动告知知识截止日期的局限性。

**Architecture:** 双层注入策略——Layer 1 在系统提示的 `SystemPromptRuntimeContext.promptSection` 中添加时序感知指南；Layer 2 在每次对话构建 `apiMessages` 时，向列表头部追加一条 `<system-reminder>` 用户消息（类比 Claude Code 的 `prependUserContext` 机制），使当前日期在对话上下文中更显著。

**Tech Stack:** Swift 6, SwiftData, SwiftAnthropic, XCTest

**参考来源（Claude Code 源码中的对应机制）：**
- `src/constants/common.ts` — `getLocalISODate()` / `getSessionStartDate()`
- `src/context.ts` — `getUserContext()` 返回 `currentDate` 字段，下游由 `prependUserContext` 包装为 `<system-reminder>` 用户消息
- `src/utils/api.ts:449` — `prependUserContext` — 将 context 字典包装为首条 user 消息
- `src/utils/attachments.ts:1415` — `getDateChangeAttachments` — 跨午夜时追加日期变更尾部附件

---

## 问题分析

### 现状

`SystemPromptRuntimeContext.promptSection` 已经注入了当前日期时间（ISO8601 格式、时区），并含一行通用的 Reality Constraints 说明：

```
- Current date/time: 2026-04-05T14:30:00+08:00
- Reality constraints: ... Use the actual current date, OS, locale, and working directory above when reasoning about commands, files, timestamps, or environment-sensitive behavior. Do not assume a different platform or stale date.
```

### 问题根因

1. **Knowledge cutoff gap 未被明确处理**：当前指令只要求模型在"命令/文件/时间戳"场景使用实际日期，未覆盖"用户询问最近事件/最新版本/近期进展"这一类时序推断场景。

2. **日期注入位置单一**：仅注入在系统提示（system prompt）中，不如 Claude Code 额外在 user-turn 注入一条 `<system-reminder>` 消息——后者在 context window 末尾更靠近用户输入，模型更容易在时序推断时引用它。

3. **无 knowledge cutoff 感知指令**：模型不知道"需要主动告知知识截止限制"。当用户问"最近有哪些新 AI 模型"，模型会用训练数据中的"最新"回答，而不说明知识边界。

### 修复目标

- 用户问"最近/近期/latest/newest/今年..."时，模型的响应应锚定到注入的 `currentDateTimeText`，并且在涉及近期事件/版本/新闻时，主动说明"我的训练数据截止日期为 [X]，今天是 [Y]，关于 [X] 之后的信息我可能不具备"。
- 修改范围最小化：只动 `ClaudeService+Prompting.swift` 和 `ClaudeService+Messaging.swift` 两个文件，新增一个测试文件。

---

## Task 1: 增强 `SystemPromptRuntimeContext.promptSection` 时序感知指令

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift:76-88`
- Test: `agentGuiTests/TemporalAwarenessInjectionTests.swift` (新增)

### Step 1: 写失败测试

在 `agentGuiTests/TemporalAwarenessInjectionTests.swift` 中添加：

```swift
import XCTest
@testable import agentGui

final class TemporalAwarenessInjectionTests: XCTestCase {

    // MARK: - Layer 1: SystemPromptRuntimeContext temporal reasoning instruction

    func test_promptSection_containsTemporalReasoningInstruction() {
        let ctx = SystemPromptRuntimeContext(
            currentDateTimeText: "2026-04-05T14:30:00+08:00",
            timezoneIdentifier: "Asia/Shanghai",
            localeIdentifier: "zh_CN",
            operatingSystemText: "macOS 15.0",
            hostName: "test-host",
            workingDirectory: "/tmp",
            workingDirectorySource: "test",
            proxySummary: nil
        )
        let section = ctx.promptSection
        XCTAssertTrue(
            section.contains("knowledge cutoff") || section.contains("训练数据截止") || section.contains("training data"),
            "promptSection 应包含 knowledge cutoff 感知指令"
        )
    }

    func test_promptSection_containsRelativeTimeAnchorInstruction() {
        let ctx = SystemPromptRuntimeContext(
            currentDateTimeText: "2026-04-05T14:30:00+08:00",
            timezoneIdentifier: "Asia/Shanghai",
            localeIdentifier: "zh_CN",
            operatingSystemText: "macOS 15.0",
            hostName: "test-host",
            workingDirectory: "/tmp",
            workingDirectorySource: "test",
            proxySummary: nil
        )
        let section = ctx.promptSection
        // 应包含"最近/近期"或"recent/latest"的相对时间锚定说明
        let hasRelativeTimeInstruction =
            section.contains("最近") || section.contains("recent") ||
            section.contains("latest") || section.contains("relative")
        XCTAssertTrue(hasRelativeTimeInstruction,
                      "promptSection 应包含相对时间表达的锚定指令")
    }

    func test_promptSection_currentDateIsPresent() {
        let dateText = "2026-04-05T14:30:00+08:00"
        let ctx = SystemPromptRuntimeContext(
            currentDateTimeText: dateText,
            timezoneIdentifier: "Asia/Shanghai",
            localeIdentifier: "zh_CN",
            operatingSystemText: "macOS 15.0",
            hostName: "test-host",
            workingDirectory: "/tmp",
            workingDirectorySource: "test",
            proxySummary: nil
        )
        XCTAssertTrue(ctx.promptSection.contains(dateText),
                      "promptSection 应包含注入的日期时间文本")
    }
}
```

### Step 2: 运行，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-temporal-derived \
  -only-testing:agentGuiTests/TemporalAwarenessInjectionTests/test_promptSection_containsTemporalReasoningInstruction \
  CODE_SIGNING_ALLOWED=NO
```

期望：**FAIL** — `test_promptSection_containsTemporalReasoningInstruction` 失败（当前 promptSection 无 knowledge cutoff 指令）。

### Step 3: 修改 `SystemPromptRuntimeContext.promptSection`

在 `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift` 中，找到 `var promptSection: String {` 计算属性，将 `"- Reality constraints: ..."` 这一行**替换**为拆分后的两部分：

**旧代码（第 76–88 行附近）：**

```swift
    var promptSection: String {
        var lines = [
            "## Runtime Environment",
            "- Current date/time: \(currentDateTimeText)",
            "- Time zone: \(timezoneIdentifier)",
            "- Locale: \(localeIdentifier)",
            "- Operating system: \(operatingSystemText)",
            "- Host: \(hostName)",
            "- Working directory: \(workingDirectory) (source: \(workingDirectorySource))",
            "- Reality constraints: You are running inside a macOS app. Use the actual current date, OS, locale, and working directory above when reasoning about commands, files, timestamps, or environment-sensitive behavior. Do not assume a different platform or stale date."
        ]

        if let proxySummary {
            lines.append("- Network proxy: \(proxySummary)")
        }

        return lines.joined(separator: "\n")
    }
```

**新代码（替换后）：**

```swift
    var promptSection: String {
        var lines = [
            "## Runtime Environment",
            "- Current date/time: \(currentDateTimeText)",
            "- Time zone: \(timezoneIdentifier)",
            "- Locale: \(localeIdentifier)",
            "- Operating system: \(operatingSystemText)",
            "- Host: \(hostName)",
            "- Working directory: \(workingDirectory) (source: \(workingDirectorySource))",
            "- Reality constraints: You are running inside a macOS app. Use the actual current date, OS, locale, and working directory above when reasoning about commands, files, timestamps, or environment-sensitive behavior. Do not assume a different platform or stale date.",
            "- Temporal reasoning: When the user uses relative time expressions — 最近、近期、最新、近来、今年、this year、recent、latest、newest、current — interpret them relative to the current date/time listed above. Your training data has a knowledge cutoff that is earlier than today's date. When answering questions about recent events, latest software versions, newest models, current prices, or recent news, proactively acknowledge your knowledge cutoff and note that information after your training cutoff may be outdated or unavailable."
        ]

        if let proxySummary {
            lines.append("- Network proxy: \(proxySummary)")
        }

        return lines.joined(separator: "\n")
    }
```

### Step 4: 运行全部 Layer 1 测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-temporal-derived \
  -only-testing:agentGuiTests/TemporalAwarenessInjectionTests \
  CODE_SIGNING_ALLOWED=NO
```

期望：**PASS** — 全部 3 个 Layer 1 测试通过。

### Step 5: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Prompting.swift \
        agentGuiTests/TemporalAwarenessInjectionTests.swift
git commit -m "feat(temporal): add knowledge cutoff + relative-time anchor in system prompt"
```

---

## Task 2: 添加 `<system-reminder>` 用户消息前置注入（Layer 2）

> 对应 Claude Code 的 `prependUserContext` 机制：将当前日期作为 `<system-reminder>` 用户消息追加到 apiMessages 最前面，使其在对话 context window 中比系统提示更靠近用户输入，提升时序感知显著度。

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`（在 `resumeSendBuiltIn` 中注入）
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift`（添加 `makeTemporalContextPreamble` 工厂方法）
- Test: `agentGuiTests/TemporalAwarenessInjectionTests.swift`（追加）

### Step 1: 在测试文件中追加 Layer 2 失败测试

在 `agentGuiTests/TemporalAwarenessInjectionTests.swift` 末尾追加：

```swift
    // MARK: - Layer 2: temporal context preamble message

    func test_makeTemporalContextPreamble_roleIsUser() {
        let preamble = SystemPromptRuntimeContext.makeTemporalContextPreamble(
            currentDateTimeText: "2026-04-05T14:30:00+08:00",
            timezoneIdentifier: "Asia/Shanghai"
        )
        XCTAssertEqual(preamble.role, .user,
                       "temporal preamble 应为 user role，以模拟 <system-reminder> 前置")
    }

    func test_makeTemporalContextPreamble_containsSystemReminderTag() {
        let preamble = SystemPromptRuntimeContext.makeTemporalContextPreamble(
            currentDateTimeText: "2026-04-05T00:00:00+08:00",
            timezoneIdentifier: "Asia/Shanghai"
        )
        guard case .text(let text) = preamble.content else {
            return XCTFail("preamble content 应为 .text")
        }
        XCTAssertTrue(text.contains("<system-reminder>"),
                      "preamble 应包含 <system-reminder> 开始标签")
        XCTAssertTrue(text.contains("</system-reminder>"),
                      "preamble 应包含 </system-reminder> 结束标签")
    }

    func test_makeTemporalContextPreamble_containsDateText() {
        let dateText = "2026-04-05T14:30:00+08:00"
        let preamble = SystemPromptRuntimeContext.makeTemporalContextPreamble(
            currentDateTimeText: dateText,
            timezoneIdentifier: "Asia/Shanghai"
        )
        guard case .text(let text) = preamble.content else {
            return XCTFail("preamble content 应为 .text")
        }
        XCTAssertTrue(text.contains(dateText),
                      "preamble 应包含注入的日期时间文本")
    }

    func test_makeTemporalContextPreamble_containsRelativeTimeKeywords() {
        let preamble = SystemPromptRuntimeContext.makeTemporalContextPreamble(
            currentDateTimeText: "2026-04-05T00:00:00+08:00",
            timezoneIdentifier: "Asia/Shanghai"
        )
        guard case .text(let text) = preamble.content else {
            return XCTFail("preamble content 应为 .text")
        }
        let hasKeywords = text.contains("最近") || text.contains("recent") || text.contains("latest")
        XCTAssertTrue(hasKeywords,
                      "preamble 应包含相对时间表达关键词以强化模型时序感知")
    }
```

### Step 2: 运行，确认 Layer 2 测试失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-temporal-derived \
  -only-testing:agentGuiTests/TemporalAwarenessInjectionTests/test_makeTemporalContextPreamble_roleIsUser \
  CODE_SIGNING_ALLOWED=NO
```

期望：**FAIL** — `makeTemporalContextPreamble` 方法不存在，编译失败。

### Step 3: 在 `SystemPromptRuntimeContext` 中添加 `makeTemporalContextPreamble` 工厂方法

在 `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift` 中，在 `SystemPromptRuntimeContext` 结构体的 `promptSection` 计算属性之后（即 `}` 前），添加静态工厂方法：

```swift
    /// 构建 <system-reminder> 时序上下文前置消息（对应 Claude Code prependUserContext 中的 currentDate 条目）。
    /// 作为 apiMessages 的第一条 user 消息追加，使模型在对话 context window 中更靠近用户输入处看到当前日期。
    static func makeTemporalContextPreamble(
        currentDateTimeText: String,
        timezoneIdentifier: String
    ) -> MessageParameter.Message {
        let content = """
        <system-reminder>
        # currentDate
        Today's date and time: \(currentDateTimeText) (\(timezoneIdentifier)).

        When the user uses relative time expressions — 最近、近期、最新、近来、今年、this year、recent、latest、newest、current — always interpret them relative to the date above. Your training data has a knowledge cutoff that may be significantly earlier than today. When answering questions about recent events, latest software versions, newest AI models, current prices, recent news, or any topic that changes over time, proactively state your knowledge cutoff and note that more recent information may exist beyond your training data.

        IMPORTANT: This reminder is injected automatically. Do not respond to it directly — only apply it when the user's query is time-sensitive.
        </system-reminder>
        """
        return MessageParameter.Message(role: .user, content: .text(content))
    }
```

### Step 4: 在 `resumeSendBuiltIn` 中的 `apiMessages` 前注入此消息

在 `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift` 中，找到 `private func resumeSendBuiltIn(...)` 方法，在 `let settings = AppSettings.getOrCreate(in: modelContext)` 之后（且在 `resolveTurnSkillContext` 调用之前），添加以下代码：

**在 `resumeSendBuiltIn` 中找到这个位置（原代码第 518–525 行附近）：**

```swift
    private func resumeSendBuiltIn(
        apiMessages: [MessageParameter.Message],
        service: any AnthropicService,
        session: Session,
        modelId: String,
        selectedFilePath: String? = nil,
        selectedText: String? = nil,
        directives: [ChatInputDirective] = [],
        targetAgentMessageID: UUID? = nil,
        modelContext: ModelContext
    ) async throws {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let turnSkillContext = try await resolveTurnSkillContext(
```

**修改为（添加 temporal preamble 注入逻辑）：**

```swift
    private func resumeSendBuiltIn(
        apiMessages: [MessageParameter.Message],
        service: any AnthropicService,
        session: Session,
        modelId: String,
        selectedFilePath: String? = nil,
        selectedText: String? = nil,
        directives: [ChatInputDirective] = [],
        targetAgentMessageID: UUID? = nil,
        modelContext: ModelContext
    ) async throws {
        let settings = AppSettings.getOrCreate(in: modelContext)

        // Layer 2 temporal injection: 仅当 apiMessages 头部尚无 system-reminder 时追加时序上下文前置消息
        // 对应 Claude Code 的 prependUserContext({ currentDate: "Today's date is ..." })
        let messagesWithTemporalContext: [MessageParameter.Message]
        let alreadyHasTemporalPreamble = apiMessages.first.map { msg -> Bool in
            if case .text(let t) = msg.content { return t.contains("<system-reminder>") }
            return false
        } ?? false
        if !alreadyHasTemporalPreamble {
            let runtimeCtx = SystemPromptRuntimeContext.live(
                workingDirectory: settings.workingDirectory,
                settings: settings,
                session: session
            )
            let preamble = SystemPromptRuntimeContext.makeTemporalContextPreamble(
                currentDateTimeText: runtimeCtx.currentDateTimeText,
                timezoneIdentifier: runtimeCtx.timezoneIdentifier
            )
            messagesWithTemporalContext = [preamble] + apiMessages
        } else {
            messagesWithTemporalContext = apiMessages
        }

        let turnSkillContext = try await resolveTurnSkillContext(
```

> **注意：** 后续代码中所有引用 `apiMessages` 的地方（仅此函数内部）需改为 `messagesWithTemporalContext`。具体来说是调用 `sendMessageImpl`（或 `runAgenticLoop` / `resumeBuiltInSendImpl`）时传入的参数。

找到该函数内调用下一阶段的位置（大约在 `try await sendMessageImpl(...)` 或 `try await self.sendBuiltIn(...)` 处，将 `apiMessages:` 参数改为 `apiMessages: messagesWithTemporalContext`）。

> 提示：用 `grep -n "apiMessages:" agentGui/Services/ClaudeService/ClaudeService+Messaging.swift` 确认调用点，确保仅改 `resumeSendBuiltIn` 内的下游传参，不要影响该方法的输入参数。

### Step 5: 运行全部 Layer 2 测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-temporal-derived \
  -only-testing:agentGuiTests/TemporalAwarenessInjectionTests \
  CODE_SIGNING_ALLOWED=NO
```

期望：**PASS** — 全部 7 个测试通过（3 个 Layer 1 + 4 个 Layer 2）。

### Step 6: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Prompting.swift \
        agentGui/Services/ClaudeService/ClaudeService+Messaging.swift \
        agentGuiTests/TemporalAwarenessInjectionTests.swift
git commit -m "feat(temporal): inject <system-reminder> date preamble in apiMessages (Layer 2)"
```

---

## Task 3: Regression — 现有系统提示相关测试不被破坏

### Step 1: 运行现有提示测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-temporal-derived \
  -only-testing:agentGuiTests/MemoryBootstrapSystemPromptInjectionTests \
  -only-testing:agentGuiTests/MemorySystemPromptInjectionTests \
  -only-testing:agentGuiTests/SkillCatalogPromptRendererTests \
  CODE_SIGNING_ALLOWED=NO
```

期望：**PASS** — 所有现有提示测试通过。

### Step 2: 如有失败，分析原因并修复

常见原因：
- `makeSystemPromptForTests` 的调用签名依赖 `SystemPromptRuntimeContext`，若 `makeTemporalContextPreamble` 引起编译错误则在此处修复。
- `promptSection` 新增行导致某些"内容精确匹配"测试失败 — 更新这些断言以使用 `contains` 而非精确相等。

### Step 3: Commit（若有修复）

```bash
git add .
git commit -m "fix(temporal): update existing prompt tests for new promptSection content"
```

---

## 验收标准（手动验证）

完成上述任务后，启动应用，在新对话中依次发送：

1. `今天是几号？` → 模型应回答系统注入的实际日期（而非"我不知道今天是几号"）。
2. `最近有什么新的 AI 模型发布？` → 模型应明确说明自己的知识截止日期，并提示今天实际日期与截止日期之间可能有信息空白。
3. `最新版的 macOS 是什么？` → 模型应说明训练截止日期，建议用户自行查阅官网获取最新信息。
4. `近期 Swift 有什么大更新？` → 同上，模型主动锚定当前日期并告知知识局限。

---

## 关键设计决策

### 为什么用两层注入而不是只改系统提示？

Claude Code 的实践表明（`src/utils/api.ts:449`），将时序上下文作为 **user-turn 消息**（而非仅在 system prompt 中）注入，能让模型在 context window 尾部（即更靠近用户输入的位置）看到当前日期，从而在生成下一条 assistant 响应时更优先引用这个信息。这两种注入方式互补，而非替代。

### 为什么不用 `appendSystemContext` 而是 user-turn 注入？

Anthropic API 的 `system` 字段一旦设定，其 token 权重相对固定。而 user-turn 消息在对话内更接近生成时刻，对模型的 attention 计算有更直接的影响，尤其对相对时间推断这类需要"当下感知"的任务。

### 为什么只在 `resumeSendBuiltIn` 注入而不是全部入口？

`resumeSendBuiltIn` 是 built-in agent 消息发送的唯一汇聚点（`sendMessageBuiltIn`、`regenerateBuiltIn`、`retryFailedBuiltIn` 都最终调用它）。集中在此注入保证幂等性（通过检查首条消息是否已含 `<system-reminder>`），避免重复注入。

### 关于 ACP 外部 provider

ACP 外部 provider（opencode、qoder 等）有自己的系统提示构建路径，不经过 `resumeSendBuiltIn`，不在本计划范围内。如需扩展可参考此计划在各 ExternalProviderAdapter 中做类似处理。

---

## 文件修改汇总

| 操作 | 文件 | 说明 |
|------|------|------|
| Modify | `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift` | 在 `promptSection` 添加 Temporal reasoning 行；新增 `makeTemporalContextPreamble` 静态方法 |
| Modify | `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift` | 在 `resumeSendBuiltIn` 的 apiMessages 前注入 temporal preamble |
| Create | `agentGuiTests/TemporalAwarenessInjectionTests.swift` | 7 个单元测试（3 Layer1 + 4 Layer2）|
