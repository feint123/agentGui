# CV-F2: 文件引用富交互 UI 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将现有的"引用了 N 个文件"计数 badge，升级为每个文件独立的可交互 pill chip，展示文件图标 + 文件名 + 可选行范围 + 状态色；hover 弹出代码预览 popover；单击在工作区编辑器中打开并跳转到文件。

**Architecture:** 从快照构建层向视图层全链路传递 `AttachmentSnapshotEntry`（已含 `displayName / statusRaw / lineStart / lineEnd`），替换现有的 `[String]` 路径列表；新建两个独立 View 组件（`FileReferencePillView` + `FileReferencePreviewPopover`），最后在 `MessageBubbleView` 中接入。

**Tech Stack:** SwiftUI / Swift 6 · SwiftData · `WorkspaceState.showFileDetail` 导航 · `SyntaxHighlightedCodeTextView` 预览 · `CodeSyntaxHighlightingService` 语法高亮 · `ChatMotion` 动效 token · `UserMessageWrappingLayout`（共享 FlowLayout）

---

## 前置条件

CV-F1 已完成，以下已存在：
- `MessageAttachment` — `@Model`，含 `filePath / displayName / fileKindRaw / statusRaw / lineStart / lineEnd`
- `AttachmentSnapshotEntry` — 跨 Actor 安全值类型，含相同字段
- `MessageAttachmentSnapshot.fromStructured(_:)` — 从结构化条目构建快照
- `sendMessage()` — 发送时写入 `MessageAttachment` 而非拼入纯文本

---

## 竞品参考摘要

### Open WebUI（Svelte `FileItem.svelte`）
- `small` 模式：`HStack { 类型图标 – displayName – 文件大小 }`，点击打开 `FileItemModal`
- `dismissible` 模式：右上角悬停出现 ×
- 状态靠 `loading` prop 驱动 Spinner，无缺失/修改态（因文件在服务端）
- **UI 洞察**：pill 内 icon + name 的 compact 布局已验证；macOS 上对应行为是点击后在编辑器而非新窗口打开

### VS Code Copilot Chat（TypeScript `chatAttachmentsContentPart.ts`）
- 文件引用渲染为 `<a>` pill：文件 icon + filename（FileKind 决定 icon）+ 可选 `:line`
- 悬停（hover）→ `IChatMarkdownContent` hover widget 显示代码片段预览
- 单击 → `openerService.open(uri, { selection: lineRange })` 在编辑器打开并跳行
- 状态：`ChatAttachmentModel` 被 `ChatFileWatcher` 标记 `.missing`，pill 变 strikethrough
- **UI 洞察**：pill 宽度固定约 `180px`，截断显示文件名，完整路径在 tooltip

---

## 依赖图（当前）

```
sendMessage()
    └─ MessageAttachment (@Model)
           └─ AttachmentSnapshotEntry (cross-actor value)
                  ├─ MessageAttachmentSnapshot.others: [String]  ← 待升级
                  └─ ParsedUserMessageText.others: [String]       ← 待升级
```

目标状态：

```
AttachmentSnapshotEntry
    ├─ MessageAttachmentSnapshot.others: [AttachmentSnapshotEntry]
    ├─ ParsedUserMessageText.others:     [AttachmentSnapshotEntry]
    └─ UserMessagePresentation.others:   [AttachmentSnapshotEntry]
           └─ FileReferencePillView (per entry)
                    └─ FileReferencePreviewPopover (hover popover)
```

---

## 修改文件速查

| 文件（路径均相对 `agentGui/`） | 变更类型 |
|---|---|
| `ViewModels/MessageRowSnapshot.swift` | 修改：`MessageAttachmentSnapshot.others: [AttachmentSnapshotEntry]` |
| `Services/UserMessageTextParser.swift` | 修改：`ParsedUserMessageText.others: [AttachmentSnapshotEntry]` |
| `ViewModels/UserMessagePresentation.swift` | 修改：`UserMessagePresentation.others: [AttachmentSnapshotEntry]` |
| `Views/UserMessageInlineContentView.swift` | 提取：私有 `UserMessageWrappingLayout` → 内部可见 |
| `Views/FileReferencePillView.swift` | 新建 |
| `Views/FileReferencePreviewPopover.swift` | 新建 |
| `Views/MessageBubbleView.swift` | 修改：接入 pill list，注入 `WorkspaceState` |
| `agentGuiTests/FileReferencePillSnapshotTests.swift` | 新建 |

---

## Task 1: 升级 `MessageAttachmentSnapshot.others`

**目标文件：**
- 修改：`agentGui/ViewModels/MessageRowSnapshot.swift`（1–35 行）

**背景：** 当前 `others: [String]` 仅保留路径，丢失了 `displayName / statusRaw / lineStart / lineEnd`。需改为 `[AttachmentSnapshotEntry]`。

---

### Step 1-1: 编写失败单元测试

在 `agentGuiTests/FileReferencePillSnapshotTests.swift`（新建）写：

