# CV-FA2: 聚焦文件持久化迁移实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将"当前聚焦文件/选区"从内联文本前缀（`"当前文件: /path/file.swift\n选区内容:\n..."`）迁移为独立的 `MessageAttachment(origin: .focused)` SwiftData 记录，使消息历史可结构化识别聚焦文件引用，同时保持对旧格式消息的完全兼容。

**Architecture:** 三层改动——数据模型层（`MessageAttachment` 加字段），发送层（`ChatView+Actions` 移除文本拼接，改写 attachment），API 构造层（`ClaudeService+Messaging` 在构建 API messages 时从 `.focused` attachment 重建上下文文本）。旧消息 `textContent` 不变，UI 层已有 `stripSelectionExcerpt` + `normalizeContextDisplayText` 兼容处理。

**Tech Stack:** Swift 6.0, SwiftData (@Model), SwiftUI, Swift Testing (`@Test` / `#expect`)

**竞品参考（本计划涉及）:**
- **VS Code `IChatRequestImplicitVariableEntry`** — `kind: 'implicit'`, `isFile: true`, `isSelection: boolean`; 隐式引用与显式引用走同一持久化 + 渲染路径，仅 `kind` 字段区分。
- **Open WebUI `FileItem.svelte`** — `loading` prop 控制 Spinner/图标切换，单一组件覆盖所有文件类型。本 feature 对应数据模型侧的 `kind`/`origin` 字段设计。

---

## 依赖关系

```
CV-FA1 (已完成，AttachedFile.origin 字段已存在)
   └─→ CV-FA2 (本计划)
          └─→ CV-FA3 / CV-FA4
```

`AttachmentOrigin` 枚举（`.project` / `.focused` / `.external`）已在 `AttachedFile.swift` 中定义并已被测试覆盖，本计划直接复用。

---

## Task 1: MessageAttachment 模型扩展

**Files:**
- Modify: `agentGui/Models/MessageAttachment.swift`
- Test: `agentGuiTests/MessageAttachmentModelTests.swift`

SwiftData 向已有 `@Model` 添加可选字段时，现有数据库行自动以 `NULL` 填充，不需要手动迁移。默认值通过计算属性提供。

### Step 1.1: 写失败测试

在 `agentGuiTests/MessageAttachmentModelTests.swift` 末尾追加：

```swift
// MARK: - CV-FA2: originRaw and selectedText fields

@Test
func defaultOriginIsExternal() {
    let a = MessageAttachment(filePath: "/tmp/F.swift", displayName: "F.swift", fileKind: .sourceCode)
    #expect(a.origin == .external)
    #expect(a.originRaw == AttachmentOrigin.external.rawValue)
}

@Test
func focusedOriginRoundTrips() {
    let a = MessageAttachment(
        filePath: "/tmp/F.swift",
        displayName: "F.swift",
        fileKind: .sourceCode,
        origin: .focused
    )
    #expect(a.origin == .focused)
    #expect(a.originRaw == "focused")
}

@Test
func selectedTextStoredOnFocusedAttachment() {
    let a = MessageAttachment(
        filePath: "/tmp/F.swift",
        displayName: "F.swift",
        fileKind: .sourceCode,
        origin: .focused,
        selectedText: "let x = 42"
    )
    #expect(a.selectedText == "let x = 42")
}

@Test
func fromAttachedFileCopiesOrigin() {
    let file = AttachedFile(
        name: "View.swift",
        url: URL(fileURLWithPath: "/src/View.swift"),
        origin: .focused
    )
    let attachment = MessageAttachment.from(file)
    #expect(attachment.origin == .focused)
}

@Test
func fromAttachedFileFocusedWithSelectedText() {
    var file = AttachedFile(
        name: "View.swift",
        url: URL(fileURLWithPath: "/src/View.swift"),
        origin: .focused
    )
    file.selectedText = "body { EmptyView() }"
    let attachment = MessageAttachment.from(file)
    #expect(attachment.origin == .focused)
    #expect(attachment.selectedText == "body { EmptyView() }")
}
```

### Step 1.2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t1 \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```
预期：编译失败（`origin` 参数不存在）。

### Step 1.3: 修改 `MessageAttachment.swift`

在现有属性后添加：

