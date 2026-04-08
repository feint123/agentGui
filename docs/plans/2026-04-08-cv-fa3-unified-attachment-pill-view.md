# CV-FA3: 统一消息历史 AttachmentPillView 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 用统一的 `AttachmentPillView` 替代当前消息气泡中的 `FileReferencePillView`（项目文件）和 `MediaThumbnailCell`（图片/PDF），使所有类型附件在消息历史中以一致的 pill 组件渲染，支持状态着色、hover 动效、点击交互。

**Architecture:** 新建 `AttachmentPillView.swift`（消息历史侧统一 pill 组件），内含三个子变体—— `FileIconPill`（代码/目录/其他文件）、`MediaThumbnailPill`（图片/PDF 缩略图 pill）。`MessageAttachmentSnapshot` 不再拆分 images/pdfs/others，改为保留完整 `[AttachmentSnapshotEntry]`，由 `AttachmentPillView` 按 `fileKindRaw` 分发渲染。`MessageBubbleView` 中的 `mediaGrid` + `fileReferencePillList` 合并为单一 `attachmentPillGrid`。

**Tech Stack:** Swift 6.0+, SwiftUI, SwiftData (MessageAttachment model), ChatMotion tokens

**竞品参考:**
- **VS Code:** `ChatAttachmentsContentPart` 按 `kind` 分发到不同 `AbstractChatAttachmentWidget` 子类（`FileAttachmentWidget`、`ImageAttachmentWidget` 等），统一由 `IChatAttachmentWidgetRegistry` 工厂创建，全部渲染为 `.chat-attached-context-attachment` DOM pill 节点。`OmittedState` 枚举统一表达附件状态（NotOmitted / Partial / Full / ImageLimitExceeded）。
- **Open WebUI:** `FileItem.svelte` 单组件通过 `type`/`loading`/`dismissible`/`small` props 驱动所有文件变体（file/collection/note/chat），图片单独走 `<Image>` 分支但 dismiss 逻辑完全复用。消息历史中 `ResponseMessage.svelte` 用 `FileItem` 统一渲染非图片附件。

---

## 前置依赖

- CV-FA2 已完成：`AttachmentSnapshotEntry` 已有 `originRaw` 字段
- `AttachmentOrigin` 枚举（project/focused/external）可用
- `ChatMotion` 动效 token 可用
- `FileReferencePreviewPopover` 可复用

---

## Task 1: 重构 `MessageAttachmentSnapshot`，保留完整条目

**目标:** 当前 `MessageAttachmentSnapshot` 将 images/pdfs 拆为 `[String]` 路径，丢失了 `AttachmentSnapshotEntry` 的结构化数据（origin、status、lineStart 等）。需改为统一保留完整条目列表，由渲染层按 kind 分发。

**Files:**
- Modify: `agentGui/ViewModels/MessageRowSnapshot.swift`
- Test: `agentGuiTests/FileReferencePillSnapshotTests.swift`

**Step 1: Write failing tests for new snapshot structure**

在 `FileReferencePillSnapshotTests.swift` 末尾新增：

```swift
// MARK: - Unified entries

func test_allEntries_includesImagesAndOthers() {
    let entries = [
        AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/img.png", displayName: "img.png",
            fileKindRaw: "image", statusRaw: "valid"
        ),
        AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid"
        ),
        AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/doc.pdf", displayName: "doc.pdf",
            fileKindRaw: "pdf", statusRaw: "valid"
        ),
    ]
    let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
    XCTAssertEqual(snapshot.allEntries.count, 3)
    XCTAssertEqual(snapshot.allEntries.map(\.displayName), ["img.png", "main.swift", "doc.pdf"])
}

func test_allEntries_emptyWhenNoEntries() {
    let snapshot = MessageAttachmentSnapshot.empty
    XCTAssertTrue(snapshot.allEntries.isEmpty)
}

func test_allEntries_preservesOriginRaw() {
    let entries = [
        AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/img.png", displayName: "img.png",
            fileKindRaw: "image", statusRaw: "valid", originRaw: "focused"
        ),
    ]
    let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
    XCTAssertEqual(snapshot.allEntries.first?.originRaw, "focused")
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination "platform=macOS" -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-cv-fa3-t1 -only-testing:agentGuiTests/FileReferencePillSnapshotTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"`

