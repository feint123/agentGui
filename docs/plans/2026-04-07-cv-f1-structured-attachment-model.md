# CV-F1: 结构化文件引用模型 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将消息文件引用从"嵌入 textContent 的纯文本"升级为独立的 SwiftData `@Model`，为富交互 UI（CV-F2）和文件监控（CV-F3）打下数据层基础。

**Architecture:**
- 新增 `MessageAttachment` SwiftData `@Model`，与 `Message` 建立 1-N 关系；
- `ChatView+Actions` 发送时不再把文件列表拼入 `textContent`，改为写入 `MessageAttachment` 记录；为保持向 Claude API 的兼容，`ClaudeService.sendMessage` 新增 `attachments` 参数并在内部注入文件上下文；
- 快照层（`MessageRowSnapshot`）优先从结构化 relationship 读取，旧消息通过现有文本解析兜底；
- 语义 fingerprint（`MessageRowSemanticFingerprint`）纳入 attachment 摘要，确保附件变化能触发增量重建。

**Tech Stack:** Swift 6, SwiftData (@Model / @Relationship / .cascade), Apple Swift Testing framework (`@Test`, `#expect`)

---

## VS Code 设计参考

> 阅读本节有助于理解各设计决策的来源。

VS Code 在 `src/vs/workbench/contrib/chat/browser/chatAttachmentModel/` 中将附件管理为独立的 `IChatRequestVariableEntry[]` 集合，与消息文本完全分离。每条 entry 包含：

| 字段 | 含义 | 对应本方案 |
|------|------|-----------|
| `id: string` | 唯一标识 | `MessageAttachment.id: UUID` |
| `name: string` | 展示名 | `MessageAttachment.displayName: String` |
| `value: URI` | 文件绝对路径 | `MessageAttachment.filePath: String` |
| `kind: 'file'│'folder'│'selection'` | 附件类型 | `MessageAttachment.fileKind: AttachmentKind` |
| `range?: IRange` | 可选行范围 | `MessageAttachment.lineStart/lineEnd: Int?` |
| `isFile: boolean` | 是文件还是目录 | 由 `fileKind` 隐含 |

关键设计原则（借鉴）：
1. **附件与正文分离**：请求对象持有 `{ message: string, attachments: Entry[] }`，文本干净；
2. **状态独立存储**：VS Code 维护 `deletedContext: Set<string>` 追踪已删除文件，本方案用 `AttachmentStatus` enum 实现等价语义；
3. **快照序列化**：发送前把结构化 entry 重新"投影"成 API 所需格式（本方案在 `ClaudeService` 内完成注入）。

---

## 改动文件清单

| 操作 | 文件 |
|------|------|
| **新建** | `agentGui/Models/MessageAttachment.swift` |
| **修改** | `agentGui/Models/Message.swift` |
| **修改** | `agentGui/ViewModels/MessageRowSnapshot.swift` |
| **修改** | `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift` |
| **修改** | `agentGui/Views/ChatView+Actions.swift` |
| **修改** | `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift` |
| **新建** | `agentGuiTests/MessageAttachmentModelTests.swift` |
| **新建** | `agentGuiTests/MessageAttachmentSnapshotBuilderTests.swift` |

---

## Task 1：定义 `MessageAttachment` SwiftData 模型

**Files:**
- Create: `agentGui/Models/MessageAttachment.swift`

### Step 1：写失败测试

在 `agentGuiTests/MessageAttachmentModelTests.swift` 中写：

