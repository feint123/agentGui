# User Message Inline Context UI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build structured user-message presentation for `@` file references and slash-command directives so the message list shows lightweight chips/tokens instead of raw plain text while remaining fully backward compatible with existing persisted messages.

**Architecture:** Implement v1 as a presentation-layer feature, not a persistence migration. Add a dedicated parser that derives directive chips, inline mention tokens, and attachment sections from existing `Message.textContent`, then render user bubbles through a small presentation model plus focused SwiftUI subviews. Keep copy/edit behavior bound to raw text so display-only structure does not mutate stored message content.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing `MessageBubbleView`, `ChatInputDirective`, `AttachedFile`, and ChatView input pipeline.

---

## 1. 实施原则

- 先做纯解析与 presentation 层，再改 `MessageBubbleView`。不要一开始直接在视图里堆字符串处理。
- v1 只做展示兼容，不修改 `Message` 持久化结构。
- 复制与编辑必须继续基于原始 `textContent`，避免 UI 美化影响模型输入一致性。
- mention 识别必须保守：能确认是工作区内真实文件再转 token，不能确认就保留原文。
- 测试优先覆盖三条链路：消息解析、展示映射、user bubble 回归。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/UserMessagePresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/UserMessageTextParser.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/UserMessageInlineContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/FileIconSymbolResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UserMessageTextParserTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UserMessagePresentationTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MessageBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`

## 3. 任务拆解

### Task 1: 建立 user message 文本解析器，稳定拆分正文、directive 和附件

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/UserMessageTextParser.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UserMessageTextParserTests.swift`

**Step 1: 写失败测试，固定解析契约**

新增测试覆盖以下行为：

