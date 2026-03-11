# ChatView Slash Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an extensible `/` command system in ChatView that lets users explicitly activate a skill for the current turn, with keyboard-first UX, per-turn input directives, deterministic request assembly, and room to add non-skill commands later.

**Architecture:** Treat slash commands as a general composer capability rather than a skill-specific shortcut. Introduce a small command catalog layer (`SlashCommandItem` + provider registry), a per-turn directive layer (`ChatInputDirective`), and a request-resolution layer that turns selected directives into explicit runtime context before the model call. Keep v1 limited to one skill directive per turn, but do not hardcode the UI or request pipeline to `Skill`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing `SkillService`, existing `ClaudeService` prompt builder and agent loop.

---

## 1. 实施原则

- 先做可测试的纯模型与解析层，再接 UI。不要一开始把 slash 状态全塞进 `ChatView`。
- 先支持单个 skill directive，底层模型允许未来支持多命令。
- slash 激活必须是“本轮临时生效”，不能污染 `AppSettings.enabledSkillNames`。
- 显式激活 skill 时，客户端要在发送前完成解析，不能继续完全依赖模型自行调用 `read_skill`。
- 测试优先覆盖三条主链路：候选生成、输入解析、请求生效。

## 2. 任务拆解

### Task 1: 建立 Slash Command 基础模型与 Skill Provider

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SlashCommandModels.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SlashCommandRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SkillService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SlashCommandRegistryTests.swift`

**Step 1: 写失败测试，固定 slash catalog 契约**

新增测试，覆盖以下行为：

- 已安装 skill 能被转换为 `SlashCommandItem(kind: .skill, ...)`
- 过滤时同时匹配 `name`、`directoryName`、`description`
- 全局已启用 skill 排在未启用 skill 前面
- catalog 当前只有 skill provider 时，也仍返回通用命令项模型，而不是直接暴露 `Skill`

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct SlashCommandRegistryTests {

    @Test func skillProviderBuildsGenericSlashItems() async throws {
        let skills = [
            Skill(
                directoryName: "brainstorming",
                name: "brainstorming",
                description: "Use when exploring feature requirements.",
                path: URL(fileURLWithPath: "/tmp/brainstorming"),
                contentURL: URL(fileURLWithPath: "/tmp/brainstorming/SKILL.md")
            )
        ]

        let registry = SlashCommandRegistry(
            providers: [SkillSlashCommandProvider(skills: skills, enabledSkillNames: [])]
        )

        let items = registry.items(matching: "brain")

        #expect(items.count == 1)
        #expect(items.first?.kind == .skill)
        #expect(items.first?.title == "brainstorming")
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/SlashCommandRegistryTests
```

Expected: FAIL，因为 `SlashCommandRegistry`、`SlashCommandItem`、`SkillSlashCommandProvider` 还不存在。

**Step 3: 写最小实现**

新增通用模型，建议最小字段如下：

```swift
enum SlashCommandKind: String, Codable, Hashable {
    case skill
    case agent
    case workflow
    case preset
    case contextAction
}

enum SlashCommandPayload: Hashable, Codable {
    case skill(directoryName: String)
}

struct SlashCommandItem: Identifiable, Hashable {
    let id: String
    let kind: SlashCommandKind
    let title: String
    let subtitle: String
    let aliases: [String]
    let badge: String?
    let isEnabledByDefault: Bool
    let payload: SlashCommandPayload
}
```

新增 `SlashCommandRegistry` 与 `SlashCommandProvider`，并实现 `SkillSlashCommandProvider`。

`SkillService` 只补最少辅助能力，例如：

- `func skill(namedOrDirectoryName: String) -> Skill?`
- 或 `func availableSkills(enabledNames: [String]) -> [Skill]` 所需排序支持

不要在 `SkillService` 里直接写 UI 过滤逻辑；过滤应留在 slash catalog 层。

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/SlashCommandModels.swift agentGui/Services/SlashCommandRegistry.swift agentGui/Services/SkillService.swift agentGuiTests/SlashCommandRegistryTests.swift
git commit -m "feat: add slash command registry for skills"
```

### Task 2: 抽离输入解析与 directive 状态，避免把 slash 逻辑写死在 View 内

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChatInputDirective.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChatInputCommandParser.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatInputCommandParserTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`

**Step 1: 写失败测试，固定 slash 触发与 directive 规则**

新增解析测试，至少覆盖：