Expected: FAIL — `allEntries` not found on `MessageAttachmentSnapshot`

**Step 3: Add `allEntries` to `MessageAttachmentSnapshot`**

In `agentGui/ViewModels/MessageRowSnapshot.swift`, add a stored property that preserves the full entry list:

```swift
struct MessageAttachmentSnapshot: Equatable, @unchecked Sendable {
    let images: [String]
    let pdfs:   [String]
    let others: [AttachmentSnapshotEntry]
    let allEntries: [AttachmentSnapshotEntry]   // 新增：所有条目的完整列表

    static let empty = MessageAttachmentSnapshot(images: [], pdfs: [], others: [], allEntries: [])

    var hasMedia: Bool {
        !images.isEmpty || !pdfs.isEmpty
    }

    static func fromStructured(_ entries: [AttachmentSnapshotEntry]) -> MessageAttachmentSnapshot {
        var images: [String] = []
        var pdfs:   [String] = []
        var others: [AttachmentSnapshotEntry] = []
        for e in entries {
            switch AttachmentKind(rawValue: e.fileKindRaw) ?? .other {
            case .image:                          images.append(e.filePath)
            case .pdf:                            pdfs.append(e.filePath)
            case .sourceCode, .directory, .other: others.append(e)
            }
        }
        return MessageAttachmentSnapshot(images: images, pdfs: pdfs, others: others, allEntries: entries)
    }
}
```

**Step 4: Fix build — update all `MessageAttachmentSnapshot(images:pdfs:others:)` call sites**

Search for `MessageAttachmentSnapshot(images:` and add `allEntries:` parameter. The only direct call site should be the `fromStructured` factory and `empty`. Any test code that constructs `MessageAttachmentSnapshot` directly also needs updating.

**Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination "platform=macOS" -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-cv-fa3-t1 -only-testing:agentGuiTests/FileReferencePillSnapshotTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"`

Expected: All PASS

**Step 6: Commit**

```bash
git add -A && git commit -m "feat(cv-fa3): add allEntries to MessageAttachmentSnapshot"
```

---

## Task 2: 颜色 Token — 扩展 AttachmentOrigin 状态着色

**目标:** 定义 origin-based pill 颜色 token，统一三种来源的视觉区分。对标 VS Code `OmittedState` + Open WebUI `colorClassName` 模式。

**VS Code 参考:** 在 `AbstractChatAttachmentWidget` 中，`omittedState` 控制 pill 的 `.warning` CSS class，partial/omitted 附件显示 warning icon 和降低的 opacity；Open WebUI 通过 `colorClassName` prop 传入颜色主题类。

**Files:**
- Create: `agentGui/Views/AttachmentPillStyle.swift`
- Test: `agentGuiTests/AttachmentPillStyleTests.swift`

**Step 1: Write failing tests**

新建 `agentGuiTests/AttachmentPillStyleTests.swift`:

```swift
import XCTest
@testable import agentGui

final class AttachmentPillStyleTests: XCTestCase {

    // MARK: - Origin tint

    func test_originTint_project_isAccent() {
        let tint = AttachmentPillStyle.originTint(for: .project)
        XCTAssertEqual(tint, .accentColor)
    }

    func test_originTint_focused_isOrange() {
        let tint = AttachmentPillStyle.originTint(for: .focused)
        XCTAssertEqual(tint, .orange)
    }

    func test_originTint_external_isSecondary() {
        let tint = AttachmentPillStyle.originTint(for: .external)
        XCTAssertEqual(tint, .secondary)
    }

    // MARK: - Status color

    func test_statusColor_valid_matchesOriginTint() {
        let color = AttachmentPillStyle.statusColor(origin: .project, status: .valid)
        XCTAssertEqual(color, .accentColor)
    }

    func test_statusColor_modified_isYellow() {
        let color = AttachmentPillStyle.statusColor(origin: .project, status: .modified)
        XCTAssertEqual(color, .yellow)
    }

    func test_statusColor_missing_isRed() {
        let color = AttachmentPillStyle.statusColor(origin: .external, status: .missing)
        XCTAssertEqual(color, .red)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination "platform=macOS" -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-cv-fa3-t2 -only-testing:agentGuiTests/AttachmentPillStyleTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"`