```swift
import XCTest
@testable import agentGui

final class FileReferencePillSnapshotTests: XCTestCase {

    // MARK: - fromStructured preserves metadata

    func test_fromStructured_preservesDisplayName() {
        let entries = [
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/ClaudeService.swift",
                displayName: "ClaudeService.swift",
                fileKindRaw: "sourceCode",
                statusRaw: "valid"
            )
        ]
        let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
        XCTAssertEqual(snapshot.others.first?.displayName, "ClaudeService.swift")
    }

    func test_fromStructured_preservesModifiedStatus() {
        let entries = [
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/foo.swift",
                displayName: "foo.swift",
                fileKindRaw: "sourceCode",
                statusRaw: "modified"
            )
        ]
        let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
        XCTAssertEqual(snapshot.others.first?.statusRaw, "modified")
    }

    func test_fromStructured_preservesMissingStatus() {
        let entries = [
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/gone.swift",
                displayName: "gone.swift",
                fileKindRaw: "sourceCode",
                statusRaw: "missing"
            )
        ]
        let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
        XCTAssertEqual(snapshot.others.first?.statusRaw, "missing")
    }

    func test_fromStructured_imagesAndPdfsRemainsStringPaths() {
        let entries = [
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/img.png",
                displayName: "img.png",
                fileKindRaw: "image",
                statusRaw: "valid"
            ),
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/doc.pdf",
                displayName: "doc.pdf",
                fileKindRaw: "pdf",
                statusRaw: "valid"
            )
        ]
        let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
        XCTAssertEqual(snapshot.images, ["/a/img.png"])
        XCTAssertEqual(snapshot.pdfs, ["/a/doc.pdf"])
        XCTAssertTrue(snapshot.others.isEmpty)
    }
}
```

**Step 1-2: 运行测试，确认编译失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileReferencePillSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：编译错误 `value of type '[String]' has no member 'displayName'`

**Step 1-3: 修改 `MessageAttachmentSnapshot`**

在 `agentGui/ViewModels/MessageRowSnapshot.swift` 中作如下改动：

```swift
// 修改前
struct MessageAttachmentSnapshot: Equatable, @unchecked Sendable {
    let images: [String]
    let pdfs:   [String]
    let others: [String]
    ...
    static func fromStructured(_ entries: [AttachmentSnapshotEntry]) -> MessageAttachmentSnapshot {
        var images:  [String] = []
        var pdfs:    [String] = []
        var others:  [String] = []
        for e in entries {
            switch AttachmentKind(rawValue: e.fileKindRaw) ?? .other {
            case .image:                          images.append(e.filePath)
            case .pdf:                            pdfs.append(e.filePath)
            case .sourceCode, .directory, .other: others.append(e.filePath)
            }
        }
        return MessageAttachmentSnapshot(images: images, pdfs: pdfs, others: others)
    }
}
```

```swift
// 修改后
struct MessageAttachmentSnapshot: Equatable, @unchecked Sendable {
    let images: [String]                     // 图像路径（供 MediaThumbnailCell 使用）
    let pdfs:   [String]                     // PDF 路径（供 MediaThumbnailCell 使用）
    let others: [AttachmentSnapshotEntry]    // 结构化文件条目

    static let empty = MessageAttachmentSnapshot(images: [], pdfs: [], others: [])

    var hasMedia: Bool { !images.isEmpty || !pdfs.isEmpty }

    static func fromStructured(_ entries: [AttachmentSnapshotEntry]) -> MessageAttachmentSnapshot {
        var images:  [String] = []
        var pdfs:    [String] = []
        var others:  [AttachmentSnapshotEntry] = []
        for e in entries {
            switch AttachmentKind(rawValue: e.fileKindRaw) ?? .other {
            case .image:                          images.append(e.filePath)
            case .pdf:                            pdfs.append(e.filePath)
            case .sourceCode, .directory, .other: others.append(e)   // ← 保留完整条目
            }
        }
        return MessageAttachmentSnapshot(images: images, pdfs: pdfs, others: others)
    }
}
```

同文件还需更新旧的文本回退解析方法 `attachmentSnapshot(from raw:)`：

```swift
// 修改后（在 MessageRowSnapshot 的 private static func）
nonisolated private static func attachmentSnapshot(from raw: String) -> MessageAttachmentSnapshot {
    let separator = "\n\nReferenced files:\n"
    guard let range = raw.range(of: separator) else { return .empty }

    let paths = raw[range.upperBound...]
        .split(separator: "\n")
        .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
        .filter { !$0.isEmpty }

    var images: [String] = []
    var pdfs:   [String] = []
    var others: [AttachmentSnapshotEntry] = []

    for path in paths {
        if AttachedFile.pathIsImage(path) {
            images.append(path)
        } else if AttachedFile.pathIsPDF(path) {
            pdfs.append(path)
        } else {
            // 旧格式：只有路径，displayName 从路径末尾取文件名
            let displayName = (path as NSString).lastPathComponent
            others.append(AttachmentSnapshotEntry(
                id: UUID(),
                filePath: path,
                displayName: displayName,
                fileKindRaw: AttachmentKind.other.rawValue,
                statusRaw: AttachmentStatus.valid.rawValue
            ))
        }
    }
    return MessageAttachmentSnapshot(images: images, pdfs: pdfs, others: others)
}
```