```swift
import Testing
@testable import agentGui

@MainActor
struct MessageAttachmentModelTests {

    @Test
    func initSetsDefaultStatus() {
        let a = MessageAttachment(filePath: "/tmp/Foo.swift", displayName: "Foo.swift", fileKind: .sourceCode)
        #expect(a.status == .valid)
        #expect(a.lineStart == nil)
        #expect(a.lineEnd == nil)
    }

    @Test
    func fileTypeDetectedFromExtension() {
        let swift   = MessageAttachment(filePath: "/src/Foo.swift",  displayName: "Foo.swift",  fileKind: .sourceCode)
        let png     = MessageAttachment(filePath: "/img/bg.png",     displayName: "bg.png",     fileKind: .image)
        let pdf     = MessageAttachment(filePath: "/doc/spec.pdf",   displayName: "spec.pdf",   fileKind: .pdf)
        let other   = MessageAttachment(filePath: "/doc/notes.txt",  displayName: "notes.txt",  fileKind: .other)
        #expect(swift.fileKind == .sourceCode)
        #expect(png.fileKind   == .image)
        #expect(pdf.fileKind   == .pdf)
        #expect(other.fileKind == .other)
    }

    @Test
    func lineRangeRoundTrips() {
        let a = MessageAttachment(filePath: "/tmp/F.swift", displayName: "F.swift",
                                  fileKind: .sourceCode, lineStart: 10, lineEnd: 42)
        #expect(a.lineStart == 10)
        #expect(a.lineEnd   == 42)
    }
}
```

运行测试，预期编译错误（类型不存在）。

### Step 2：实现模型

创建 `agentGui/Models/MessageAttachment.swift`：

```swift
import SwiftData
import Foundation

// MARK: - Enums (Codable for SwiftData persistence)

enum AttachmentKind: String, Codable {
    /// Swift / Objective-C / TypeScript 等源代码文件
    case sourceCode
    /// PNG / JPEG / WEBP / HEIC / GIF / TIFF / BMP
    case image
    /// PDF 文档
    case pdf
    /// 目录/文件夹
    case directory
    /// 其他（Markdown、JSON、文本等）
    case other
}

enum AttachmentStatus: String, Codable {
    /// 文件存在且未修改（相对于消息发送时刻）
    case valid
    /// 文件发送后被删除或移动
    case missing
    /// 文件发送后内容已变更
    case modified
}

// MARK: - Model

@Model
final class MessageAttachment {
    var id: UUID
    var filePath: String
    var displayName: String
    var fileKindRaw: String        // 存 AttachmentKind.rawValue
    var statusRaw: String          // 存 AttachmentStatus.rawValue
    var lineStart: Int?
    var lineEnd: Int?

    /// 反向关系（由 Message.attachments 拥有）
    var message: Message?

    var fileKind: AttachmentKind {
        get { AttachmentKind(rawValue: fileKindRaw) ?? .other }
        set { fileKindRaw = newValue.rawValue }
    }

    var status: AttachmentStatus {
        get { AttachmentStatus(rawValue: statusRaw) ?? .valid }
        set { statusRaw = newValue.rawValue }
    }

    init(
        filePath: String,
        displayName: String,
        fileKind: AttachmentKind,
        lineStart: Int? = nil,
        lineEnd: Int? = nil
    ) {
        self.id = UUID()
        self.filePath = filePath
        self.displayName = displayName
        self.fileKindRaw = fileKind.rawValue
        self.statusRaw = AttachmentStatus.valid.rawValue
        self.lineStart = lineStart
        self.lineEnd = lineEnd
    }
}

// MARK: - Convenience factory from AttachedFile

extension MessageAttachment {
    static func from(_ file: AttachedFile) -> MessageAttachment {
        MessageAttachment(
            filePath: file.path,
            displayName: file.name,
            fileKind: resolveKind(for: file)
        )
    }

    private static func resolveKind(for file: AttachedFile) -> AttachmentKind {
        if file.isImage { return .image }
        if file.isPDF   { return .pdf }
        let ext = (file.path as NSString).pathExtension.lowercased()
        let sourcetExts: Set<String> = [
            "swift","m","mm","h","cpp","c","ts","tsx","js","jsx",
            "py","rb","go","rs","kt","java","cs","php"
        ]
        if sourcetExts.contains(ext) { return .sourceCode }
        return .other
    }
}
```