Expected: FAIL — `AttachmentPillStyle` not found

**Step 3: Implement `AttachmentPillStyle`**

新建 `agentGui/Views/AttachmentPillStyle.swift`:

```swift
import SwiftUI

/// 附件 pill 的统一颜色 token。
/// 对标 VS Code OmittedState + Open WebUI colorClassName 模式。
enum AttachmentPillStyle {

    /// origin-based 基础色。
    static func originTint(for origin: AttachmentOrigin) -> Color {
        switch origin {
        case .project:  return .accentColor
        case .focused:  return .orange
        case .external: return .secondary
        }
    }

    /// 最终 pill 状态色（status 优先级高于 origin）。
    static func statusColor(origin: AttachmentOrigin, status: AttachmentStatus) -> Color {
        switch status {
        case .modified: return .yellow
        case .missing:  return .red
        case .valid:    return originTint(for: origin)
        }
    }

    /// Pill 背景 opacity（normal / hover）。
    static func backgroundOpacity(status: AttachmentStatus, hovered: Bool) -> Double {
        switch status {
        case .valid:    return hovered ? 0.12 : 0.07
        case .modified: return hovered ? 0.15 : 0.08
        case .missing:  return hovered ? 0.12 : 0.06
        }
    }

    /// Pill border opacity。
    static func borderOpacity(status: AttachmentStatus) -> Double {
        switch status {
        case .valid:    return 0.18
        case .modified: return 0.30
        case .missing:  return 0.25
        }
    }
}
```

**Step 4: Add to Xcode project, run tests**

Run: same command as Step 2

Expected: All PASS

**Step 5: Commit**

```bash
git add -A && git commit -m "feat(cv-fa3): add AttachmentPillStyle color tokens"
```

---

## Task 3: 创建 `AttachmentPillView` 组件

**目标:** 统一的消息历史附件 pill，替代 `FileReferencePillView` + `MediaThumbnailCell`。按 `fileKindRaw` 分发为 `FileIconPill`（非媒体）或 `MediaThumbnailPill`（图片/PDF），共享 hover/tap/preview 交互。

**VS Code 参考:** `ChatAttachmentsContentPart.renderAttachment()` 按 `kind` 分发到不同的 `AbstractChatAttachmentWidget` 子类，但所有子类共享同一 pill DOM 容器 `.chat-attached-context-attachment`、hover 和 contextmenu 行为。`correspondingContentReference` 检查 `OmittedState` 决定是否加 `.warning` class。

**Open WebUI 参考:** `ResponseMessage.svelte` 中图片走 `<Image>` 组件，非图片走 `<FileItem item={file} small={true}>`，两者都放在 `flex overflow-x-auto gap-2 flex-wrap` 容器中。点击 `FileItem` 弹出 `FileItemModal`（类似我们的 preview popover）。

**Files:**
- Create: `agentGui/Views/AttachmentPillView.swift`
- Test: `agentGuiTests/AttachmentPillViewTests.swift`

**Step 1: Write failing tests**

新建 `agentGuiTests/AttachmentPillViewTests.swift`:

```swift
import XCTest
@testable import agentGui

final class AttachmentPillViewTests: XCTestCase {

    // MARK: - AttachmentPillViewModel helpers

    func test_isMediaEntry_image() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/photo.png", displayName: "photo.png",
            fileKindRaw: "image", statusRaw: "valid"
        )
        XCTAssertTrue(AttachmentPillViewModel.isMedia(entry))
    }

    func test_isMediaEntry_pdf() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/doc.pdf", displayName: "doc.pdf",
            fileKindRaw: "pdf", statusRaw: "valid"
        )
        XCTAssertTrue(AttachmentPillViewModel.isMedia(entry))
    }

    func test_isMediaEntry_sourceCode() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        XCTAssertFalse(AttachmentPillViewModel.isMedia(entry))
    }

    func test_labelText_plainFile() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.labelText(for: entry), "main.swift")
    }

    func test_labelText_withLineRange() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            lineStart: 10, lineEnd: 20
        )
        XCTAssertEqual(AttachmentPillViewModel.labelText(for: entry), "main.swift:10-20")
    }

    func test_labelText_withSingleLine() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            lineStart: 42, lineEnd: 42
        )
        XCTAssertEqual(AttachmentPillViewModel.labelText(for: entry), "main.swift:42")
    }

    func test_pillIcon_sourceCode() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.iconName(for: entry), "doc.text")
    }

    func test_pillIcon_directory() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/src", displayName: "src",
            fileKindRaw: "directory", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.iconName(for: entry), "folder")
    }

    func test_pillIcon_image() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/photo.png", displayName: "photo.png",
            fileKindRaw: "image", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.iconName(for: entry), "photo")
    }

    func test_pillIcon_pdf() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/doc.pdf", displayName: "doc.pdf",
            fileKindRaw: "pdf", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.iconName(for: entry), "doc.richtext")
    }

    func test_supportsPreview_project_true() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            originRaw: "project"
        )
        XCTAssertTrue(AttachmentPillViewModel.supportsPreview(entry))
    }

    func test_supportsPreview_focused_true() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            originRaw: "focused"
        )
        XCTAssertTrue(AttachmentPillViewModel.supportsPreview(entry))
    }

    func test_supportsPreview_external_false() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            originRaw: "external"
        )
        XCTAssertFalse(AttachmentPillViewModel.supportsPreview(entry))
    }

    func test_supportsPreview_image_false() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/img.png", displayName: "img.png",
            fileKindRaw: "image", statusRaw: "valid",
            originRaw: "project"
        )
        XCTAssertFalse(AttachmentPillViewModel.supportsPreview(entry))
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination "platform=macOS" -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-cv-fa3-t3 -only-testing:agentGuiTests/AttachmentPillViewTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"`

Expected: FAIL — `AttachmentPillViewModel` not found

**Step 3: Implement `AttachmentPillView.swift`**

新建 `agentGui/Views/AttachmentPillView.swift`:

```swift
//  AttachmentPillView.swift
//  agentGui

import SwiftUI
import AppKit

// MARK: - ViewModel (testable, pure logic)

enum AttachmentPillViewModel {

    static func isMedia(_ entry: AttachmentSnapshotEntry) -> Bool {
        let kind = AttachmentKind(rawValue: entry.fileKindRaw) ?? .other
        return kind == .image || kind == .pdf
    }

    static func labelText(for entry: AttachmentSnapshotEntry) -> String {
        FileReferencePillViewModel.labelText(for: entry)
    }

    static func iconName(for entry: AttachmentSnapshotEntry) -> String {
        let kind = AttachmentKind(rawValue: entry.fileKindRaw) ?? .other
        switch kind {
        case .sourceCode:  return "doc.text"
        case .image:       return "photo"
        case .pdf:         return "doc.richtext"
        case .directory:   return "folder"
        case .other:       return FileIconSymbolResolver.symbol(forFileName: entry.displayName)
        }
    }

    /// Option+Click 代码预览仅支持 project/focused 来源的非媒体文件。
    static func supportsPreview(_ entry: AttachmentSnapshotEntry) -> Bool {
        guard !isMedia(entry) else { return false }
        let origin = AttachmentOrigin(rawValue: entry.originRaw) ?? .external
        return origin == .project || origin == .focused
    }
}

// MARK: - Main Pill View

/// 统一的消息历史附件 pill。
/// 按 fileKindRaw 分发为 FileIconPill（代码/目录/其他）或 MediaThumbnailPill（图片/PDF）。
struct AttachmentPillView: View {
    let entry: AttachmentSnapshotEntry
    var onTap: () -> Void = {}
    var onMediaTap: (() -> Void)? = nil  // 图片/PDF 点击打开 viewer

    var body: some View {
        if AttachmentPillViewModel.isMedia(entry) {
            MediaThumbnailPill(entry: entry, onTap: onMediaTap ?? onTap)
        } else {
            FileIconPill(entry: entry, onTap: onTap)
        }
    }
}

// MARK: - FileIconPill（非媒体文件 pill）

/// 显示文件图标 + 名称 + 状态的 pill。复用 FileReferencePillView 的视觉语言，
/// 增加 origin-based 着色。
struct FileIconPill: View {
    let entry: AttachmentSnapshotEntry
    var onTap: () -> Void = {}

    @State private var isHovered = false
    @State private var showPreview = false

    private var origin: AttachmentOrigin {
        AttachmentOrigin(rawValue: entry.originRaw) ?? .external
    }
    private var status: AttachmentStatus {
        AttachmentStatus(rawValue: entry.statusRaw) ?? .valid
    }
    private var tintColor: Color {
        AttachmentPillStyle.statusColor(origin: origin, status: status)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: AttachmentPillViewModel.iconName(for: entry))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tintColor.opacity(status == .valid ? 0.75 : 1.0))

            Group {
                if status == .missing {
                    Text(AttachmentPillViewModel.labelText(for: entry))
                        .strikethrough(true, color: .red.opacity(0.7))
                        .foregroundStyle(.red)
                } else {
                    Text(AttachmentPillViewModel.labelText(for: entry))
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
                .fill(tintColor.opacity(AttachmentPillStyle.backgroundOpacity(status: status, hovered: isHovered)))
                .shadow(color: .black.opacity(isHovered ? 0.08 : 0), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tintColor.opacity(AttachmentPillStyle.borderOpacity(status: status)), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if status == .modified {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .offset(x: 4, y: -4)
            }
        }
        .scaleEffect(isHovered ? ChatMotion.hoverScale : 1.0)
        .animation(ChatMotion.hoverSpring, value: isHovered)
        .onHover { hovered in
            withAnimation(ChatMotion.hoverSpring) { isHovered = hovered }
        }
        .onTapGesture { onTap() }
        .simultaneousGesture(
            TapGesture().modifiers(.option).onEnded { _ in
                if AttachmentPillViewModel.supportsPreview(entry) {
                    showPreview = true
                }
            }
        )
        .popover(isPresented: $showPreview, arrowEdge: .bottom) {
            FileReferencePreviewPopover(entry: entry)
                .frame(width: 380, height: 240)
        }
        .help(entry.filePath)
    }
}

// MARK: - MediaThumbnailPill（图片/PDF 缩略图 pill）

/// 80×80 缩略图 pill，替代原 MediaThumbnailCell。
/// 增加 origin-based 边框着色和 missing 状态覆盖层。
struct MediaThumbnailPill: View {
    let entry: AttachmentSnapshotEntry
    var onTap: () -> Void = {}

    @State private var thumbnail: NSImage? = nil
    @State private var isHovered = false

    private var isPDF: Bool {
        (AttachmentKind(rawValue: entry.fileKindRaw) ?? .other) == .pdf
    }
    private var status: AttachmentStatus {
        AttachmentStatus(rawValue: entry.statusRaw) ?? .valid
    }
    private var origin: AttachmentOrigin {
        AttachmentOrigin(rawValue: entry.originRaw) ?? .external
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: isPDF ? "doc.richtext" : "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
            // PDF label badge
            if isPDF {
                VStack {
                    Spacer()
                    Text("PDF")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(.bottom, 5)
                }
            }
            // Missing overlay
            if status == .missing {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.3))
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    status == .missing
                        ? Color.red.opacity(0.4)
                        : AttachmentPillStyle.originTint(for: origin).opacity(isHovered ? 0.3 : 0.12),
                    lineWidth: 1
                )
        )
        .scaleEffect(isHovered ? ChatMotion.hoverScale : 1.0)
        .animation(ChatMotion.hoverSpring, value: isHovered)
        .onHover { hovered in
            withAnimation(ChatMotion.hoverSpring) { isHovered = hovered }
        }
        .onTapGesture { onTap() }
        .help(entry.displayName)
        .task { thumbnail = await mediaThumbImage(url: URL(fileURLWithPath: entry.filePath), targetWidth: 80) }
    }
}
```

**Step 4: Add to Xcode project, run tests**

Run: same command as Step 2

Expected: All PASS

**Step 5: Commit**

```bash
git add -A && git commit -m "feat(cv-fa3): add AttachmentPillView with FileIconPill and MediaThumbnailPill"
```

---

## Task 4: 替换 `MessageBubbleView` 渲染为统一 pill

**目标:** 用 `AttachmentPillView` 替换 `MessageBubbleView` 中的 `mediaGrid` + `fileReferencePillList`，两者合并为 `attachmentPillGrid`。