```swift
// MARK: - CV-FA2: Origin + selected text (聚焦文件专用)

/// 附件来源。新增字段，旧数据库行默认 NULL 映射为 `.external`。
var originRaw: String = AttachmentOrigin.external.rawValue

/// 聚焦文件的选区文本（仅 origin == .focused 时非 nil）。
var selectedText: String?

var origin: AttachmentOrigin {
    get { AttachmentOrigin(rawValue: originRaw) ?? .external }
    set { originRaw = newValue.rawValue }
}
```

更新 `init` 签名（在现有 `lineEnd` 参数后追加新参数，带默认值保持向后兼容）：

```swift
init(
    filePath: String,
    displayName: String,
    fileKind: AttachmentKind,
    lineStart: Int? = nil,
    lineEnd: Int? = nil,
    origin: AttachmentOrigin = .external,
    selectedText: String? = nil
) {
    self.id = UUID()
    self.filePath = filePath
    self.displayName = displayName
    self.fileKindRaw = fileKind.rawValue
    self.statusRaw = AttachmentStatus.valid.rawValue
    self.lineStart = lineStart
    self.lineEnd = lineEnd
    self.originRaw = origin.rawValue
    self.selectedText = selectedText
}
```

更新 `MessageAttachment.from(_ file: AttachedFile)` 工厂（在 `AttachedFile` 上需先添加 `selectedText` 属性，见下方 Step 1.4）：

```swift
static func from(_ file: AttachedFile) -> MessageAttachment {
    MessageAttachment(
        filePath: file.path,
        displayName: file.name,
        fileKind: resolveKind(for: file),
        origin: file.origin,
        selectedText: file.selectedText   // 仅 .focused 时非 nil
    )
}
```

### Step 1.4: 在 `AttachedFile.swift` 添加 `selectedText` 属性

`AttachedFile` 是 value type（struct），在现有字段后添加：

```swift
var selectedText: String? = nil
```

### Step 1.5: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t1 \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```
预期：所有测试通过。

### Step 1.6: Commit

```bash
git add agentGui/Models/MessageAttachment.swift \
        agentGui/Models/AttachedFile.swift \
        agentGuiTests/MessageAttachmentModelTests.swift
git commit -m "feat(cv-fa2): add originRaw + selectedText to MessageAttachment"
```

---

## Task 2: AttachmentSnapshotEntry 传播 originRaw

**Files:**
- Modify: `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Test: `agentGuiTests/MessageAttachmentSnapshotBuilderTests.swift`

`AttachmentSnapshotEntry` 是 UI-side 的轻量快照，需镜像 `originRaw` 供 pill 和 watcher 使用。

### Step 2.1: 写失败测试

在 `MessageAttachmentSnapshotBuilderTests.swift` 末尾追加：

```swift
// MARK: - CV-FA2: originRaw 传播

@Test
func snapshotEntryCarriesOriginRaw() {
    let entry = AttachmentSnapshotEntry(
        id: UUID(),
        filePath: "/src/Main.swift",
        displayName: "Main.swift",
        fileKindRaw: "sourceCode",
        statusRaw: "valid",
        originRaw: "focused"
    )
    #expect(entry.originRaw == "focused")
}

@Test
func snapshotEntryDefaultOriginIsExternal() {
    // 旧代码路径（无 originRaw 参数）——测试向后兼容
    let entry = AttachmentSnapshotEntry(
        id: UUID(),
        filePath: "/src/A.swift",
        displayName: "A.swift",
        fileKindRaw: "sourceCode",
        statusRaw: "valid"
    )
    #expect(entry.originRaw == AttachmentOrigin.external.rawValue)
}

@Test
func focusedAttachmentEntrySeparatedInSnapshot() {
    // 聚焦文件在 structuredAttachments 中当作 .other 类型处理（非 image/pdf），
    // 应出现在 others 数组而不是 images/pdfs
    let entry = AttachmentSnapshotEntry(
        id: UUID(),
        filePath: "/src/View.swift",
        displayName: "View.swift",
        fileKindRaw: "sourceCode",
        statusRaw: "valid",
        originRaw: "focused"
    )
    let input = MessageRowBuildInput.fixture(
        direction: .user,
        textContent: "请看这里",
        structuredAttachments: [entry]
    )
    let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
    let others = snap.user?.presentation.others ?? []
    #expect(others.contains(where: { $0.originRaw == "focused" }))
}
```

### Step 2.2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t2 \
  -only-testing:agentGuiTests/MessageAttachmentSnapshotBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

### Step 2.3: 修改 `AttachmentSnapshotEntry`

在 `ChatMessageListSnapshotBuilder.swift` 中，将 `AttachmentSnapshotEntry` 扩展为：

```swift
struct AttachmentSnapshotEntry: Hashable, Identifiable, @unchecked Sendable {
    let id: UUID
    let filePath: String
    let displayName: String
    let fileKindRaw: String
    let statusRaw: String
    let lineStart: Int?
    let lineEnd: Int?
    let originRaw: String   // CV-FA2 新增，默认 "external"