**Step 1-4: 修复下游编译错误**

`others` 从 `[String]` 变为 `[AttachmentSnapshotEntry]` 后，以下调用点将报错：

- `MessageBubbleView.swift` 中两处 `agent.attachments.others.count` 和 `content.others.count`
  → 临时改为 `.others.count`（`count` 仍可用，编译通过即可，等 Task 5 再替换 UI）

**Step 1-5: 运行测试，确认通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileReferencePillSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：`TEST SUCCEEDED`

**Step 1-6: Commit**

```
git add agentGui/ViewModels/MessageRowSnapshot.swift \
        agentGuiTests/FileReferencePillSnapshotTests.swift
git commit -m "cv-f2: extend MessageAttachmentSnapshot.others to [AttachmentSnapshotEntry]"
```

---

## Task 2: 升级 `ParsedUserMessageText` 与 `UserMessagePresentation`

**目标文件：**
- 修改：`agentGui/Services/UserMessageTextParser.swift`
- 修改：`agentGui/ViewModels/UserMessagePresentation.swift`

**背景：** 用户消息里的文件引用走 `ParsedUserMessageText → UserMessagePresentation`，`others: [String]` 路径同样需要变为 `[AttachmentSnapshotEntry]`。

---

### Step 2-1: 写测试（追加到 `FileReferencePillSnapshotTests.swift`）

```swift
// MARK: - ParsedUserMessageText.replacingAttachments preserves metadata

func test_replacingAttachments_preservesDisplayNameInOthers() {
    // 模拟 CV-F1 写入的结构化条目
    let entry = AttachmentSnapshotEntry(
        id: UUID(),
        filePath: "/workspace/ClaudeService.swift",
        displayName: "ClaudeService.swift",
        fileKindRaw: "sourceCode",
        statusRaw: "modified"
    )
    let base = ParsedUserMessageText(
        bodyText: "hello",
        directiveAuditItems: [],
        inlineSegments: [],
        images: [],
        pdfs: [],
        others: []
    )
    let updated = base.replacingAttachments(with: [entry])
    XCTAssertEqual(updated.others.first?.displayName, "ClaudeService.swift")
    XCTAssertEqual(updated.others.first?.statusRaw, "modified")
}
```

**Step 2-2: 运行测试确认编译失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileReferencePillSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

**Step 2-3: 修改 `ParsedUserMessageText`**

`agentGui/Services/UserMessageTextParser.swift`（约第 3–10 行）：

```swift
// 修改 others 类型
struct ParsedUserMessageText: Equatable {
    let bodyText: String
    let directiveAuditItems: [ParsedDirectiveAuditItem]
    let inlineSegments: [UserMessageInlineSegment]
    let images: [String]
    let pdfs:   [String]
    let others: [AttachmentSnapshotEntry]   // ← 从 [String] 升级
}
```

修改 `replacingAttachments(with:)`：

```swift
extension ParsedUserMessageText {
    func replacingAttachments(with entries: [AttachmentSnapshotEntry]) -> ParsedUserMessageText {
        var imgs: [String] = []
        var pdfs: [String] = []
        var others: [AttachmentSnapshotEntry] = []
        for e in entries {
            switch AttachmentKind(rawValue: e.fileKindRaw) ?? .other {
            case .image:                          imgs.append(e.filePath)
            case .pdf:                            pdfs.append(e.filePath)
            case .sourceCode, .directory, .other: others.append(e)     // ← 保留完整条目
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

修改 `UserMessageTextParser.parse` 中构建 `others` 的地方（原先是 `bodyAndAttachments.others: [String]`）。
`bodyAndAttachments` 由 `splitReferencedFiles(in:)` 返回。  
查找该私有方法的返回类型并更新：

- 找到 `splitReferencedFiles(in:)` 的返回 struct / tuple（含 `others: [String]`）
- 将其改为 `others: [AttachmentSnapshotEntry]`
- 在构建处用 `lastPathComponent` 作 `displayName`、`AttachmentKind.other` 作 `fileKindRaw`、`AttachmentStatus.valid` 作 `statusRaw`：

```swift
// splitReferencedFiles 内 others 构建处
let displayName = (path as NSString).lastPathComponent
others.append(AttachmentSnapshotEntry(
    id: UUID(),
    filePath: path,
    displayName: displayName,
    fileKindRaw: AttachmentKind.other.rawValue,
    statusRaw: AttachmentStatus.valid.rawValue
))
```

**Step 2-4: 修改 `UserMessagePresentation`**

`agentGui/ViewModels/UserMessagePresentation.swift`（约第 3–10 行）：

```swift
struct UserMessagePresentation: Equatable {
    let directiveChips: [DirectiveChipPresentation]
    let inlineItems: [InlineItem]
    let images: [String]
    let pdfs:   [String]
    let others: [AttachmentSnapshotEntry]   // ← 升级
    ...
}
```

`make(from:)` 直接透传：

```swift
return UserMessagePresentation(
    directiveChips: directiveChips,
    inlineItems: inlineItems,
    images: parsed.images,
    pdfs:   parsed.pdfs,
    others: parsed.others           // ← 已是 [AttachmentSnapshotEntry]
)
```

**Step 2-5: 修复下游编译错误**

`MessageBubbleView.swift` 中 `content.others.count` 调用保持不变（`.count` 仍然可用）。

**Step 2-6: 运行测试确认通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileReferencePillSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

**Step 2-7: Commit**

```
git add agentGui/Services/UserMessageTextParser.swift \
        agentGuiTests/FileReferencePillSnapshotTests.swift \
        agentGui/ViewModels/UserMessagePresentation.swift