### Step 3：运行测试，确认通过

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cvf1-t1 \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

预期：全部 passed。

### Step 4：Commit

```
git add agentGui/Models/MessageAttachment.swift agentGuiTests/MessageAttachmentModelTests.swift
git commit -m "feat(CV-F1): add MessageAttachment SwiftData model with kind/status enums"
```

---

## Task 2：在 `Message` 上添加 `attachments` 关系

**Files:**
- Modify: `agentGui/Models/Message.swift`

### Step 1：写失败测试

在 `MessageAttachmentModelTests.swift` 中追加：

```swift
    @Test
    func messageHoldsAttachments() {
        let session = Session.fixture(title: "CV-F1 Test")
        let message = Message.userFixture(session: session)
        let a1 = MessageAttachment(filePath: "/src/A.swift", displayName: "A.swift", fileKind: .sourceCode)
        let a2 = MessageAttachment(filePath: "/img/b.png",   displayName: "b.png",   fileKind: .image)
        message.attachments = [a1, a2]
        #expect(message.attachments.count == 2)
        #expect(message.attachments.first?.displayName == "A.swift")
    }
```

运行，预期编译错误（`attachments` 不存在）。

### Step 2：在 `Message.swift` 中添加关系

在 `agentRounds` relationship 声明之后插入：

```swift
    /// 结构化文件附件（CV-F1：替代 textContent 中的 "Referenced files:" 段落）
    @Relationship(deleteRule: .cascade, inverse: \MessageAttachment.message)
    var attachments: [MessageAttachment] = []
```

> ⚠️ **注意**：SwiftData 会自动生成轻量级迁移（新增可选关系不需要手写 MigrationPlan）。
> 旧数据库中现有 `Message` 记录的 `attachments` 将为空数组，文本解析兜底层（Task 6）会向前兼容。

### Step 3：运行测试，确认通过

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cvf1-t2 \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

### Step 4：Commit

```
git add agentGui/Models/Message.swift agentGuiTests/MessageAttachmentModelTests.swift
git commit -m "feat(CV-F1): add Message.attachments cascade relationship"
```

---

## Task 3：将结构化附件纳入 `MessageRowBuildInput` 和 `MessageRowSemanticFingerprint`

**Files:**
- Modify: `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`

> **为何要做：** `MessageRowBuildInput` 是快照构建的数据来源；`MessageRowSemanticFingerprint` 用于增量缓存 key 判等。若附件变化不体现在 fingerprint 中，附件状态更新（CV-F3 写入 status）将无法触发 UI 重建。

### Step 1：写失败测试（fingerprint 层）

在 `MessageAttachmentSnapshotBuilderTests.swift` 中写：

```swift
import Testing
@testable import agentGui

struct MessageAttachmentSnapshotBuilderTests {

    @Test
    func fingerprintDiffersWhenAttachmentAdded() {
        let base = MessageRowBuildInput.fixture(
            id: UUID(),
            structuredAttachments: []
        )
        let withAttachment = MessageRowBuildInput.fixture(
            id: base.id,
            structuredAttachments: [
                .init(id: UUID(), filePath: "/src/A.swift",
                      displayName: "A.swift", fileKindRaw: "sourceCode",
                      statusRaw: "valid")
            ]
        )
        let fp1 = MessageRowSemanticFingerprint(base)
        let fp2 = MessageRowSemanticFingerprint(withAttachment)
        #expect(fp1 != fp2)
    }

    @Test
    func fingerprintEqualWhenAttachmentUnchanged() {
        let attachmentID = UUID()
        let entry = AttachmentSnapshotEntry(
            id: attachmentID, filePath: "/src/A.swift",
            displayName: "A.swift", fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        let a = MessageRowBuildInput.fixture(id: UUID(), structuredAttachments: [entry])
        let b = MessageRowBuildInput.fixture(id: a.id, structuredAttachments: [entry])
        #expect(MessageRowSemanticFingerprint(a) == MessageRowSemanticFingerprint(b))
    }
}
```