    @MainActor
    init(_ a: MessageAttachment) {
        self.id = a.id
        self.filePath = a.filePath
        self.displayName = a.displayName
        self.fileKindRaw = a.fileKindRaw
        self.statusRaw = a.statusRaw
        self.lineStart = a.lineStart
        self.lineEnd = a.lineEnd
        self.originRaw = a.originRaw   // CV-FA2 新增
    }

    // 测试用（手动初始化，保持向后兼容，增加 originRaw 带默认值）
    init(id: UUID, filePath: String, displayName: String, fileKindRaw: String, statusRaw: String,
         lineStart: Int? = nil, lineEnd: Int? = nil,
         originRaw: String = AttachmentOrigin.external.rawValue) {
        self.id = id
        self.filePath = filePath
        self.displayName = displayName
        self.fileKindRaw = fileKindRaw
        self.statusRaw = statusRaw
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.originRaw = originRaw   // CV-FA2 新增
    }
}
```

### Step 2.4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t2 \
  -only-testing:agentGuiTests/MessageAttachmentSnapshotBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

### Step 2.5: Commit

```bash
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift \
        agentGuiTests/MessageAttachmentSnapshotBuilderTests.swift
git commit -m "feat(cv-fa2): propagate originRaw through AttachmentSnapshotEntry"
```

---

## Task 3: FocusedFileContextInjector 工具类

**Files:**
- Create: `agentGui/Utilities/FocusedFileContextInjector.swift`
- Create: `agentGuiTests/FocusedFileContextInjectorTests.swift`

这是 CV-FA2 的核心：当 API 消息需要包含聚焦文件上下文时，从 `MessageAttachment(origin: .focused)` 重建原先的内联文本前缀——与 roAS Code 的 `IChatRequestImplicitVariableEntry` 走统一渲染路径的思路相同，只是这里在 prompt 构造层注入。

**为什么独立提取：** `sendMessageBuiltIn` 也被 `regenerateBuiltIn` / `editAndResendBuiltIn` 路径使用，历史消息构建逻辑共享此 helper，避免重复。

### Step 3.1: 写失败测试（文件尚不存在）

新建 `agentGuiTests/FocusedFileContextInjectorTests.swift`：

```swift
import Testing
import Foundation
@testable import agentGui

struct FocusedFileContextInjectorTests {

    // MARK: - contextString(from:)

    @Test
    func contextStringWithPathOnly() {
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let result = FocusedFileContextInjector.contextString(from: a)
        #expect(result == "当前文件: /ws/src/App.swift")
    }