**VS Code 参考:** `ChatListItemRenderer.renderChatRequest()` 在消息内容渲染后，调用 `renderAttachments(element.variables, ...)` 一次性渲染所有附件。不区分 media/file，统一由 `ChatAttachmentsContentPart` 处理。

**Open WebUI 参考:** `ResponseMessage.svelte` 将图片和非图片文件放在同一个 `flex overflow-x-auto gap-2 flex-wrap` 容器中，先渲染图片 `<Image>`，再渲染其余 `<FileItem>`。

**Files:**
- Modify: `agentGui/Views/MessageBubbleView.swift`

**Step 1: Add `attachmentPillGrid` function**

在 `MessageBubbleView.swift` 中 `mediaGrid` 和 `fileReferencePillList` 旁边新增：

```swift
/// 统一附件渲染：用 ChatFlowLayout 排列所有类型的 pill。
/// 图片/PDF → MediaThumbnailPill（80×80），其他 → FileIconPill（compact）。
@ViewBuilder
private func attachmentPillGrid(entries: [AttachmentSnapshotEntry]) -> some View {
    if !entries.isEmpty {
        ChatFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(entries) { entry in
                AttachmentPillView(
                    entry: entry,
                    onTap: { openAttachment(entry) },
                    onMediaTap: AttachmentPillViewModel.isMedia(entry) ? {
                        viewingMedia = MediaItem(url: URL(fileURLWithPath: entry.filePath))
                    } : nil
                )
            }
        }
    }
}
```

**Step 2: Replace user bubble rendering**

In `userBubble`, replace the two separate blocks:

```swift
// BEFORE:
if !content.images.isEmpty || !content.pdfs.isEmpty {
    mediaGrid(images: content.images, pdfs: content.pdfs)
}
if !content.others.isEmpty {
    fileReferencePillList(others: content.others)
}

// AFTER:
if !content.allEntries.isEmpty {
    attachmentPillGrid(entries: content.allEntries)
}
```

注意：`content` 在 user bubble 中是 `user.presentation`（`UserMessagePresentation`），其 `allEntries` 需要从 `attachmentSnapshot` 获取。检查 `UserMessagePresentation` 是否已包含 `MessageAttachmentSnapshot`。如果是通过 `content.images`/`content.pdfs`/`content.others` 访问的，需确认 `allEntries` 也可用。

**Step 3: Replace agent bubble rendering**

In `agentCardContent`, replace:

```swift
// BEFORE:
if !agent.hasAgentRounds {
    if agent.attachments.hasMedia {
        mediaGrid(images: agent.attachments.images, pdfs: agent.attachments.pdfs)
    }
    if !agent.attachments.others.isEmpty {
        fileReferencePillList(others: agent.attachments.others)
    }
}

// AFTER:
if !agent.hasAgentRounds, !agent.attachments.allEntries.isEmpty {
    attachmentPillGrid(entries: agent.attachments.allEntries)
}
```

**Step 4: Build and verify**

Run: `xcodebuild build -project agentGui.xcodeproj -scheme agentGui -destination "platform=macOS" -derivedDataPath /tmp/agentGui-cv-fa3-t4 CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"`

Expected: Build succeeded

**Step 5: Commit**

```bash
git add -A && git commit -m "feat(cv-fa3): replace mediaGrid+fileReferencePillList with unified attachmentPillGrid"
```

---

## Task 5: 处理 `UserMessagePresentation` 中的 allEntries 路径

**目标:** `UserMessagePresentation`（用户消息的渲染模型）可能直接暴露 `images`/`pdfs`/`others`。需确认 `allEntries` 的可访问路径，必要时扩展。

**Files:**
- Modify: 取决于 `UserMessagePresentation` 的定义文件

**Step 1: 查找 `UserMessagePresentation` 定义**

Search for `struct UserMessagePresentation` and check what fields it exposes. If it wraps a `MessageAttachmentSnapshot`, then `allEntries` is already available. If it separately stores `images`/`pdfs`/`others`, need to add `allEntries`.

**Step 2: 如果需要，添加 `allEntries` 计算属性**

```swift
var allEntries: [AttachmentSnapshotEntry] {
    attachmentSnapshot.allEntries  // 或根据实际结构调整
}
```

**Step 3: Build and verify**

Run: same build command

**Step 4: Commit (if changes needed)**