运行，预期编译错误（`structuredAttachments` / `AttachmentSnapshotEntry` 不存在）。

### Step 2：实现

在 `ChatMessageListSnapshotBuilder.swift` 中：

**2a. 新增值类型 `AttachmentSnapshotEntry`**（在 `WorkspaceDependencyFingerprint` 附近添加）：

```swift
/// 轻量附件摘要，不依赖 SwiftData，跨 Actor 安全传递。
struct AttachmentSnapshotEntry: Hashable, Identifiable, @unchecked Sendable {
    let id: UUID
    let filePath: String
    let displayName: String
    let fileKindRaw: String
    let statusRaw: String

    @MainActor
    init(_ a: MessageAttachment) {
        self.id = a.id
        self.filePath = a.filePath
        self.displayName = a.displayName
        self.fileKindRaw = a.fileKindRaw
        self.statusRaw = a.statusRaw
    }

    // 测试用
    init(id: UUID, filePath: String, displayName: String, fileKindRaw: String, statusRaw: String) {
        self.id = id; self.filePath = filePath; self.displayName = displayName
        self.fileKindRaw = fileKindRaw; self.statusRaw = statusRaw
    }
}
```

**2b. 在 `MessageRowBuildInput` 中添加字段**（加在 `workspaceDependency` 之前）：

```swift
    let structuredAttachments: [AttachmentSnapshotEntry]
```

`@MainActor init(message: Message, workspaceRoot: String)` 中追加：

```swift
        self.structuredAttachments = message.attachments.map(AttachmentSnapshotEntry.init)
```

直接 memberwise `init` 和 `fixture()` 中添加参数 `structuredAttachments: [AttachmentSnapshotEntry] = []`。

**2c. 在 `MessageRowSemanticFingerprint` 中添加字段**：

```swift
    let attachments: [AttachmentSnapshotEntry]
```

`init(_ message: MessageRowBuildInput)` 中追加：

```swift
        self.attachments = message.structuredAttachments
```

### Step 3：运行测试，确认通过

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cvf1-t3 \
  -only-testing:agentGuiTests/MessageAttachmentSnapshotBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

### Step 4：Commit

```
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift \
        agentGuiTests/MessageAttachmentSnapshotBuilderTests.swift
git commit -m "feat(CV-F1): add AttachmentSnapshotEntry to MessageRowBuildInput and fingerprint"
```

---

## Task 4：更新 `MessageAttachmentSnapshot` — 结构化优先，文本解析兜底

**Files:**
- Modify: `agentGui/ViewModels/MessageRowSnapshot.swift`

> **VS Code 类比：** chatModel 的 `resolvedVariables` / `attachments` 字段在 request 发出后永久存储在 persistence 层，展现时直接读取。本任务同理：优先读 SwiftData 关系，解析 textContent 仅作遗留兼容。

### Step 1：写测试

在 `MessageAttachmentSnapshotBuilderTests.swift` 追加：

```swift
    @Test
    func snapshotFromStructuredDataIgnoresTextParsing() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/src/Main.swift",
            displayName: "Main.swift", fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        let input = MessageRowBuildInput.fixture(
            direction: .user,
            // textContent 故意带旧格式，验证结构化优先
            textContent: "hello\n\nReferenced files:\n- /legacy/Old.swift",
            structuredAttachments: [entry]
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        // 结构化来源：只有 Main.swift
        #expect(snap.user?.presentation.others == ["/src/Main.swift"])
        #expect(snap.user?.presentation.others.contains("/legacy/Old.swift") == false)
    }

    @Test
    func snapshotFallsBackToTextParsingWhenNoStructuredAttachments() {
        let input = MessageRowBuildInput.fixture(
            direction: .user,
            textContent: "hello\n\nReferenced files:\n- /legacy/Old.swift",
            structuredAttachments: []
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.user?.presentation.others == ["/legacy/Old.swift"])
    }

    @Test
    func agentSnapshotReadsStructuredAttachments() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/img/chart.png",
            displayName: "chart.png", fileKindRaw: "image", statusRaw: "valid"
        )
        let input = MessageRowBuildInput.fixture(
            direction: .agent,
            structuredAttachments: [entry]
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.agent?.attachments.images == ["/img/chart.png"])
    }
```