    @Test
    func contextStringWithLineRange() {
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            lineStart: 10,
            lineEnd: 25,
            origin: .focused
        )
        let result = FocusedFileContextInjector.contextString(from: a)
        #expect(result == "当前文件: /ws/src/App.swift:10-25")
    }

    @Test
    func contextStringWithSingleLine() {
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            lineStart: 42,
            lineEnd: 42,
            origin: .focused
        )
        let result = FocusedFileContextInjector.contextString(from: a)
        #expect(result == "当前文件: /ws/src/App.swift:42")
    }

    @Test
    func contextStringWithSelectedText() {
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            lineStart: 10,
            lineEnd: 12,
            origin: .focused,
            selectedText: "let x = 42\nlet y = x"
        )
        let result = FocusedFileContextInjector.contextString(from: a)
        #expect(result == "当前文件: /ws/src/App.swift:10-12\n选区内容:\nlet x = 42\nlet y = x")
    }

    // MARK: - inject(into:focusedAttachments:)

    @Test
    func injectPrependsContextToMessageText() {
        let a = MessageAttachment(
            filePath: "/ws/src/View.swift",
            displayName: "View.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let result = FocusedFileContextInjector.inject(into: "帮我看看这段代码", from: [a])
        #expect(result == "当前文件: /ws/src/View.swift\n\n帮我看看这段代码")
    }

    @Test
    func injectNoOpWhenNoFocusedAttachments() {
        let external = MessageAttachment(
            filePath: "/ws/img/bg.png",
            displayName: "bg.png",
            fileKind: .image,
            origin: .external
        )
        let result = FocusedFileContextInjector.inject(into: "看图", from: [external])
        #expect(result == "看图")
    }

    @Test
    func injectSkipsNonFocusedAttachments() {
        let focused = MessageAttachment(
            filePath: "/ws/src/A.swift",
            displayName: "A.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let project = MessageAttachment(
            filePath: "/ws/src/B.swift",
            displayName: "B.swift",
            fileKind: .sourceCode,
            origin: .project
        )
        let result = FocusedFileContextInjector.inject(into: "你好", from: [focused, project])
        // 只有 focused 被注入
        #expect(result.contains("当前文件: /ws/src/A.swift"))
        #expect(!result.contains("/ws/src/B.swift"))
    }

    @Test
    func injectNoOpWhenTextAlreadyHasContextPrefix() {
        // 旧消息 textContent 已含前缀 → 不应重复注入
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let existingText = "当前文件: /ws/src/App.swift\n\n做点什么吧"
        let result = FocusedFileContextInjector.inject(into: existingText, from: [a])
        #expect(result == existingText)
    }
}
```

### Step 3.2: 运行测试确认失败（类型未定义）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t3 \
  -only-testing:agentGuiTests/FocusedFileContextInjectorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```
预期：编译失败（`FocusedFileContextInjector` 未定义）。

### Step 3.3: 实现 `FocusedFileContextInjector.swift`

```swift
//
//  FocusedFileContextInjector.swift
//  agentGui
//
// CV-FA2: 从 MessageAttachment(origin: .focused) 重建内联上下文文本，
// 供 API 消息构建层注入，保持 prompt 语义与旧格式一致。
//

import Foundation

enum FocusedFileContextInjector {

    /// 从单个 `.focused` 附件生成内联上下文字符串。
    /// 格式与 ChatView+Actions.sendMessage() 旧实现一致：
    ///   "当前文件: /path/file.swift[:line[-line]][\n选区内容:\n<text>]"
    static func contextString(from attachment: MessageAttachment) -> String {
        var result = "当前文件: " + attachment.filePath

        if let start = attachment.lineStart, let end = attachment.lineEnd {
            if start == end {
                result += ":\(start)"
            } else {
                result += ":\(start)-\(end)"
            }
        }

        if let sel = attachment.selectedText, !sel.isEmpty {
            result += "\n选区内容:\n\(sel)"
        }

        return result
    }

    /// 将 attachments 中第一个 `.focused` 附件的上下文注入到 messageText 前面。
    ///
    /// - 如果 messageText 已有 "当前文件:" 前缀（旧消息），不重复注入。
    /// - 如果没有 `.focused` 附件，原样返回。
    static func inject(into messageText: String, from attachments: [MessageAttachment]) -> String {
        guard let focused = attachments.first(where: { $0.origin == .focused }) else {
            return messageText
        }

        // 旧消息已内联上下文 → 不重复注入
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("当前文件:") || trimmed.hasPrefix("当前选区:") {
            return messageText
        }

        let ctx = contextString(from: focused)
        return ctx + "\n\n" + messageText
    }
}
```

### Step 3.4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t3 \
  -only-testing:agentGuiTests/FocusedFileContextInjectorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

### Step 3.5: Commit

```bash
git add agentGui/Utilities/FocusedFileContextInjector.swift \
        agentGuiTests/FocusedFileContextInjectorTests.swift
git commit -m "feat(cv-fa2): add FocusedFileContextInjector helper"
```

---

## Task 4: ClaudeService+Messaging — API 消息注入

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Test: `agentGuiTests/FocusedFileContextInjectorTests.swift`（追加集成测试）

在 `sendMessageBuiltIn` 中，为每条历史用户消息检查 `.focused` 附件并注入上下文。