git commit -m "cv-f2: propagate AttachmentSnapshotEntry through ParsedUserMessageText and UserMessagePresentation"
```

---

## Task 3: 提取共享 FlowLayout

**目标文件：**
- 新建：`agentGui/Views/ChatFlowLayout.swift`
- 修改：`agentGui/Views/UserMessageInlineContentView.swift`（去 private typealias）

**背景：** `UserMessageWrappingLayout` 是私有 struct，`FileReferencePillView` 的 pill list 也需要同样的换行布局。提取一次，两处复用。

---

### Step 3-1: 新建 `ChatFlowLayout.swift`

`agentGui/Views/ChatFlowLayout.swift`：

```swift
//  ChatFlowLayout.swift
//  agentGui
//
//  换行 FlowLayout，ChatView 体系共享。

import SwiftUI

/// 水平排列子视图，超出宽度时自动换行，类似 CSS flexbox wrap。
struct ChatFlowLayout<Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content()
    }

    var body: some View {
        _ChatWrappingLayout(spacing: spacing, lineSpacing: lineSpacing) {
            content
        }
    }
}

struct _ChatWrappingLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    struct Cache {
        var rows: [Row] = []
        var size: CGSize = .zero
    }

    struct Row {
        var elements: [Element]
        var width: CGFloat
        var height: CGFloat
    }

    struct Element {
        let index: Int
        let size: CGSize
        let x: CGFloat
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        cache = makeRows(proposal: proposal, subviews: subviews)
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.rows.isEmpty { cache = makeRows(proposal: proposal, subviews: subviews) }
        var y = bounds.minY
        for row in cache.rows {
            for element in row.elements {
                let x = bounds.minX + element.x
                subviews[element.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(element.size)
                )
            }
            y += row.height + lineSpacing
        }
    }

    private func makeRows(proposal: ProposedViewSize, subviews: Subviews) -> Cache {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var currentRow: [Element] = []
        var currentX: CGFloat = 0
        var currentHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, !currentRow.isEmpty {
                rows.append(Row(elements: currentRow, width: currentX - spacing, height: currentHeight))
                totalHeight += currentHeight + lineSpacing
                currentRow = []
                currentX = 0
                currentHeight = 0
            }
            currentRow.append(Element(index: index, size: size, x: currentX))
            currentX += size.width + spacing
            currentHeight = max(currentHeight, size.height)
        }

        if !currentRow.isEmpty {
            rows.append(Row(elements: currentRow, width: currentX - spacing, height: currentHeight))
            totalHeight += currentHeight
        }

        let maxRowWidth = rows.map(\.width).max() ?? 0
        return Cache(rows: rows, size: CGSize(width: maxRowWidth, height: max(totalHeight, 0)))
    }
}
```

### Step 3-2: 更新 `UserMessageInlineContentView`

将原来的 `UserMessageWrapLayout` / `UserMessageWrappingLayout` 私有实现替换为对 `ChatFlowLayout` 的调用：

```swift
// 删除文件末尾的 UserMessageWrapLayout 和 UserMessageWrappingLayout 两个 struct
// 将调用处改为：
UserMessageWrapLayout(spacing: 6, lineSpacing: 6) { ... }
// → 改为
ChatFlowLayout(spacing: 6, lineSpacing: 6) { ... }
```

### Step 3-3: 确认编译通过

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 3-4: Commit

```
git add agentGui/Views/ChatFlowLayout.swift \
        agentGui/Views/UserMessageInlineContentView.swift