运行，预期失败（逻辑尚未实现）。

### Step 2：实现

在 `MessageRowSnapshot.swift` 中：

**2a. 更新 `MessageAttachmentSnapshot`** — 增加便利属性：

```swift
struct MessageAttachmentSnapshot: Equatable, @unchecked Sendable {
    let images: [String]
    let pdfs: [String]
    let others: [String]

    static let empty = MessageAttachmentSnapshot(images: [], pdfs: [], others: [])

    var hasMedia: Bool { !images.isEmpty || !pdfs.isEmpty }

    // 新增：从结构化条目构建
    static func fromStructured(_ entries: [AttachmentSnapshotEntry]) -> MessageAttachmentSnapshot {
        var images: [String] = []
        var pdfs: [String] = []
        var others: [String] = []
        for e in entries {
            switch AttachmentKind(rawValue: e.fileKindRaw) ?? .other {
            case .image:       images.append(e.filePath)
            case .pdf:         pdfs.append(e.filePath)
            case .sourceCode, .directory, .other: others.append(e.filePath)
            }
        }
        return MessageAttachmentSnapshot(images: images, pdfs: pdfs, others: others)
    }
}
```

**2b. 在 `MessageRowSnapshot.make(for:workspaceRoot:)` 中：**

替换 agent snapshot 构建部分（`AgentRowSnapshot` 初始化器中的 `attachments:` 参数）：

```swift
// 旧代码：
//   attachments: attachmentSnapshot(from: message.textContent ?? ""),
// 新代码：
attachments: message.structuredAttachments.isEmpty
    ? attachmentSnapshot(from: message.textContent ?? "")
    : MessageAttachmentSnapshot.fromStructured(message.structuredAttachments),
```

同理，`UserRowSnapshot` 构建中，在 `UserMessagePresentation.make(from:)` 之前：如果 `message.structuredAttachments` 非空，则将结构化附件注入 `ParsedUserMessageText`，并覆盖 `parsed.images / .pdfs / .others`：

```swift
if message.direction == .user {
    let rawText = message.textContent ?? ""
    var parsed = UserMessageTextParser.parse(text: rawText, workspaceRoot: workspaceRoot)
    // 结构化优先覆盖文件列表
    if !message.structuredAttachments.isEmpty {
        parsed = parsed.replacingAttachments(with: message.structuredAttachments)
    }
    userSnapshot = UserRowSnapshot(
        bodyText: parsed.bodyText,
        presentation: UserMessagePresentation.make(from: parsed)
    )
}
```

**2c. 在 `UserMessageTextParser.swift` 中给 `ParsedUserMessageText` 添加替换方法：**

```swift
extension ParsedUserMessageText {
    /// 用结构化附件覆盖文件列表，保留 bodyText 和 inlineSegments。
    func replacingAttachments(with entries: [AttachmentSnapshotEntry]) -> ParsedUserMessageText {
        var imgs: [String] = []
        var pdfs: [String] = []
        var others: [String] = []
        for e in entries {
            switch AttachmentKind(rawValue: e.fileKindRaw) ?? .other {
            case .image:       imgs.append(e.filePath)
            case .pdf:         pdfs.append(e.filePath)
            case .sourceCode, .directory, .other: others.append(e.filePath)
            }
        }
        return ParsedUserMessageText(
            bodyText: bodyText,
            directiveAuditItems: directiveAuditItems,
            inlineSegments: inlineSegments,
            images: imgs,
            pdfs: pdfs,
            others: others
        )
    }
}
```