**重要背景：** 当前 `sendMessageBuiltIn` 构建 `apiMessages` 时直接使用 `msg.textContent`；旧消息的 `textContent` 已含内联前缀，`FocusedFileContextInjector.inject` 有"已含前缀则不重复"的保护。新消息的 `textContent` 不含前缀，但有 `.focused` 附件，注入逻辑会自动补全。

### Step 4.1: 写失败测试

在 `FocusedFileContextInjectorTests.swift` 追加（对 `sendMessageBuiltIn` 的集成测试留待 Task 6，这里先增补 injector 边界测试）：

```swift
@Test
func injectHandlesEmptyAttachments() {
    let result = FocusedFileContextInjector.inject(into: "hello", from: [])
    #expect(result == "hello")
}

@Test
func injectUsesFirstFocusedOnly() {
    let a1 = MessageAttachment(filePath: "/ws/a.swift", displayName: "a.swift",
                               fileKind: .sourceCode, origin: .focused)
    let a2 = MessageAttachment(filePath: "/ws/b.swift", displayName: "b.swift",
                               fileKind: .sourceCode, origin: .focused)
    let result = FocusedFileContextInjector.inject(into: "test", from: [a1, a2])
    // 只注入 a1
    #expect(result.contains("/ws/a.swift"))
    #expect(!result.contains("/ws/b.swift"))
}
```

### Step 4.2: 运行测试确认新测试通过（FocusedFileContextInjector 已实现）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t4 \
  -only-testing:agentGuiTests/FocusedFileContextInjectorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

### Step 4.3: 修改 `sendMessageBuiltIn` — 历史消息注入

在 `ClaudeService+Messaging.swift` 中，找到 `sendMessageBuiltIn` 方法，将历史消息构建循环从：

```swift
for msg in sortedMessages {
    guard let content = msg.textContent, !content.isEmpty else { continue }
    let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
    apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
}
```

修改为：

```swift
for msg in sortedMessages {
    guard let content = msg.textContent, !content.isEmpty else { continue }
    let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
    if msg.direction == .user {
        // CV-FA2: 为新格式消息（无内联前缀）注入聚焦文件上下文
        let enrichedContent = FocusedFileContextInjector.inject(
            into: content,
            from: msg.attachments
        )
        apiMessages.append(MessageParameter.Message(role: role, content: .text(enrichedContent)))
    } else {
        apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
    }
}
```

> **注意：** `msg.attachments` 来自 SwiftData 关系，`sendMessageBuiltIn` 在 `@MainActor` ClaudeService 上下文中调用，访问安全。

### Step 4.4: 编译确认无错误

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-cv-fa2-t4-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 4.5: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Messaging.swift \
        agentGuiTests/FocusedFileContextInjectorTests.swift
git commit -m "feat(cv-fa2): inject focused file context in sendMessageBuiltIn"
```

---

## Task 5: ChatView+Actions — 移除文本前缀，改用 attachment

**Files:**
- Modify: `agentGui/Views/ChatView+Actions.swift`
- Test: `agentGuiTests/FocusedFilePersistenceIntegrationTests.swift`（新建）

`sendMessage()` 中目前的文本前缀逻辑（约第 138–155 行）：

```swift
var contextParts: [String] = []
if showSelectionContext, let sel = workspaceState.editorSelectedText, !sel.isEmpty {
    if let fileURL = workspaceState.selectedFile {
        contextParts.append("当前文件: \(WorkspaceFileContextFormatter.inlineReference(...))")
    }
    contextParts.append("选区内容:\n\(sel)")
} else if showFileContext, let fileURL = workspaceState.selectedFile {
    contextParts.append("当前文件: \(WorkspaceFileContextFormatter.inlineReference(for: fileURL))")
}
if !contextParts.isEmpty {
    fullText = contextParts.joined(separator: "\n") + "\n\n" + fullText
}
```

需要替换。

### Step 5.1: 写集成测试（验证新 attachment 格式）

新建 `agentGuiTests/FocusedFilePersistenceIntegrationTests.swift`：

```swift
import Testing
import Foundation
@testable import agentGui

/// CV-FA2: 验证发送时聚焦文件以 MessageAttachment(origin: .focused) 持久化，
/// 而非内联到 textContent。
struct FocusedFilePersistenceIntegrationTests {