git commit -m "cv-f2: extract ChatFlowLayout from UserMessageInlineContentView for reuse"
```

---

## Task 4: 新建 `FileReferencePillView`

**目标文件：**
- 新建：`agentGui/Views/FileReferencePillView.swift`

**UI 规格（参考 VS Code pill + 现有 `mentionTokenView` 风格）：**

```
[📄 ClaudeService.swift:42-68]   ← valid, 正常色
[⚠️ foo.swift                ]   ← modified, 黄色背景+感叹号
[~~gone.swift~~              ]   ← missing, 红色删除线
```

---

### Step 4-1: 写失败测试（逻辑测试）

在 `FileReferencePillSnapshotTests.swift` 追加（测试辅助方法，验证 `labelText` 计算逻辑）：

```swift
// MARK: - FileReferencePillView label text logic

func test_pillLabelText_withoutLineRange() {
    let entry = AttachmentSnapshotEntry(
        id: UUID(), filePath: "/a/foo.swift", displayName: "foo.swift",
        fileKindRaw: "sourceCode", statusRaw: "valid"
    )
    XCTAssertEqual(FileReferencePillViewModel.labelText(for: entry), "foo.swift")
}

func test_pillLabelText_withLineRange() {
    var entry = AttachmentSnapshotEntry(
        id: UUID(), filePath: "/a/foo.swift", displayName: "foo.swift",
        fileKindRaw: "sourceCode", statusRaw: "valid"
    )
    // AttachmentSnapshotEntry 目前无 lineStart/lineEnd，Task 4-2 补充
    // 此测试在 Task 4-2 之后才能通过
    _ = entry
}
```

> 注意：`AttachmentSnapshotEntry` 当前不含 `lineStart / lineEnd`（这两个字段只在 `MessageAttachment` 上）。Task 4-2 需要将其加入 `AttachmentSnapshotEntry`。

### Step 4-2: 扩展 `AttachmentSnapshotEntry` 加入行范围

`agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`（`AttachmentSnapshotEntry` 定义处）：

```swift
struct AttachmentSnapshotEntry: Hashable, Identifiable, @unchecked Sendable {
    let id: UUID
    let filePath: String
    let displayName: String
    let fileKindRaw: String
    let statusRaw: String
    let lineStart: Int?    // ← 新增
    let lineEnd: Int?      // ← 新增

    @MainActor
    init(_ a: MessageAttachment) {
        self.id = a.id
        self.filePath = a.filePath
        self.displayName = a.displayName
        self.fileKindRaw = a.fileKindRaw
        self.statusRaw = a.statusRaw
        self.lineStart = a.lineStart   // ← 读取
        self.lineEnd = a.lineEnd       // ← 读取
    }

    // 测试用（手动初始化，保持向后兼容）
    init(id: UUID, filePath: String, displayName: String, fileKindRaw: String, statusRaw: String,
         lineStart: Int? = nil, lineEnd: Int? = nil) {
        self.id = id
        self.filePath = filePath
        self.displayName = displayName
        self.fileKindRaw = fileKindRaw
        self.statusRaw = statusRaw
        self.lineStart = lineStart
        self.lineEnd = lineEnd
    }
}
```

### Step 4-3: 新建 `FileReferencePillView.swift`

`agentGui/Views/FileReferencePillView.swift`：

```swift
//  FileReferencePillView.swift
//  agentGui

import SwiftUI

/// 单个文件引用 pill chip。
/// 显示：文件图标 + 文件名（可选行号）+ 状态指示。
/// 交互：单击跳转编辑器；长按/Option+Click 弹出代码预览 popover。
struct FileReferencePillView: View {
    let entry: AttachmentSnapshotEntry
    var onTap: () -> Void = {}

    @State private var isHovered = false
    @State private var showPreview = false

    private var status: AttachmentStatus {
        AttachmentStatus(rawValue: entry.statusRaw) ?? .valid
    }

    var body: some View {
        pillContent
            .overlay(alignment: .topTrailing) {
                if status == .modified {
                    modifiedBadge
                }
            }
            .onHover { hovered in
                withAnimation(ChatMotion.hoverSpring) { isHovered = hovered }
            }
            .onTapGesture {
                onTap()
            }
            .simultaneousGesture(
                // Option+Click → 弹代码预览
                TapGesture().modifiers(.option).onEnded { _ in showPreview = true }
            )
            .popover(isPresented: $showPreview, arrowEdge: .bottom) {
                FileReferencePreviewPopover(entry: entry)
                    .frame(width: 380, height: 240)
            }
            .help(entry.filePath)   // 完整路径作 tooltip（对应 VS Code pill 的 tooltip）
    }

    // MARK: - Pill 主体