### Step 3：运行测试

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cvf1-t4 \
  -only-testing:agentGuiTests/MessageAttachmentSnapshotBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

### Step 4：Commit

```
git add agentGui/ViewModels/MessageRowSnapshot.swift \
        agentGui/Services/UserMessageTextParser.swift \
        agentGuiTests/MessageAttachmentSnapshotBuilderTests.swift
git commit -m "feat(CV-F1): MessageAttachmentSnapshot reads from structured model first, text-parsing fallback"
```

---

## Task 5：更新 `ChatView+Actions` — 发送时写入结构化附件

**Files:**
- Modify: `agentGui/Views/ChatView+Actions.swift`

> **当前行为：** 发送时把 `attachedFiles` 拼接成 `"Referenced files:\n- path"` 追加到 `fullText`，连同消息正文一起存入 `Message.textContent`。
>
> **目标：**
> 1. 把文件列表从 `fullText` 中移除（发给 Claude 的文本保持干净）；
> 2. 创建 `MessageAttachment` 记录，写入 `userMessage.attachments`；
> 3. 让 `ClaudeService.sendMessage` 负责把文件路径注入 API 上下文（Task 6）。

### Step 1：写集成测试（行为验证层）

在 `MessageAttachmentModelTests.swift` 追加：

```swift
    @Test
    func attachedFilesWrittenToRelationshipNotText() {
        let session = Session.fixture(title: "Send Test")
        let a = AttachedFile(name: "Foo.swift", url: URL(fileURLWithPath: "/src/Foo.swift"))
        let message = Message.userMessage(text: "看这个文件", session: session)
        message.attachments = [MessageAttachment.from(a)]

        // textContent 里不应再含 "Referenced files:"
        let text = message.textContent ?? ""
        #expect(!text.contains("Referenced files:"))
        // 结构化附件应存在
        #expect(message.attachments.count == 1)
        #expect(message.attachments.first?.filePath == "/src/Foo.swift")
    }
```

此测试是对预期行为的规格说明，先运行确认当前代码下**失败**（`textContent` 含有 "Referenced files:"）。

### Step 2：实现

定位并修改 `ChatView+Actions.swift` 中 `sendMessage()`（或其等效入口函数）内的文件引用处理块：

```swift
// 删除旧代码：
// if !attachedFiles.isEmpty {
//     let refs = attachedFiles.map { "- \($0.path)" }.joined(separator: "\n")
//     fullText += "\n\nReferenced files:\n\(refs)"
// }

// 新代码在消息保存后立即追加：（在 modelContext.insert(userMessage) 之后）
for file in attachedFiles {
    let attachment = MessageAttachment.from(file)
    attachment.message = userMessage
    modelContext.insert(attachment)
}
```

同时更新 `claudeService.sendMessage(...)` 调用，增加 `attachments` 参数（Task 6 完成后补上）。此步先传空数组占位以保持编译：

```swift
try await claudeService.sendMessage(
    text: auditedText,
    session: session,
    attachments: attachedFiles,   // ← 新增（Task 6 实现后生效）
    modelId: modelId,
    ...
)
```

### Step 3：运行测试

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cvf1-t5 \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

### Step 4：Commit

```
git add agentGui/Views/ChatView+Actions.swift \
        agentGuiTests/MessageAttachmentModelTests.swift
git commit -m "feat(CV-F1): write MessageAttachment records on send, remove file refs from textContent"
```

---