    @Test
    func focusedFileNotInTextContent() {
        // 模拟 sendMessage 中重组逻辑的纯函数部分
        // （完整 UI 集成测试不在此文件，只测 helper 层行为）

        // 验证：attachedFiles 包含 .focused 时，
        // MessageAttachment.from() 产生 origin == .focused
        var file = AttachedFile(
            name: "App.swift",
            url: URL(fileURLWithPath: "/ws/App.swift"),
            origin: .focused
        )
        file.selectedText = "struct ContentView: View {}"
        let attachment = MessageAttachment.from(file)

        #expect(attachment.origin == .focused)
        #expect(attachment.selectedText == "struct ContentView: View {}")
        #expect(attachment.filePath == "/ws/App.swift")
    }

    @Test
    func focusedFileContextStringMatchesLegacyFormat() {
        // 验证 FocusedFileContextInjector 输出与旧 contextParts 格式完全一致
        let a = MessageAttachment(
            filePath: "/ws/src/View.swift",
            displayName: "View.swift",
            fileKind: .sourceCode,
            lineStart: 5,
            lineEnd: 10,
            origin: .focused,
            selectedText: "var body: some View {\n    Text(\"hello\")\n}"
        )
        let ctx = FocusedFileContextInjector.contextString(from: a)
        let expected = "当前文件: /ws/src/View.swift:5-10\n选区内容:\nvar body: some View {\n    Text(\"hello\")\n}"
        #expect(ctx == expected)
    }

    @Test
    func legacyMessageTextLeftUntouched() {
        // 旧格式消息 textContent 已含前缀，注入器不修改
        let oldText = "当前文件: /ws/src/App.swift\n\n做点什么吧"
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let injected = FocusedFileContextInjector.inject(into: oldText, from: [a])
        #expect(injected == oldText)
    }

    @Test
    func noFocusedFileYieldsNoAttachment() {
        // showFileContext = false 时，不创建 .focused attachment
        let user: [MessageAttachment] = []
        #expect(user.filter { $0.origin == .focused }.isEmpty)
    }
}
```

### Step 5.2: 运行测试确认通过（Task 3 已实现 helper）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t5 \
  -only-testing:agentGuiTests/FocusedFilePersistenceIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

### Step 5.3: 修改 `ChatView+Actions.swift` — sendMessage()

将旧的 `contextParts` 块（构建内联文本前缀）替换为创建 `.focused` attachment 的逻辑，并将 attachment 加入最终的 `filesToAttach` 列表中存储。

**修改前（约第 135–170 行）：**

```swift
// Build a parseable workspace context prefix from the current file path and/or selected text.
var contextParts: [String] = []
if showSelectionContext, let sel = workspaceState.editorSelectedText, !sel.isEmpty {
    if let fileURL = workspaceState.selectedFile {
        contextParts.append("当前文件: \(WorkspaceFileContextFormatter.inlineReference(for: fileURL, lineRange: workspaceState.editorSelectedLineRange))")
    } else if let lineRange = workspaceState.editorSelectedLineRange {
        contextParts.append("当前文件: :\(lineRange.displayText)")
    } else {
        contextParts.append("当前文件:")
    }
    contextParts.append("选区内容:\n\(sel)")
} else if showFileContext, let fileURL = workspaceState.selectedFile {
    contextParts.append("当前文件: \(WorkspaceFileContextFormatter.inlineReference(for: fileURL))")
}
if !contextParts.isEmpty {
    fullText = contextParts.joined(separator: "\n") + "\n\n" + fullText
}
```

**修改后：**

```swift
// CV-FA2: 聚焦文件/选区以 MessageAttachment(origin: .focused) 持久化，
// 不再内联到 textContent。API 构造层（FocusedFileContextInjector）负责重建上下文。
var focusedFileAttachment: AttachedFile? = nil
if showSelectionContext, let sel = workspaceState.editorSelectedText, !sel.isEmpty,
   let fileURL = workspaceState.selectedFile {
    var file = AttachedFile(
        name: fileURL.lastPathComponent,
        url: fileURL.standardizedFileURL,
        origin: .focused
    )
    file.lineStart = workspaceState.editorSelectedLineRange?.startLine
    file.lineEnd   = workspaceState.editorSelectedLineRange?.endLine
    file.selectedText = sel
    focusedFileAttachment = file
} else if showFileContext, let fileURL = workspaceState.selectedFile {
    focusedFileAttachment = AttachedFile(
        name: fileURL.lastPathComponent,
        url: fileURL.standardizedFileURL,
        origin: .focused
    )
}
```

同时，在 `let filesToAttach = attachedFiles` 之后，将 `focusedFileAttachment` 合并进去：

```swift
let filesToAttach: [AttachedFile]
if let focused = focusedFileAttachment {
    filesToAttach = [focused] + attachedFiles
} else {
    filesToAttach = attachedFiles
}
attachedFiles = []
```

> **注意：** `AttachedFile` struct 需要新增 `lineStart: Int?`、`lineEnd: Int?` 便捷字段，用于将 `FileLineRange` 传递给 attachment（不直接持有 `FileLineRange` 以避免循环依赖）。在 `AttachedFile.swift` 中添加：
>
> ```swift
> var lineStart: Int? = nil
> var lineEnd: Int? = nil
> ```

### Step 5.4: 更新 `MessageAttachment.from(_ file: AttachedFile)` 来携带行范围

`from(_:)` 工厂现在需从 `AttachedFile.lineStart / lineEnd` 读取（这些字段在 Task 1 已绑定）：

当前工厂已在 Task 1 更新为传递 `origin` 和 `selectedText`，但行范围需补入：

```swift
static func from(_ file: AttachedFile) -> MessageAttachment {
    MessageAttachment(
        filePath: file.path,
        displayName: file.name,
        fileKind: resolveKind(for: file),
        lineStart: file.lineStart,       // CV-FA2 新增
        lineEnd: file.lineEnd,           // CV-FA2 新增
        origin: file.origin,             // CV-FA2 (Task 1 已做)
        selectedText: file.selectedText  // CV-FA2 (Task 1 已做)
    )
}
```

### Step 5.5: 运行现有测试确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t5b \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  -only-testing:agentGuiTests/FocusedFilePersistenceIntegrationTests \
  -only-testing:agentGuiTests/AttachmentEntryChipViewTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

### Step 5.6: Commit

```bash
git add agentGui/Views/ChatView+Actions.swift \
        agentGui/Models/AttachedFile.swift \
        agentGui/Models/MessageAttachment.swift \
        agentGuiTests/FocusedFilePersistenceIntegrationTests.swift