    private var pillContent: some View {
        HStack(spacing: 5) {
            // 文件类型图标
            Image(systemName: fileIconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconForeground)

            // 文件名 [+行号]
            Group {
                if status == .missing {
                    Text(labelText)
                        .strikethrough(true, color: .red.opacity(0.7))
                        .foregroundStyle(.red)
                } else {
                    Text(labelText)
                        .foregroundStyle(status == .modified ? Color.yellow : .primary.opacity(0.8))
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(pillBackground)
                .shadow(color: .black.opacity(isHovered ? 0.08 : 0), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(pillBorderColor, lineWidth: 1)
        )
        .scaleEffect(isHovered ? ChatMotion.hoverScale : 1.0)
        .animation(ChatMotion.hoverSpring, value: isHovered)
    }

    // 修改标记角标
    private var modifiedBadge: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(.yellow)
            .offset(x: 4, y: -4)
    }

    // MARK: - Helpers

    private var labelText: String {
        FileReferencePillViewModel.labelText(for: entry)
    }

    private var fileIconName: String {
        let kind = AttachmentKind(rawValue: entry.fileKindRaw) ?? .other
        switch kind {
        case .sourceCode:  return "doc.text"
        case .image:       return "photo"
        case .pdf:         return "doc.richtext"
        case .directory:   return "folder"
        case .other:       return FileIconSymbolResolver.symbol(forFileName: entry.displayName)
        }
    }

    private var iconForeground: some ShapeStyle {
        switch status {
        case .valid:    return AnyShapeStyle(Color.accentColor.opacity(0.75))
        case .modified: return AnyShapeStyle(Color.yellow.opacity(0.85))
        case .missing:  return AnyShapeStyle(Color.red.opacity(0.7))
        }
    }

    private var pillBackground: some ShapeStyle {
        switch status {
        case .valid:    return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.12 : 0.07))
        case .modified: return AnyShapeStyle(Color.yellow.opacity(isHovered ? 0.15 : 0.08))
        case .missing:  return AnyShapeStyle(Color.red.opacity(isHovered ? 0.12 : 0.06))
        }
    }

    private var pillBorderColor: Color {
        switch status {
        case .valid:    return .accentColor.opacity(0.18)
        case .modified: return .yellow.opacity(0.30)
        case .missing:  return .red.opacity(0.25)
        }
    }
}

// MARK: - ViewModel helpers（逻辑可单测）

enum FileReferencePillViewModel {
    /// 生成显示文本：`filename` 或 `filename:start-end`
    static func labelText(for entry: AttachmentSnapshotEntry) -> String {
        guard let start = entry.lineStart else {
            return entry.displayName
        }
        if let end = entry.lineEnd, end != start {
            return "\(entry.displayName):\(start)-\(end)"
        }
        return "\(entry.displayName):\(start)"
    }
}
```

### Step 4-4: 更新测试中的行范围测试

回到 `FileReferencePillSnapshotTests.swift` 补全之前预留的测试：

```swift
func test_pillLabelText_withLineRange() {
    let entry = AttachmentSnapshotEntry(
        id: UUID(), filePath: "/a/foo.swift", displayName: "foo.swift",
        fileKindRaw: "sourceCode", statusRaw: "valid",
        lineStart: 10, lineEnd: 20
    )
    XCTAssertEqual(FileReferencePillViewModel.labelText(for: entry), "foo.swift:10-20")
}

func test_pillLabelText_singleLine() {
    let entry = AttachmentSnapshotEntry(
        id: UUID(), filePath: "/a/foo.swift", displayName: "foo.swift",
        fileKindRaw: "sourceCode", statusRaw: "valid",
        lineStart: 42, lineEnd: 42
    )
    XCTAssertEqual(FileReferencePillViewModel.labelText(for: entry), "foo.swift:42")
}
```

### Step 4-5: 运行测试确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileReferencePillSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

### Step 4-6: Commit

```
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift \
        agentGui/Views/FileReferencePillView.swift \
        agentGuiTests/FileReferencePillSnapshotTests.swift
git commit -m "cv-f2: add FileReferencePillView + extend AttachmentSnapshotEntry with lineStart/lineEnd"
```

---

## Task 5: 新建 `FileReferencePreviewPopover`

**目标文件：**
- 新建：`agentGui/Views/FileReferencePreviewPopover.swift`

**业务规则（参考 VS Code hover widget）：**
- 显示文件前 20 行，带语法高亮
- 文件缺失时显示警告占位
- 文件过大（>5MB raw read）截断到换行 2000 字符
- Popover 宽 380，高 240（`.frame` 由调用方 Task 6 指定）

---

### Step 5-1: 新建 `FileReferencePreviewPopover.swift`

`agentGui/Views/FileReferencePreviewPopover.swift`：

```swift
//  FileReferencePreviewPopover.swift
//  agentGui

import SwiftUI

/// 悬停/Option+Click 弹出的文件代码预览 popover。
/// 显示文件前 20 行, 语法高亮, 文件缺失时显示警告。
struct FileReferencePreviewPopover: View {
    let entry: AttachmentSnapshotEntry

    @State private var previewAttr: NSAttributedString? = nil
    @State private var isMissing = false
    @State private var isLoading = true