## Task 6：更新 `ClaudeService.sendMessage` — 从附件列表重建文件上下文

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`

> **为何要做：** 步骤 5 把文件路径从 `textContent` 里移走了，Claude 必须通过另一条路径获知文件列表。`ClaudeService` 是注入上下文的合适位置，在构建 API 请求时把 `[AttachedFile]` 拼入 system/user context 块中。
>
> **VS Code 类比：** VS Code 的 chat provider 在 `prepareSession` / `provideResponse` 阶段读取 `IChatRequestVariableEntry[]` 并用 `TextDocumentSnapshot` 展开为 file content，然后注入到 messages 数组之前。本方案仅添加路径列表（不读取文件内容），与现有行为等价。

### Step 1：写测试

在 `MessageAttachmentModelTests.swift` 追加（需要 mock ClaudeService 调用入口，或通过 spy 方式验证）：

```swift
    @Test
    func sendMessageWithAttachmentsAppendsFileRefsToContext() async throws {
        // 通过检查 enqueue command 的 text 来验证文件路径被注入
        let spy = EnqueueCommandSpy()
        let service = ClaudeService.fixtureWithSpy(spy)
        let session = Session.fixture(title: "Attach Test")
        let attachments = [
            AttachedFile(name: "A.swift", url: URL(fileURLWithPath: "/src/A.swift"))
        ]
        // 调用新签名
        try await service.sendMessage(
            text: "请看代码",
            session: session,
            attachments: attachments,
            modelId: "claude-opus-4-5",
            selectedFilePath: nil,
            selectedText: nil,
            directives: [],
            modelContext: ModelContext.inMemory()
        )
        #expect(spy.lastText?.contains("Referenced files:") == true)
        #expect(spy.lastText?.contains("/src/A.swift") == true)
    }
```

> **Note：** 若 `ClaudeService` 内部难以 spy，可改为集成测试：发送消息后从 session.messages 读 textContent 验证。测试方式灵活——关键是验证 _Claude 收到的文本_ 含有路径。

### Step 2：更新函数签名

在 `ClaudeService+Messaging.swift` 中，将 `sendMessage` 签名更新为：

```swift
func sendMessage(
    text: String,
    session: Session,
    attachments: [AttachedFile] = [],       // ← 新增，默认空数组保持向后兼容
    modelId: String,
    selectedFilePath: String? = nil,
    selectedText: String? = nil,
    directives: [ChatInputDirective] = [],
    modelContext: ModelContext
) async throws
```

在函数体内，构建 `resolveEnqueueCommand` 调用之前，将附件重新拼入 text：

```swift
var enrichedText = text
if !attachments.isEmpty {
    let refs = attachments.map { "- \($0.path)" }.joined(separator: "\n")
    enrichedText += "\n\nReferenced files:\n\(refs)"
}
// 之后传 enrichedText 而非 text 给 resolveEnqueueCommand
```

### Step 3：更新 `ChatView+Actions.swift` 调用（去掉 Task 5 的占位）

将 `claudeService.sendMessage` 调用中的 `attachments: attachedFiles` 保留（Task 5 已写入）。

### Step 4：运行测试

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cvf1-t6 \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

### Step 5：Commit

```
git add agentGui/Services/ClaudeService/ClaudeService+Messaging.swift \
        agentGuiTests/MessageAttachmentModelTests.swift
git commit -m "feat(CV-F1): ClaudeService.sendMessage accepts attachments, injects file context before API call"
```

---

## Task 7：向后兼容验证 — 旧消息文本解析不受影响

**Files:**
- 无新文件；在已有测试中追加场景

> Task 4 的 Step 2 已经在 `MessageRowSnapshot.make` 中保留了文本解析兜底（`structuredAttachments.isEmpty` 时走旧路径）。本 Task 是显式验证，确保现有功能不退化。

### Step 1：写回归测试

在 `MessageAttachmentSnapshotBuilderTests.swift` 追加：

```swift
    // === 后向兼容场景（模拟旧消息） ===

    @Test
    func legacyUserMessageWithNoAttachmentsUsesTextParsing() {
        let input = MessageRowBuildInput.fixture(
            direction: .user,
            textContent: "分析一下\n\nReferenced files:\n- /old/File.swift\n- /old/Lib.swift",
            structuredAttachments: []
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.user?.presentation.others.count == 2)
        #expect(snap.user?.presentation.others.contains("/old/File.swift") == true)
    }

    @Test
    func legacyAgentMessageWithNoAttachmentsUsesTextParsing() {
        let input = MessageRowBuildInput.fixture(
            direction: .agent,
            textContent: "done\n\nReferenced files:\n- /out/result.png",
            structuredAttachments: []
        )
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.agent?.attachments.images == ["/out/result.png"])
    }

    @Test
    func emptyTextContentProducesEmptySnapshot() {
        let input = MessageRowBuildInput.fixture(direction: .user, textContent: nil, structuredAttachments: [])
        let snap = MessageRowSnapshot.make(for: input, workspaceRoot: "/ws")
        #expect(snap.user?.presentation.others.isEmpty == true)
    }