- 普通 user message 不做任何结构化拆分
- 包含 `[Active directives] skill=brainstorming` 的消息能剥离 directive 尾注
- 包含 `Referenced files` 段的消息能拆出图片、PDF、其他文件
- directive 尾注和 `Referenced files` 共存时，解析顺序正确
- 正文中出现工作区内绝对路径时，只对真实文件生成 mention candidate
- 无法确认的绝对路径保持普通文本

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct UserMessageTextParserTests {

    @Test func parserExtractsDirectiveAuditAndLeavesBodyClean() async throws {
        let parsed = UserMessageTextParser.parse(
            text: "请按这个技能处理。\n\n[Active directives] skill=brainstorming",
            workspaceRoot: "/tmp/workspace"
        )

        #expect(parsed.bodyText == "请按这个技能处理。")
        #expect(parsed.directives.count == 1)
        #expect(parsed.directives.first?.rawValue == "skill=brainstorming")
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/UserMessageTextParserTests
```

Expected: FAIL，因为解析器与解析结果模型还不存在。

**Step 3: 写最小实现**

在 `UserMessageTextParser.swift` 中新增最小可测类型：

```swift
struct ParsedUserMessageText: Equatable {
    let bodyText: String
    let directiveAuditItems: [ParsedDirectiveAuditItem]
    let inlineSegments: [UserMessageInlineSegment]
    let images: [String]
    let pdfs: [String]
    let others: [String]
}

struct ParsedDirectiveAuditItem: Equatable {
    let kind: String
    let rawValue: String
    let displayName: String
}

enum UserMessageInlineSegment: Equatable {
    case text(String)
    case mention(ParsedMention)
}

struct ParsedMention: Equatable {
    let fullPath: String
    let displayName: String
    let secondaryPath: String?
}
```

解析顺序固定为：

1. 剥离 `Referenced files` 段
2. 剥离 `[Active directives] ...` 尾注
3. 基于剩余正文做 mention tokenization

mention 识别规则：

- 只识别工作区根目录下的绝对路径
- 只在文件真实存在时转 mention
- 使用最长路径优先，避免同一行多次切碎

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/UserMessageTextParser.swift agentGuiTests/UserMessageTextParserTests.swift
git commit -m "feat: add parser for structured user message text"
```

### Task 2: 建立 presentation 模型，隔离 UI 与解析细节

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/UserMessagePresentation.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UserMessagePresentationTests.swift`

**Step 1: 写失败测试，固定展示映射规则**

新增测试覆盖：

- parser 输出能映射成 directive chip row
- mention segment 会生成可渲染 token item
- 没有结构化元素时仍返回普通文本 presentation
- 附件段仍可复用现有图片/PDF/其他文件分组

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct UserMessagePresentationTests {

    @Test func presentationBuildsDirectiveAndMentionDisplayModels() async throws {
        let parsed = ParsedUserMessageText(
            bodyText: "请查看路径",
            directiveAuditItems: [
                ParsedDirectiveAuditItem(kind: "skill", rawValue: "skill=brainstorming", displayName: "brainstorming")
            ],
            inlineSegments: [
                .text("请查看 "),
                .mention(ParsedMention(fullPath: "/tmp/ws/agentGui/Views/MessageBubbleView.swift", displayName: "MessageBubbleView.swift", secondaryPath: "agentGui/Views/MessageBubbleView.swift"))
            ],
            images: [],
            pdfs: [],
            others: []
        )

        let presentation = UserMessagePresentation.make(from: parsed)

        #expect(presentation.directiveChips.count == 1)
        #expect(presentation.inlineItems.count == 2)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/UserMessagePresentationTests
```

Expected: FAIL，因为 presentation 模型还不存在。

**Step 3: 写最小实现**

在 `UserMessagePresentation.swift` 中新增只服务 user bubble 的轻量展示模型，例如：

```swift
struct UserMessagePresentation: Equatable {
    let directiveChips: [DirectiveChipPresentation]
    let inlineItems: [InlineItem]
    let images: [String]
    let pdfs: [String]
    let others: [String]
}

struct DirectiveChipPresentation: Equatable, Identifiable {
    let id: String
    let title: String
    let helpText: String
}

enum InlineItem: Equatable, Identifiable {
    case text(TextRunPresentation)
    case mention(MentionTokenPresentation)
}
```

要求：

- 解析器负责“是什么”，presentation 负责“怎么显示”
- 不在 SwiftUI View 里再写 audit string 解析逻辑
- `skill` 指令优先显示友好名称，回退到目录名

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/UserMessagePresentation.swift agentGuiTests/UserMessagePresentationTests.swift
git commit -m "feat: add user message presentation model"
```

### Task 3: 抽取共享文件图标解析器，消除 user bubble 对输入区私有方法的依赖

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/FileIconSymbolResolver.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UserMessagePresentationTests.swift`

**Step 1: 写失败测试，固定扩展名到 SF Symbol 的映射**

在已有 presentation 测试中补一条断言，确保 `.swift`、`.md`、图片、PDF 的图标映射稳定。

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/UserMessagePresentationTests
```

Expected: FAIL，因为共享解析器尚未建立。

**Step 3: 写最小实现**

新增共享工具：

```swift
enum FileIconSymbolResolver {
    static func symbol(forFileName name: String) -> String { ... }
}
```

然后把 `ChatView+InputArea.swift` 和 `WorkspacePanelView.swift` 内部重复的 `fileIcon(for:)` 迁移为调用该工具。

要求：

- 先保持现有映射不变
- 不顺手改动无关 UI 逻辑
- `UserMessageInlineContentView` 后续统一复用这个 resolver

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Utilities/FileIconSymbolResolver.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/WorkspacePanelView.swift agentGuiTests/UserMessagePresentationTests.swift
git commit -m "refactor: share file icon symbol mapping"
```

### Task 4: 实现 user bubble 内联内容视图，渲染 directive chips 与 mention tokens

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/UserMessageInlineContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MessageBubbleView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UserMessagePresentationTests.swift`

**Step 1: 先补回归测试，固定 user bubble 的展示切换点**

新增测试或断言覆盖：

- 有 directive 时显示 chip 行
- 有 mention 时生成 token 视图输入数据
- 无结构化内容时退回纯文本视图模型
- 其他附件展示不受影响

如果 UI 直接 snapshot 测试成本过高，至少把 `MessageBubbleView` 所依赖的 presentation 输出固定住。

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/UserMessagePresentationTests
```

Expected: FAIL，因为 아직没有 user bubble 新渲染路径。

**Step 3: 写最小实现**

在 `UserMessageInlineContentView.swift` 中实现三个子块：

- `directiveChipsRow`
- `inlineContentWrap`
- `mentionTokenView`

视图要求：

- directive 行放在正文上方，弱材质或轻底色，不含删除按钮
- mention token 显示图标、主文案、副文案
- hover 显示完整路径或 help 文本
- 布局可换行，不引入过重卡片边框

在 `MessageBubbleView.swift` 中，把现有：

```swift
Text(content.text)
    .font(.body)
    .textSelection(.enabled)
```

改为：

- 先构建 `UserMessagePresentation`
- 有结构化内容时渲染 `UserMessageInlineContentView`
- 无结构化内容时保留原 `Text` 渲染路径

要求：

- 不破坏编辑态
- 不改变附件展示与 hover action
- `copyMessage(_:)` 保持复制原始 `textContent`

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/UserMessageInlineContentView.swift agentGui/Views/MessageBubbleView.swift agentGuiTests/UserMessagePresentationTests.swift
git commit -m "feat: render structured user message context"
```

### Task 5: 做消息级回归测试，覆盖真实文本样本与历史兼容

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UserMessageTextParserTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UserMessagePresentationTests.swift`

**Step 1: 增加真实样本测试**

补以下样本：

- 只含正文
- 正文 + 单 mention
- 正文 + 多 mention
- 正文 + directive
- 正文 + directive + `Referenced files`
- 包含工作区外绝对路径但不应转 token
- 图片/PDF 附件与 mention 共存

建议用和当前工程一致的绝对路径前缀，例如：

```swift
/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MessageBubbleView.swift
```

**Step 2: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/UserMessageTextParserTests -only-testing:agentGuiTests/UserMessagePresentationTests
```

Expected: PASS。

**Step 3: 跑消息相关回归测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ChatInputDirectiveAuditTests \
  -only-testing:agentGuiTests/MarkdownMessageViewRenderingTests \
  -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: PASS，确保新展示层没有影响现有 audit、markdown 或 agent message 逻辑。

**Step 4: Commit**

```bash
git add agentGuiTests/UserMessageTextParserTests.swift agentGuiTests/UserMessagePresentationTests.swift
git commit -m "test: cover structured user message compatibility"
```

### Task 6: 可选的 v1.1 收尾优化，不阻塞主干合并

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/UserMessageInlineContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-11-user-message-inline-context-ui-requirements.md`

**Step 1: 实现 hover 文案优化**

- directive chip hover 展示原始 audit 值
- mention token hover 展示完整绝对路径

**Step 2: 评估是否需要点击打开文件**

- 如果实现简单且不影响稳定性，可补受控点击行为
- 如果需要额外依赖 `WorkspaceState` 或文件导航，延后到独立需求

**Step 3: 文档回写**

把已实现范围与延期项同步回需求文档，防止文档与实现漂移。

## 4. 关键实现细节

### 4.1 为什么先做 parser，而不是直接在 `MessageBubbleView` 中拼视图

因为当前 user message 已经同时混有：

- 正文
- directive 审计尾注
- `Referenced files` 附件段
- 展开后的绝对路径 mention

如果这些逻辑继续留在 `MessageBubbleView`，后续只会演变成更大的 view-level string soup。先抽 parser 能把问题限制在纯函数层，便于做历史兼容测试。

### 4.2 为什么 mention token 只识别工作区内真实文件

发送链路会把 `@relative/path` 展开成绝对路径，这意味着仅靠路径形状无法判断它是不是用户显式引用。如果不加边界，任何日志、报错、命令输出中的绝对路径都有可能被误渲染成 token。工作区根路径 + 文件真实存在是 v1 最稳妥的识别条件。

### 4.3 为什么 v1 不改持久化结构

本需求优先级在“提升回看体验”，不是“重做消息存储层”。先通过展示兼容收敛体验，能最大程度避免迁移成本；等 UI 和解析规则稳定后，再进入结构化 metadata 持久化阶段。

## 5. 风险与回退策略

- 如果 `Text` 与自定义 token 混排在 SwiftUI 中换行表现不稳定，优先退到“正文文本块 + mention token 列表摘要”方案，不阻塞 directive chip 上线。
- 如果绝对路径识别误判率高，先只支持通过显式前缀规则识别本工作区路径，减少自动 token 化范围。
- 如果 `MessageBubbleView` 体积继续膨胀，允许在 Task 4 中顺手把 user bubble 子树拆到 `UserMessageInlineContentView`，但不要顺手重构 agent bubble。

## 6. 完成定义

满足以下条件即可认为 v1 完成：

1. user message 中的 directive 尾注不再直接裸露为正文字符串。
2. 工作区内可确认的文件路径在 user bubble 中能以 mention token 展示。
3. 图片、PDF、其他附件现有能力不回退。
4. 复制与编辑行为保持当前语义。
5. 新增 parser/presentation 测试与消息相关回归测试全部通过。

Plan complete and saved to `docs/plans/2026-03-11-user-message-inline-context-ui-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?