- 文本开头输入 `/` 能识别为空查询
- `/brain` 能识别出 query 为 `brain`
- `hello /brain` 若 slash 前为空白，仍能识别
- `/Users/feint/file.swift` 不应误识别为 slash 命令
- 选中 slash 项后能生成 `ChatInputDirective.skill(...)`

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct ChatInputCommandParserTests {

    @Test func detectsSlashQueryAtStartOfComposer() async throws {
        let result = ChatInputCommandParser.detectSlashQuery(in: "/brain")

        #expect(result?.rawToken == "/brain")
        #expect(result?.query == "brain")
    }

    @Test func ignoresAbsolutePaths() async throws {
        let result = ChatInputCommandParser.detectSlashQuery(in: "/Users/feint/project")

        #expect(result == nil)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ChatInputCommandParserTests
```

Expected: FAIL，因为 parser 与 directive 模型还不存在。

**Step 3: 写最小实现**

新增 per-turn directive 模型，v1 先只实现 skill：

```swift
enum ChatInputDirective: Identifiable, Hashable, Codable {
    case skill(SkillInputDirective)

    var id: String {
        switch self {
        case .skill(let value):
            return "skill:\(value.directoryName)"
        }
    }
}

struct SkillInputDirective: Hashable, Codable {
    let directoryName: String
    let displayName: String
}
```

新增纯解析器：

- `detectSlashQuery(in:)`
- `replacingSlashToken(in:with:)`
- `makeDirective(from:)`

`ChatView` 只先增加最少状态：

- `slashQuery`
- `slashCandidates`
- `highlightedSlashItemID`
- `activeInputDirectives`

此阶段不要接 UI 面板，只把状态模型准备好。

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/ChatInputDirective.swift agentGui/Services/ChatInputCommandParser.swift agentGui/Views/ChatView.swift agentGuiTests/ChatInputCommandParserTests.swift
git commit -m "feat: add slash query parsing and input directives"
```

### Task 3: 接入 ChatView 输入区 UI 与键盘交互

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerSlashStateTests.swift`

**Step 1: 写失败测试，先固定交互状态转换**

不要直接写 NSView 交互测试，先写纯状态测试，覆盖：

- 输入 `/` 时打开 slash 候选
- 继续输入关键字时缩小候选集
- 选中候选后移除文本中的 slash token，并新增 directive chip
- 清除 directive 后可再次选择新命令
- 有 slash 面板时，`Enter` 优先选择命令而不是直接发送

如果现有 `MentionAwareEditor` 不方便直接单测，抽出一个极小状态对象，例如：

- `ChatComposerSlashState`
- 或 `ChatComposerAssistState`

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct ChatComposerSlashStateTests {

    @Test func selectingSlashItemCreatesDirectiveAndRemovesTriggerToken() async throws {
        let item = SlashCommandItem(
            id: "skill:brainstorming",
            kind: .skill,
            title: "brainstorming",
            subtitle: "Use when exploring feature requirements.",
            aliases: [],
            badge: "Skill",
            isEnabledByDefault: false,
            payload: .skill(directoryName: "brainstorming")
        )

        let result = ChatInputCommandParser.replacingSlashToken(
            in: "/brain fix this layout",
            selectedItem: item
        )

        #expect(result.updatedText == "fix this layout")
        #expect(result.directive?.id == "skill:brainstorming")
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ChatComposerSlashStateTests
```

Expected: FAIL，因为 slash 选择后的状态处理与 token 替换流程还未实现。

**Step 3: 写最小实现**

在 `ChatView+InputArea.swift` 中实现：

- slash 面板卡片，风格复用 mention popup
- 候选列表渲染与高亮行
- directive chip 行，复用当前 chip 视觉语言
- slash 与 mention 的显示优先级规则：同一时刻只展示一个辅助面板

在 `MentionAwareEditor` 内补最少键盘能力：

- `Up` / `Down` 切换高亮项
- `Tab` / `Enter` 触发选中回调
- `Esc` 关闭 slash 面板

如果把所有逻辑硬写在 `NSViewRepresentable` 协调器里会很快失控，应增加清晰回调：

- `onMoveSelection(direction:)`
- `onCommitSelection()`
- `onCancelAssist()`

不要在这个任务中改发送链路；只完成 UI 选择与 directive 呈现。

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: 手工验证一次输入交互**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED。

手工检查：

- 输入 `/` 可看到 skill 列表
- 键盘可筛选和确认
- 选中后出现 chip，原 slash token 被移除

**Step 6: Commit**

```bash
git add agentGui/Views/ChatView.swift agentGui/Views/ChatView+InputArea.swift agentGuiTests/ChatComposerSlashStateTests.swift
git commit -m "feat: add slash command composer UI"
```

### Task 4: 重构发送载荷，让 slash 选择真实生效到本轮请求

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChatSendRequest.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChatInputDirectiveResolver.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatInputDirectiveResolverTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceSlashCommandTests.swift`

**Step 1: 写失败测试，固定“显式 skill 激活”的请求语义**

新增 resolver / prompt 测试，至少覆盖：

- 全局启用 skill 与本轮显式 skill 会做并集，不重复
- 本轮显式 skill 即使不在 `enabledSkillNames` 中，也能加入本轮有效 skill 集
- 若 directive 指向不存在 skill，resolver 返回结构化错误
- system prompt 中会新增显式激活 skill 的段落
- 该段落包含激活来源 `user slash command`

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct ClaudeServiceSlashCommandTests {

    @Test func systemPromptIncludesExplicitlyActivatedSkillsSection() async throws {
        let skill = Skill(
            directoryName: "brainstorming",
            name: "brainstorming",
            description: "Use when exploring feature requirements.",
            path: URL(fileURLWithPath: "/tmp/brainstorming"),
            contentURL: URL(fileURLWithPath: "/tmp/brainstorming/SKILL.md")
        )

        let settings = AppSettings()
        let prompt = ClaudeService().makeSystemPromptForTests(
            skills: [skill],
            workingDirectory: "/tmp/project",
            settings: settings,
            session: nil,
            explicitSkillActivations: [
                ExplicitSkillActivation(
                    directoryName: "brainstorming",
                    displayName: "brainstorming",
                    content: "# Brainstorming Skill"
                )
            ]
        )

        #expect(prompt.contains("## Explicitly Activated Skills For This Turn"))
        #expect(prompt.contains("user slash command"))
        #expect(prompt.contains("# Brainstorming Skill"))
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ChatInputDirectiveResolverTests -only-testing:agentGuiTests/ClaudeServiceSlashCommandTests
```

Expected: FAIL，因为发送链路还没有 directive resolver，也没有显式 skill 上下文注入。

**Step 3: 写最小实现**

先引入发送模型，避免继续把 `sendMessage(text:)` 当成唯一入口：

```swift
struct ChatSendRequest {
    let visibleText: String
    let directives: [ChatInputDirective]
}
```

新增 `ChatInputDirectiveResolver`，负责：

- 解析本轮 directive
- 读取 skill 内容
- 生成 `ExplicitSkillActivation`
- 返回本轮有效 skill 集与 prompt 附加段落

`ChatView+Actions.swift` 改为：

- 先从 `inputText + activeInputDirectives` 生成 `ChatSendRequest`
- 再做 mention 展开、context 拼装、文件引用拼装
- 发送后清空 directive

`ACPClientService.swift` 改为：

- `sendMessage` / `resumeSend` 接收 `ChatSendRequest` 或显式激活结果
- `buildSystemPrompt` 增加 `explicitSkillActivations` 参数
- 有效 skill 集 = 全局启用 skill + 本轮显式 skill
- tools 仍可继续传本轮有效 skill 集，保证 `read_skill` tool 列表与本轮语义一致

不要在这一阶段引入 workflow / agent directive 解析；resolver 只做 skill 分支。

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: 跑关联回归测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests
```

Expected: PASS，确保 system prompt 相关改动没有回归既有逻辑。

**Step 6: Commit**

```bash
git add agentGui/Models/ChatSendRequest.swift agentGui/Services/ChatInputDirectiveResolver.swift agentGui/Views/ChatView+Actions.swift agentGui/Services/ACPClientService.swift agentGuiTests/ChatInputDirectiveResolverTests.swift agentGuiTests/ClaudeServiceSlashCommandTests.swift
git commit -m "feat: resolve slash skill directives into request context"
```

### Task 5: 为消息增加 directive 审计快照，并补齐回归测试

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Message.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MessageDirectiveMetadataTests.swift`

**Step 1: 写失败测试，固定消息审计行为**

新增测试，覆盖：

- 用户消息可存储本轮 directive 快照 JSON
- 未使用 slash 指令时，metadata 保持空值
- 只记录本轮快照，不回写到全局设置

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct MessageDirectiveMetadataTests {

    @Test func userMessageCanPersistDirectiveSnapshotJSON() async throws {
        let session = Session(title: "Slash")
        let message = Message.userMessage(text: "Fix this", session: session)
        message.inputDirectivesJSON = "[{\"kind\":\"skill\",\"directoryName\":\"brainstorming\"}]"

        #expect(message.inputDirectivesJSON?.contains("brainstorming") == true)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MessageDirectiveMetadataTests
```

Expected: FAIL，因为 `Message` 还没有 directive metadata 字段。

**Step 3: 写最小实现**

在 `Message` 上新增轻量字段，例如：

- `var inputDirectivesJSON: String?`

并在 `ChatView+Actions.swift` 创建用户消息时写入本轮 directive 快照。

快照建议只存最小信息：

- kind
- directoryName
- displayName

不要把完整 skill 内容写进消息模型，避免消息存储膨胀。

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: 跑整组回归测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/SlashCommandRegistryTests -only-testing:agentGuiTests/ChatInputCommandParserTests -only-testing:agentGuiTests/ChatComposerSlashStateTests -only-testing:agentGuiTests/ChatInputDirectiveResolverTests -only-testing:agentGuiTests/ClaudeServiceSlashCommandTests -only-testing:agentGuiTests/MessageDirectiveMetadataTests
```

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Models/Message.swift agentGui/Views/ChatView+Actions.swift agentGuiTests/MessageDirectiveMetadataTests.swift
git commit -m "feat: persist slash directive audit metadata"
```

### Task 6: 最终联调与最小文档收口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-11-chatview-slash-command-requirements.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/skills.md`

**Step 1: 更新需求文档状态说明**

在需求文档中补一小段实现状态或注意事项：

- v1 仅支持 skill 类型 slash command
- 一次仅允许 1 个 directive
- slash 为本轮激活，不改全局设置

**Step 2: 更新 skills 使用文档**

在 `docs/skills.md` 中补一句面向用户的说明：

- 可在 ChatView 输入 `/` 直接选择已安装 skill

不要把实现细节写进用户文档。

**Step 3: 跑完整测试或至少 build**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test
```

如果全量测试过重，最低要求：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: 通过，无新增编译错误。

**Step 4: 手工验收**

手工走完整路径：

1. 打开一个已配置 API Key 的会话
2. 输入 `/`
3. 选择一个未全局启用的 skill
4. 输入正文并发送
5. 确认本轮响应受该 skill 影响
6. 确认下一轮输入已默认清空该 directive

**Step 5: Commit**

```bash
git add docs/plans/2026-03-11-chatview-slash-command-requirements.md docs/skills.md
git commit -m "docs: document slash command skill activation"
```

## 3. 风险与决策点

### 风险 1：把键盘事件处理继续堆在 `MentionAwareEditor` 里

如果直接在协调器里继续加 slash、mention、Enter 优先级、Esc 关闭，会迅速变成不可维护的输入状态机。建议最少抽出 parser / state helper，避免把关键逻辑锁死在 AppKit delegate 回调中。

### 风险 2：显式 skill 激活仍然只是“提示模型自己去读”

这会让 slash command 失去产品价值。v1 即使不把完整 SKILL.md 全部塞进 prompt，也必须由客户端先完成读取与显式注入，保证“用户指定了 skill”这件事具备确定性。

### 风险 3：消息审计存太多内容

不要把 SKILL.md 正文写入 `Message`。消息模型里只保留小型 JSON 快照，真正的 skill 内容仍由 resolver 在运行时读取。

### 风险 4：过早支持多 slash 指令

skill + workflow + agent 同时存在时，优先级与冲突处理会把 v1 复杂度直接拉高。首版保持单 directive，底层模型允许扩展即可。

## 4. 完成定义

满足以下条件才算该计划完成：

- 用户在 ChatView 中输入 `/` 可选择 skill
- 选择后出现 directive chip，slash token 被清理
- 该 skill 即使未全局启用，也能在本轮稳定生效
- 本轮激活不会改写全局设置
- 请求链路能够显式记录并注入该 skill
- 至少有一组测试覆盖 catalog、parser、resolver、message metadata 四个层级

Plan complete and saved to `docs/plans/2026-03-11-chatview-slash-command-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?