```

### Step 2：运行全套附件测试

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cvf1-t7 \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  -only-testing:agentGuiTests/MessageAttachmentSnapshotBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

预期：全部 passed。

### Step 3：Commit

```
git add agentGuiTests/MessageAttachmentSnapshotBuilderTests.swift
git commit -m "test(CV-F1): add backward-compat regression tests for legacy text-parsed attachments"
```

---

## Task 8：质量烟雾测试（Smoke）

### Step 1：运行现有消息投影相关测试，确认无退化

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cvf1-smoke \
  -only-testing:agentGuiTests/ChatMessageListProjectionModelConcurrencyTests \
  -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  -only-testing:agentGuiTests/MessageAttachmentSnapshotBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

预期：全部 passed。

### Step 2：手工冒烟

1. Build & Run，打开 agentGui；
2. 在 Composer 拖入 1 个 `.swift` 文件 + 1 个 `.png` 文件，发送消息；
3. 验证消息气泡中文件徽章仍然显示（`"引用了 1 个文件"` + 图片缩略图）；
4. 验证数据库中 `MessageAttachment` 记录可被 `modelContext` 查出（可用 `lldb` / `ModelContext` 调试断点验证）；
5. 切换到旧会话（发送前生成的消息），验证 attachments badge 仍正常渲染（后向兼容路径）。

### Step 3：最终 Commit

若 Step 1-2 全部通过：

```
git tag cv-f1-complete
git push origin HEAD
```

---

## 验收标准回顾

| 序号 | 标准 | 验证方式 |
|------|------|---------|
| AC-1 | 新消息使用 `MessageAttachment` 关系存储文件 | `MessageAttachmentModelTests.attachedFilesWrittenToRelationshipNotText` |
| AC-2 | `message.textContent` 不再含 `"Referenced files:"` 段落 | 同上 |
| AC-3 | Claude 仍收到文件路径列表 | `MessageAttachmentModelTests.sendMessageWithAttachmentsAppendsFileRefsToContext` |
| AC-4 | 旧消息（无结构化 attachment）展示无退化 | `legacyUserMessageWithNoAttachmentsUsesTextParsing` 等 |
| AC-5 | 附件变化（status/kind 改变）触发快照 fingerprint 失效 | `MessageAttachmentSnapshotBuilderTests.fingerprintDiffersWhenAttachmentAdded` |
| AC-6 | 所有原有投影测试通过 | Task 8 质量烟雾 |

---

## 依赖关系

```
CV-F1 (本计划)
  ├─→ CV-F2: FileReferencePillView, hover 预览（依赖 MessageAttachment.status）
  └─→ CV-F3: MessageAttachmentWatcher（依赖 MessageAttachment.id + status 可写）
```

---

## 不做的事项（YAGNI）

| 提议 | 排除原因 |
|------|---------|
| 文件内容快照（发送时保存副本） | 存储开销大，CV-F3 可通过 mtime 检测变更 |
| 自动修复 `AttachmentStatus.modified` | 属于 CV-F3 职责 |
| 批量迁移旧消息文本 → 结构化记录 | SwiftData 没有批量 migration 钩子；兜底层已覆盖旧消息 |
| Agent 消息文件引用结构化 | Agent 响应中的文件引用目前仅用于展示，无与用户消息等价的发送流程 |