    private let maxPreviewLines = 20
    private let maxReadBytes = 5 * 1024 * 1024  // 5MB hard cap

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewHeader
            Divider()
            previewBody
        }
        .background(.ultraThinMaterial)
        .task(id: entry.id) {
            await loadPreview()
        }
    }

    // MARK: - Header (file path)

    private var previewHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(entry.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Body

    @ViewBuilder
    private var previewBody: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isMissing {
            missingPlaceholder
        } else if let attr = previewAttr {
            ScrollView([.horizontal, .vertical]) {
                SyntaxHighlightedCodeTextView(
                    attributedString: attr,
                    textInsets: NSSize(width: 10, height: 8)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var missingPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.yellow)
            Text("文件不存在")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(entry.filePath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - File loading

    @MainActor
    private func loadPreview() async {
        isLoading = true
        isMissing = false
        previewAttr = nil

        let path = entry.filePath
        let fileURL = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            isMissing = true
            isLoading = false
            return
        }

        let snippet = await Task.detached(priority: .userInitiated) {
            Self.readFirstLines(url: fileURL, maxLines: 20, maxBytes: 5 * 1024 * 1024)
        }.value

        guard let snippet else {
            isMissing = true
            isLoading = false
            return
        }

        let language = CodeSyntaxHighlightingService.languageIdentifier(for: fileURL)
        let highlighted = CodeSyntaxHighlightingService.shared.highlightedString(
            code: snippet,
            language: language,
            appearance: .auto,
            fontSize: 11.5
        )
        previewAttr = highlighted
        isLoading = false
    }

    /// 读取文件前 `maxLines` 行，限制读入字节数防止大文件卡 UI 线程。
    private static func readFirstLines(url: URL, maxLines: Int, maxBytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let data = fh.readData(ofLength: maxBytes)
        guard let raw = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else { return nil }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
                       .prefix(maxLines)
        return lines.joined(separator: "\n")
    }
}
```

> **注意：** `CodeSyntaxHighlightingService.languageIdentifier(for:)` 接受 `URL?`，`CodeHighlightAppearance.auto` 需确认该 enum case 存在，若当前为 `.light` / `.dark`，则改为 `NSApp.effectiveAppearance.name == .darkAqua ? .dark : .light`。

### Step 5-2: 确认编译通过

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 5-3: Commit

```
git add agentGui/Views/FileReferencePreviewPopover.swift
git commit -m "cv-f2: add FileReferencePreviewPopover with syntax-highlighted code preview"
```

---

## Task 6: 接入 `MessageBubbleView`

**目标文件：**
- 修改：`agentGui/Views/MessageBubbleView.swift`

---

### Step 6-1: 注入 `WorkspaceState`

在 `MessageBubbleView` 顶部属性区加入：

```swift
@Environment(WorkspaceState.self) private var workspaceState
```

> **若 `WorkspaceState` 不在环境中（如 preview / 测试），需添加 `.environment(WorkspaceState())` 占位。**

### Step 6-2: 新增 `fileReferencePillList` 方法，删除 `fileReferenceBadge`

删除：

```swift
private func fileReferenceBadge(count: Int) -> some View { ... }
```

新增：

```swift
@ViewBuilder
private func fileReferencePillList(others: [AttachmentSnapshotEntry]) -> some View {
    if !others.isEmpty {
        ChatFlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(others) { entry in
                FileReferencePillView(entry: entry) {
                    openAttachment(entry)
                }
            }
        }
    }
}

private func openAttachment(_ entry: AttachmentSnapshotEntry) {
    let url = URL(fileURLWithPath: entry.filePath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return }

    if let lineStart = entry.lineStart {
        workspaceState.pendingCodeEditorRevealRequest = CodeEditorRevealRequest(
            fileURL: url,
            line: lineStart,
            column: 0,
            reason: .reference
        )
    }
    workspaceState.showFileDetail(url)
}
```

### Step 6-3: 替换两处调用点

**用户消息 bubble（`userBubble` 里）：**

```swift
// 旧
if !content.others.isEmpty {
    fileReferenceBadge(count: content.others.count)
}

// 新
fileReferencePillList(others: content.others)
```

**Agent 消息 card（`agentCardContent` 里）：**

```swift
// 旧
if !agent.attachments.others.isEmpty {
    fileReferenceBadge(count: agent.attachments.others.count)
}

// 新
fileReferencePillList(others: agent.attachments.others)
```

### Step 6-4: 确认编译通过

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 6-5: 补充集成测试

在 `FileReferencePillSnapshotTests.swift` 追加：

```swift
// MARK: - openAttachment logic

func test_openAttachment_skipsNonexistentFile() {
    // 构建一个不存在文件的 entry
    let entry = AttachmentSnapshotEntry(
        id: UUID(),
        filePath: "/nonexistent/path/foo.swift",
        displayName: "foo.swift",
        fileKindRaw: "sourceCode",
        statusRaw: "missing"
    )
    // MessageBubbleView 的 openAttachment 逻辑：
    // guard FileManager.default.fileExists(atPath: ...) 应返回 false，不崩溃
    let url = URL(fileURLWithPath: entry.filePath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
}
```

### Step 6-6: 运行全部相关测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileReferencePillSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

### Step 6-7: Commit

```
git add agentGui/Views/MessageBubbleView.swift \
        agentGuiTests/FileReferencePillSnapshotTests.swift
git commit -m "cv-f2: replace fileReferenceBadge with FileReferencePillView pill list in MessageBubbleView"
```

---

## Task 7: Preview 支持与边界修复

**背景：** SwiftUI Preview 通常不带完整 Environment，需提供 mock 数据以便预览调试。

### Step 7-1: 添加 `FileReferencePillView` Preview

在 `FileReferencePillView.swift` 末尾：

```swift
#Preview {
    VStack(alignment: .leading, spacing: 12) {
        Text("Valid").font(.caption).foregroundStyle(.secondary)
        FileReferencePillView(entry: AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/ClaudeService.swift",
            displayName: "ClaudeService.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            lineStart: 42, lineEnd: 68
        ))

        Text("Modified").font(.caption).foregroundStyle(.secondary)
        FileReferencePillView(entry: AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/Message.swift",
            displayName: "Message.swift",
            fileKindRaw: "sourceCode", statusRaw: "modified"
        ))

        Text("Missing").font(.caption).foregroundStyle(.secondary)
        FileReferencePillView(entry: AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/Gone.swift",
            displayName: "Gone.swift",
            fileKindRaw: "sourceCode", statusRaw: "missing"
        ))

        Text("Directory").font(.caption).foregroundStyle(.secondary)
        FileReferencePillView(entry: AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/Services/",
            displayName: "Services/",
            fileKindRaw: "directory", statusRaw: "valid"
        ))
    }
    .padding()
    .frame(width: 300)
}
```

### Step 7-2: 验证 WorkspaceState 环境缺失不崩溃

`FileReferencePillView` 调用了 `MessageBubbleView.openAttachment`，而后者需要 `WorkspaceState`。若 Preview 无环境会 crash。

确认方案：`MessageBubbleView` 中 `workspaceState` 用 `@Environment(WorkspaceState.self) private var workspaceState`。若确实缺失，PreviewProvider 补 `.environment(WorkspaceState())`.

### Step 7-3: 最终冒烟编译 + 测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileReferencePillSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

### Step 7-4: Commit

```
git add agentGui/Views/FileReferencePillView.swift
git commit -m "cv-f2: add FileReferencePillView preview"
```

---

## 验收清单

| 验收标准 | 方式 |
|---|---|
| 新消息文件引用显示 per-file pill，不再显示"引用了 N 个文件" | 手动发送含附件消息验证 |
| `.valid` pill 使用正常 accent 色 | 肉眼 |
| `.modified` pill 显示黄色背景 + 感叹号角标 | 需要手动将文件标记为 modified（或触发 CV-F3 后自动更新） |
| `.missing` pill 显示红色删除线文字 | 发送消息后删除文件，等 CV-F3 后验证；或直接在 Preview 中验证 |
| hover 悬停 pill → scale up 动画 | 肉眼 |
| Option+Click → popover 弹出，显示前 20 行代码 | 手动操作 |
| popover 文件缺失 → 显示"⚠️ 文件不存在"占位 | 构造缺失条目在 Preview 中测试 |
| 单击 pill → 在编辑器中打开文件 | 手动操作 |
| 单击含行范围的 pill → 跳转到对应行 | 手动操作：附件带 lineStart |
| 旧消息（CV-F1 之前的纯文本格式）兼容层解析正确 | 找一条旧消息验证 |
| `FileReferencePillSnapshotTests` 全部通过 | `xcodebuild test` |

---

## 不做的事项 (YAGNI)

| 提议 | 原因 |
|---|---|
| 文件内容 diff 预览（发送时 vs 当前） | 需要 CV-F3 文件内容快照支持，超出本 feature 范围 |
| 图片引用 pill 化 | 图片已有缩略图网格，视觉信息足够 |
| PDF 引用 pill 化 | 同上 |
| pill 右键菜单（复制路径、在 Finder 打开） | 可在后续迭代加，不影响核心交互 |
| pill 拖拽重排 | 非核心，且历史引用顺序具有语义 |

---

## 潜在踩坑

1. **`CodeHighlightAppearance`**：确认该 enum 有 `.auto` case，否则需按 `NSApp.effectiveAppearance` 分支处理。
2. **`WorkspaceState` 缺失环境**：`ContentView` / `ChatView` 级别均已注入 `.environment(workspaceState)`，`MessageBubbleView` 嵌套在 `ChatView` 内故可获取。若有独立 Preview，需手动注入。
3. **`ChatMessageListSnapshotBuilder` 测试兼容**：添加 `lineStart / lineEnd` 两个新字段且有默认值，原测试中手写 `AttachmentSnapshotEntry(id:filePath:displayName:fileKindRaw:statusRaw:)` 仍兼容（Swift 默认参数）。
4. **`UserMessagePresentation.others` equatable**：`AttachmentSnapshotEntry` 已声明 `Hashable`（且 `Equatable` 是 `Hashable` 的前提），`Equatable` 合规不受影响。