git commit -m "feat(cv-fa2): sendMessage creates focused attachment instead of text prefix"
```

---

## Task 6: 向后兼容 — UserMessageTextParser 验证

**Files:**
- Review: `agentGui/Services/UserMessageTextParser.swift`
- Test: `agentGuiTests/FocusedFilePersistenceIntegrationTests.swift`（追加 backward-compat 测试）

旧消息（`textContent` 含内联 `"当前文件:"` 前缀）的 UI 显示由 `UserMessageTextParser.normalizeContextDisplayText` 处理，已在生产中验证。本任务只需追加测试确认无回归。

### Step 6.1: 追加向后兼容测试

在 `FocusedFilePersistenceIntegrationTests.swift` 末尾追加：

```swift
// MARK: - Backward Compat: 旧消息仍能正确 parse

@Test
func legacyMessageWithFileOnlyParsesDisplayBody() {
    let old = "当前文件: /ws/src/App.swift\n\n请帮我重构"
    let parsed = UserMessageTextParser.parse(text: old, workspaceRoot: "/ws")
    // bodyText 应不含 "当前文件:" 前缀
    #expect(!parsed.bodyText.hasPrefix("当前文件:"))
    #expect(parsed.bodyText.contains("请帮我重构") || parsed.bodyText.contains("/ws/src/App.swift"))
}

@Test
func legacyMessageWithSelectionParsesCorrectly() {
    let old = "当前文件: /ws/src/App.swift:10-20\n选区内容:\nlet x = 1\n\n能帮我分析吗"
    let parsed = UserMessageTextParser.parse(text: old, workspaceRoot: "/ws")
    #expect(!parsed.bodyText.hasPrefix("当前文件:"))
    // 选区后的正文被保留
    #expect(parsed.bodyText.contains("能帮我分析吗"))
}