```bash
git add -A && git commit -m "feat(cv-fa3): expose allEntries on UserMessagePresentation"
```

---

## Task 6: 外部文件 pill 点击行为 — `NSWorkspace.shared.open`

**目标:** 外部附件（origin == .external）点击时应使用系统默认应用打开，而非跳转编辑器。

**Files:**
- Modify: `agentGui/Views/MessageBubbleView.swift` — `openAttachment` 函数

**Step 1: Write failing test for open behavior logic**

在 `agentGuiTests/AttachmentPillViewTests.swift` 中新增：

```swift
// MARK: - Open behavior

func test_openBehavior_project_isEditReveal() {
    let entry = AttachmentSnapshotEntry(
        id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
        fileKindRaw: "sourceCode", statusRaw: "valid",
        originRaw: "project"
    )
    XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .editReveal)
}

func test_openBehavior_focused_isEditReveal() {
    let entry = AttachmentSnapshotEntry(
        id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
        fileKindRaw: "sourceCode", statusRaw: "valid",
        originRaw: "focused"
    )
    XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .editReveal)
}

func test_openBehavior_external_isSystemOpen() {
    let entry = AttachmentSnapshotEntry(
        id: UUID(), filePath: "/a/f.txt", displayName: "f.txt",
        fileKindRaw: "other", statusRaw: "valid",
        originRaw: "external"
    )
    XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .systemOpen)
}

func test_openBehavior_image_isMediaViewer() {
    let entry = AttachmentSnapshotEntry(
        id: UUID(), filePath: "/a/img.png", displayName: "img.png",
        fileKindRaw: "image", statusRaw: "valid",
        originRaw: "project"
    )
    XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .mediaViewer)
}

func test_openBehavior_missing_isNone() {
    let entry = AttachmentSnapshotEntry(
        id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
        fileKindRaw: "sourceCode", statusRaw: "missing",
        originRaw: "project"
    )
    XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .none)
}
```

**Step 2: Implement `openBehavior`**

在 `AttachmentPillView.swift` 的 `AttachmentPillViewModel` 中新增：

```swift
enum PillOpenBehavior: Equatable {
    case editReveal   // 跳转编辑器（project/focused 非媒体）
    case systemOpen   // NSWorkspace.shared.open（external 非媒体）
    case mediaViewer  // 打开 MediaViewerView（图片/PDF）
    case none         // missing 文件不响应
}

static func openBehavior(for entry: AttachmentSnapshotEntry) -> PillOpenBehavior {
    let status = AttachmentStatus(rawValue: entry.statusRaw) ?? .valid
    guard status != .missing else { return .none }

    if isMedia(entry) { return .mediaViewer }

    let origin = AttachmentOrigin(rawValue: entry.originRaw) ?? .external
    switch origin {
    case .project, .focused: return .editReveal
    case .external:          return .systemOpen
    }
}
```

**Step 3: Update `openAttachment` in `MessageBubbleView`**

```swift
private func openAttachment(_ entry: AttachmentSnapshotEntry) {
    let url = URL(fileURLWithPath: entry.filePath).standardizedFileURL

    switch AttachmentPillViewModel.openBehavior(for: entry) {
    case .editReveal:
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

    case .systemOpen:
        NSWorkspace.shared.open(url)

    case .mediaViewer:
        viewingMedia = MediaItem(url: url)

    case .none:
        break
    }
}
```

**Step 4: Run tests**

Run: `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination "platform=macOS" -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-cv-fa3-t6 -only-testing:agentGuiTests/AttachmentPillViewTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"`

Expected: All PASS

**Step 5: Commit**

```bash
git add -A && git commit -m "feat(cv-fa3): route attachment open behavior by origin and kind"
```

---

## Task 7: 右键菜单 — Reveal in Finder / Copy Path

**目标:** 对标设计文档第四章交互规范，所有 pill 支持右键菜单（Reveal in Finder / Copy Path）。

**Files:**
- Modify: `agentGui/Views/AttachmentPillView.swift` — `FileIconPill` 和 `MediaThumbnailPill`

**Step 1: Add context menu to `FileIconPill`**

在 `FileIconPill` 的 `.help(entry.filePath)` 前添加：