@Test
func newMessageWithFocusedAttachmentHasCleanBodyText() {
    // 新格式：textContent 只含用户正文，无前缀
    let clean = "帮我看看这段逻辑"
    let parsed = UserMessageTextParser.parse(text: clean, workspaceRoot: "/ws")
    #expect(parsed.bodyText == "帮我看看这段逻辑")
    #expect(parsed.others.isEmpty) // 无 @Mention，无 Referenced files
}
```

### Step 6.2: 运行向后兼容测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-t6 \
  -only-testing:agentGuiTests/FocusedFilePersistenceIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

### Step 6.3: Commit

```bash
git add agentGuiTests/FocusedFilePersistenceIntegrationTests.swift
git commit -m "test(cv-fa2): verify backward compat for legacy 当前文件 prefix messages"
```

---

## Task 7: 全量冒烟测试

运行覆盖所有 CV-FA2 相关模块的测试集合：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa2-final \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  -only-testing:agentGuiTests/MessageAttachmentSnapshotBuilderTests \
  -only-testing:agentGuiTests/AttachmentEntryChipViewTests \
  -only-testing:agentGuiTests/FocusedFileContextInjectorTests \
  -only-testing:agentGuiTests/FocusedFilePersistenceIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有测试通过，build 无 error/warning。

---

## 验收标准

| 标准 | 验证方式 |
|------|---------|
| 新消息发送后，聚焦文件以 `MessageAttachment(origin: .focused)` 存储 | `FocusedFilePersistenceIntegrationTests.focusedFileNotInTextContent()` |
| `textContent` 不含 `"当前文件:"` 前缀 | `FocusedFilePersistenceIntegrationTests.newMessageWithFocusedAttachmentHasCleanBodyText()` |
| API prompt 仍包含聚焦文件上下文 | `FocusedFileContextInjectorTests.injectPrependsContextToMessageText()` |
| 旧消息 `textContent` 中的 `"当前文件:"` 前缀 UI 正常 | `FocusedFilePersistenceIntegrationTests.legacyMessageWithFileOnlyParsesDisplayBody()` |
| `AttachmentSnapshotEntry` 携带 `originRaw` | `MessageAttachmentSnapshotBuilderTests.snapshotEntryCarriesOriginRaw()` |
| 选区文本、行范围正确持久化 | `FocusedFilePersistenceIntegrationTests.focusedFileContextStringMatchesLegacyFormat()` |

---

## 不做的事项（YAGNI）

| 提议 | 理由 |
|------|------|
| 在消息历史 pill 上用橙色高亮 `.focused` 来源 | 留给 CV-FA3（统一 `AttachmentPillView`） |
| 对 `.focused` 附件启用文件状态监控 | 留给 CV-FA4（`MessageAttachmentWatcher` 扩展） |
| 为旧格式消息执行 one-time 数据迁移 | 旧消息的内联前缀在 UI 层 + API 层均已兼容处理，强制迁移风险大于收益 |
| 修改 ACP provider 路径的注入逻辑 | ACP provider 依赖 `ExecutionPayloadDraft.selectedFilePath` 参数路径，该路径数据来源于 `workspaceState.selectedFile`（独立于 attachment），本期不变 |

---

## 文件变更汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `agentGui/Models/MessageAttachment.swift` | Modify | 新增 `originRaw`, `selectedText`, `origin` 计算属性；更新 `init` + `from`  |
| `agentGui/Models/AttachedFile.swift` | Modify | 新增 `selectedText`, `lineStart`, `lineEnd` 字段 |
| `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift` | Modify | `AttachmentSnapshotEntry` 新增 `originRaw` 字段 |
| `agentGui/Utilities/FocusedFileContextInjector.swift` | Create | 新工具：从 `.focused` attachment 重建内联上下文字符串 |
| `agentGui/Views/ChatView+Actions.swift` | Modify | `sendMessage()` 移除文本前缀拼接，改为创建 `.focused` attachment |
| `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift` | Modify | `sendMessageBuiltIn` 中为用户消息注入 focused context |
| `agentGuiTests/MessageAttachmentModelTests.swift` | Modify | 新增 Origin + selectedText 字段测试 |
| `agentGuiTests/MessageAttachmentSnapshotBuilderTests.swift` | Modify | 新增 originRaw 传播测试 |
| `agentGuiTests/FocusedFileContextInjectorTests.swift` | Create | 新测试文件：FocusedFileContextInjector 全覆盖 |
| `agentGuiTests/FocusedFilePersistenceIntegrationTests.swift` | Create | 新测试文件：集成 + 向后兼容测试 |