```swift
.contextMenu {
    Button {
        NSWorkspace.shared.selectFile(entry.filePath, inFileViewerRootedAtPath: "")
    } label: {
        Label("在 Finder 中显示", systemImage: "folder")
    }
    Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.filePath, forType: .string)
    } label: {
        Label("拷贝路径", systemImage: "doc.on.doc")
    }
}
```

**Step 2: Add the same context menu to `MediaThumbnailPill`**

Duplicate the same `.contextMenu` modifier.

**Step 3: Build and verify**

Run build command.

**Step 4: Commit**

```bash
git add -A && git commit -m "feat(cv-fa3): add context menu (Reveal in Finder / Copy Path) to pills"
```

---

## Task 8: 全量测试 + 回归验证

**目标:** 确保所有新旧测试通过，无编译错误。

**Files:**
- All modified files

**Step 1: Run focused FA3 tests**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa3-final \
  -only-testing:agentGuiTests/AttachmentPillViewTests \
  -only-testing:agentGuiTests/AttachmentPillStyleTests \
  -only-testing:agentGuiTests/FileReferencePillSnapshotTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25
```

Expected: All PASS

**Step 2: Run broader smoke tests**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cv-fa3-smoke \
  -only-testing:agentGuiTests/AttachmentPillViewTests \
  -only-testing:agentGuiTests/AttachmentPillStyleTests \
  -only-testing:agentGuiTests/FileReferencePillSnapshotTests \
  -only-testing:agentGuiTests/AttachmentEntryChipViewTests \
  -only-testing:agentGuiTests/MessageAttachmentSnapshotBuilderTests \
  -only-testing:agentGuiTests/MessageAttachmentModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25
```

Expected: All PASS

**Step 3: Commit final**

```bash
git add -A && git commit -m "test(cv-fa3): all attachment pill view tests pass"
```

---

## 文件清单

| 操作 | 路径 |
|------|------|
| **Create** | `agentGui/Views/AttachmentPillView.swift` |
| **Create** | `agentGui/Views/AttachmentPillStyle.swift` |
| **Create** | `agentGuiTests/AttachmentPillViewTests.swift` |
| **Create** | `agentGuiTests/AttachmentPillStyleTests.swift` |
| **Modify** | `agentGui/ViewModels/MessageRowSnapshot.swift` — add `allEntries` |
| **Modify** | `agentGui/Views/MessageBubbleView.swift` — replace mediaGrid+pillList with attachmentPillGrid |
| **Modify** | `agentGuiTests/FileReferencePillSnapshotTests.swift` — add allEntries tests |

---

## 竞品模式对照

| 本计划实现 | VS Code 对应 | Open WebUI 对应 |
|-----------|-------------|----------------|
| `AttachmentPillView` 按 kind 分发 | `ChatAttachmentsContentPart.renderAttachment()` 按 kind 分发到 Widget 子类 | `FileItem` + `Image` 按 type 分支 |
| `AttachmentPillStyle` 颜色 Token | `OmittedState` → `.warning` CSS class | `colorClassName` prop |
| `AttachmentPillViewModel` 纯逻辑 helper | `IChatAttachmentWidgetRegistry` 工厂模式 | props 驱动 |
| `openBehavior` 路由 | `AbstractChatAttachmentWidget.onOpen` virtual | `FileItem` on:click → `FileItemModal` or `window.open` |
| `.contextMenu { Reveal / Copy }` | `.contextmenu` event handler | 无右键菜单 |
| `allEntries` 统一条目列表 | `variables: readonly IChatRequestVariableEntry[]` 统一数组 | `message.files` 单一数组 |
| `ChatFlowLayout` 容器 | `.chat-attached-context` flexbox | `flex overflow-x-auto gap-2 flex-wrap` |

---

## 不做的事项 (YAGNI)

| 提议 | 理由 |
|------|------|
| 删除 `FileReferencePillView.swift` | 属于 CV-FA5 冗余清理阶段 |
| 删除 `MediaThumbnailCell` | 属于 CV-FA5 |
| 删除 `mediaGrid`/`fileReferencePillList` 函数 | 属于 CV-FA5，当前仅新增不删除 |
| 图片 pill 内嵌 LightBox 预览 | 复杂度高，当前复用 MediaViewerView sheet |
| pill 拖拽复制 | 用户需求不明确 |
