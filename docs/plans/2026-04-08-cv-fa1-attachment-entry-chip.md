# CV-FA1: 统一输入区 AttachmentEntryChipView 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `contextChip()`、`fileChip()`、`inputDirectiveChip()` 三个重复实现合并为单一 `AttachmentEntryChipView` 组件，消除 `FileThumbnailView` 与文字 chip 之间的视觉不一致。

**Architecture:** 新增 `_ChipContainer` 底层容器（统一材质/圆角/dismiss 按钮样式），在其上构建 `FileIconChip`（图标+文件名）和 `MediaThumbnailChip`（图片/PDF 缩略图）两个变体，`AttachmentEntryChipView` 根据文件类型分发。`AttachedFile` 新增 `origin: AttachmentOrigin` 和 `uploadStatus: UploadStatus`，但 **CV-FA1 不涉及持久化** —— `AttachmentOrigin` 枚举定义前置在本 Feature，CV-FA2 再向 `MessageAttachment` 添加同名字段。

**Tech Stack:** Swift 6.0+, SwiftUI, Swift Testing (`@Test`)

---

## 竞品设计参考

### Open WebUI `FileItem.svelte` 关键模式
```svelte
<!-- 单一组件，props 驱动所有变体 -->
export let dismissible = false;   // nil → 不显示 × 按钮
export let loading = false;       // true → <Spinner/> 代替图标
export let small = false;         // compact 模式（圆角/内边距缩小）
export let colorClassName = '...'; // 主题化，不硬编码颜色

{#if dismissible}
  <button aria-label={$i18n.t('Remove File')}
          class="... group-hover:visible invisible transition"
          on:click|stopPropagation={() => dispatch('dismiss')}>
    <XMark />
  </button>
{/if}
```
> 核心洞见：`dismissible=false` → × 按钮完全不渲染；`loading=true` → `<Spinner/>` 替代图标；dismiss 按钮 `group-hover:visible` 默认隐藏，hover 时才出现。

### VS Code Copilot Chat `AbstractChatAttachmentWidget` 关键模式
> （源码位于 `src/vs/workbench/contrib/chat/browser/chatInputPart.ts`，类名已验证）

```ts
// 基类提供共享逻辑：删除按钮、aria 标签、hover 动画
abstract class AbstractChatAttachmentWidget {
    protected readonly _onDidChangeVisibility;
    protected renderDeleteButton(container: HTMLElement): void { ... }
    protected setAriaLabel(label: string): void { ... }
}
// 具体子类只 override 渲染内容，不重写删除逻辑
class FileChatAttachmentWidget extends AbstractChatAttachmentWidget { ... }
class ImageChatAttachmentWidget extends AbstractChatAttachmentWidget { ... }
```
> 核心洞见：SwiftUI 等价于让 `_ChipContainer` 承担基类职责，具体内容通过 `@ViewBuilder content` 注入。

---

## 文件清单

| 操作 | 文件 |
|------|------|
| 新建 | `agentGui/Views/AttachmentEntryChipView.swift` |
| 修改 | `agentGui/Models/AttachedFile.swift` |
| 修改 | `agentGui/Views/ChatView+InputArea.swift` |
| 新建 | `agentGuiTests/AttachmentEntryChipViewTests.swift` |

---

## Task 1: 为 `AttachedFile` 添加 `AttachmentOrigin` 和 `UploadStatus`

**Files:**
- Modify: `agentGui/Models/AttachedFile.swift`

### Step 1: 编写失败测试

新建 `agentGuiTests/AttachmentEntryChipViewTests.swift`：

```swift
import Testing
@testable import agentGui

struct AttachmentEntryChipViewTests {

    // MARK: - AttachedFile origin & uploadStatus

    @Test
    func attachedFileDefaultOriginIsExternal() {
        let file = AttachedFile(name: "photo.png", url: URL(fileURLWithPath: "/tmp/photo.png"))
        #expect(file.origin == .external)
    }

    @Test
    func attachedFileAcceptsFocusedOrigin() {
        let file = AttachedFile(
            name: "main.swift",
            url: URL(fileURLWithPath: "/tmp/main.swift"),
            origin: .focused
        )
        #expect(file.origin == .focused)
    }

    @Test
    func attachedFileDefaultUploadStatusIsPending() {
        let file = AttachedFile(name: "doc.pdf", url: URL(fileURLWithPath: "/tmp/doc.pdf"))
        #expect(file.uploadStatus == .pending)
    }
}
```

### Step 2: 运行测试确认失败

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-cv-fa1-task1 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/AttachmentEntryChipViewTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed"
```
预期：**编译错误** — `origin` / `uploadStatus` 属性不存在。

### Step 3: 修改 `AttachedFile.swift`

```swift
// agentGui/Models/AttachedFile.swift

import Foundation

/// 附件来源，区分三种文件引用类型。
/// CV-FA2 会将同名枚举镜像到 MessageAttachment.originRaw 持久化字段。
enum AttachmentOrigin: String, Codable, Equatable {
    case project   // @Mention 项目文件
    case focused   // 当前聚焦文件 / 编辑器选区
    case external  // 用户手动拖入或附加的外部文件
}

/// 输入区临时文件，仅存在于发送前。
struct AttachedFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    var origin: AttachmentOrigin = .external
    var uploadStatus: UploadStatus = .pending

    enum UploadStatus: Equatable {
        case pending    // 等待（本地文件通常常驻此态）
        case uploading  // 上传中（未来远程文件使用）
        case uploaded   // 完成
    }

    var path: String { url.path }
    var isImage: Bool { AttachedFile.pathIsImage(url.path) }
    var isPDF: Bool { AttachedFile.pathIsPDF(url.path) }

    static func pathIsImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
    }

    static func pathIsPDF(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "pdf"
    }
}
```

> **注意：** `id = UUID()` 保留原有行为（每次创建不同）。新增 `origin` / `uploadStatus` 有默认值，现有所有调用站无需改动。

### Step 4: 运行测试确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-cv-fa1-task1 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/AttachmentEntryChipViewTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed"
```
预期：`** TEST SUCCEEDED **`

### Step 5: Commit

```bash
git add agentGui/Models/AttachedFile.swift agentGuiTests/AttachmentEntryChipViewTests.swift
git commit -m "feat(cv-fa1): add AttachmentOrigin + UploadStatus to AttachedFile"
```

---

## Task 2: 实现 `_ChipContainer` — 底层共享 chip 容器

**Files:**
- Create: `agentGui/Views/AttachmentEntryChipView.swift`

### Step 1: 添加测试 — `_ChipContainer` 无 `onRemove` 时不渲染 × 按钮

> SwiftUI 视图无法直接单测渲染树，因此测试辅助函数和 hosting 逻辑。此步验证 `ChipContainerConfig` 结构体的可测计算属性。

在 `AttachmentEntryChipViewTests.swift` 末尾追加：

```swift
    // MARK: - _ChipContainer config

    @Test
    func chipContainerShowsRemoveOnlyWhenCallbackProvided() {
        let withRemove = ChipContainerConfig(tint: .blue, onRemove: { })
        let withoutRemove = ChipContainerConfig(tint: .blue, onRemove: nil)
        #expect(withRemove.hasRemoveButton == true)
        #expect(withoutRemove.hasRemoveButton == false)
    }

    @Test
    func chipContainerIsLoadingWhenUploadStatusIsUploading() {
        #expect(ChipContainerConfig.isLoading(for: .uploading) == true)
        #expect(ChipContainerConfig.isLoading(for: .pending) == false)
        #expect(ChipContainerConfig.isLoading(for: .uploaded) == false)
    }
```

### Step 2: 运行确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-cv-fa1-task2 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/AttachmentEntryChipViewTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed"
```
预期：**编译错误** — `ChipContainerConfig` 不存在。

### Step 3: 创建 `AttachmentEntryChipView.swift`

新建文件 `agentGui/Views/AttachmentEntryChipView.swift`，内容如下：

```swift
//
//  AttachmentEntryChipView.swift
//  agentGui
//
//  输入区统一附件 Chip — 替代 contextChip() / fileChip() / inputDirectiveChip() 三个独立实现。
//
//  参考:
//  - Open WebUI FileItem.svelte: dismissible prop + loading → Spinner 替代图标
//  - VS Code AbstractChatAttachmentWidget: 基类承担 dismiss 按钮 + aria 共享逻辑

import SwiftUI

// MARK: - Config（可测辅助结构，与 View 解耦）

/// `_ChipContainer` 的纯数据配置，用于单元测试和条件渲染判断。
struct ChipContainerConfig {
    let tint: Color
    let onRemove: (() -> Void)?

    var hasRemoveButton: Bool { onRemove != nil }

    static func isLoading(for status: AttachedFile.UploadStatus) -> Bool {
        status == .uploading
    }
}

// MARK: - _ChipContainer（基础 chip 容器）

/// 所有输入区 chip 的底层容器。
/// 提供：ultraThinMaterial 背景、cornerRadius 8、0.10 边框、× 按钮（可选）、hover 缩放。
///
/// 对标 Open WebUI: `dismissible=false` → × 按钮不渲染；`loading=true` → content 区换 Spinner。
/// 对标 VS Code: AbstractChatAttachmentWidget 基类负责 dismiss + aria，内容子类注入。
struct _ChipContainer<Content: View>: View {
    let tint: Color
    var isLoading: Bool = false
    var onRemove: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            chipBody

            // × 按钮 — 仅 onRemove != nil 时渲染（对标 Open WebUI: dismissible 模式）
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .background(
                            Circle()
                                .fill(Color(NSColor.windowBackgroundColor))
                                .padding(1)
                        )
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .opacity(isHovered ? 1 : 0)            // hover 时才可见（对标 Open WebUI group-hover:visible）
                .accessibilityLabel("移除附件")
            }
        }
        .scaleEffect(isHovered ? ChatMotion.hoverScale : 1.0)
        .animation(ChatMotion.hoverSpring, value: isHovered)
        .onHover { isHovered = $0 }
        // 入场动效（对标设计规范 §4.2）
        .transition(
            .scale(scale: 0.85).combined(with: .opacity)
        )
    }

    private var chipBody: some View {
        HStack(spacing: 5) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else {
                content()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

// MARK: - FileIconChip（文字文件、项目文件 @Mention、聚焦文件、指令）

/// 图标 + 名称样式的 chip，适用于非图片/PDF 文件及 inputDirective。
struct FileIconChip: View {
    let systemImage: String
    let label: String
    let tint: Color
    var isLoading: Bool = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        _ChipContainer(tint: tint, isLoading: isLoading, onRemove: onRemove) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
            Text(label)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.72))
                .lineLimit(1)
        }
    }
}

// MARK: - MediaThumbnailChip（图片 / PDF 缩略图）

/// 72×72 缩略图 chip，适用于图片和 PDF 附件。
/// 对标 Open WebUI: icon 区域在 loading 时切换到 Spinner，图标在 loaded 后替换为真实图片。
struct MediaThumbnailChip: View {
    let file: AttachedFile
    var onRemove: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @State private var thumbnail: NSImage? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnailBody
                .onTapGesture { onTap?() }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .background(
                            Circle()
                                .fill(Color(NSColor.windowBackgroundColor))
                                .padding(1)
                        )
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("移除附件")
            }
        }
        .task { thumbnail = await mediaThumbImage(url: file.url, targetWidth: 72) }
        // 入场动效
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    @ViewBuilder
    private var thumbnailBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))

            if file.uploadStatus == .uploading {
                ProgressView()
                    .controlSize(.regular)
            } else if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: file.isPDF ? "doc.richtext" : "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }

            if file.isPDF {
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
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - AttachmentEntryChipView（公开入口）

/// 输入区统一附件 chip 入口视图。
/// - 图片 / PDF → `MediaThumbnailChip`（缩略图）
/// - 其他文件 → `FileIconChip`（图标 + 文件名）
/// - 聚焦文件 / 指令 → 调用方直接使用 `FileIconChip`
struct AttachmentEntryChipView: View {
    let file: AttachedFile
    var onRemove: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        if file.isImage || file.isPDF {
            MediaThumbnailChip(file: file, onRemove: onRemove, onTap: onTap)
        } else {
            FileIconChip(
                systemImage: FileIconSymbolResolver.symbol(forFileName: file.name),
                label: file.name,
                tint: tintColor,
                isLoading: file.uploadStatus == .uploading,
                onRemove: onRemove
            )
        }
    }

    private var tintColor: Color {
        switch file.origin {
        case .focused:  return .orange
        case .project:  return .accentColor
        case .external: return .secondary
        }
    }
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-cv-fa1-task2 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/AttachmentEntryChipViewTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed"
```
预期：`** TEST SUCCEEDED **`

### Step 5: Commit

```bash
git add agentGui/Views/AttachmentEntryChipView.swift
git commit -m "feat(cv-fa1): add _ChipContainer, FileIconChip, MediaThumbnailChip, AttachmentEntryChipView"
```

---

## Task 3: 向 `ChipContainerConfig` 追加辅助方法测试覆盖

**Files:**
- Modify: `agentGuiTests/AttachmentEntryChipViewTests.swift`

### Step 1: 追加测试 — 来源颜色映射

```swift
    // MARK: - 来源 tint 颜色

    @Test
    func tintColorForFocusedOriginIsOrange() {
        // 通过 AttachmentEntryChipView.tintColor 内部逻辑验证（通过暴露辅助函数）
        #expect(AttachmentOriginTint.color(for: .focused) == .orange)
        #expect(AttachmentOriginTint.color(for: .project) == .accentColor)
        #expect(AttachmentOriginTint.color(for: .external) == .secondary)
    }
```

在 `AttachmentEntryChipView.swift` 底部追加：

```swift
// MARK: - Testable Helpers

/// @testable 可见的 tint 映射，避免在测试中实例化视图。
enum AttachmentOriginTint {
    static func color(for origin: AttachmentOrigin) -> Color {
        switch origin {
        case .focused:  return .orange
        case .project:  return .accentColor
        case .external: return .secondary
        }
    }
}
```

并将 `AttachmentEntryChipView.tintColor` 改为调用 `AttachmentOriginTint.color(for: file.origin)`。

### Step 2: 运行测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-cv-fa1-task3 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/AttachmentEntryChipViewTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed"
```
预期：`** TEST SUCCEEDED **`

### Step 3: Commit

```bash
git add agentGui/Views/AttachmentEntryChipView.swift \
        agentGuiTests/AttachmentEntryChipViewTests.swift
git commit -m "test(cv-fa1): add origin tint mapping test + AttachmentOriginTint helper"
```

---

## Task 4: 替换 `ChatView+InputArea.swift` 中的三个 chip 函数

**Files:**
- Modify: `agentGui/Views/ChatView+InputArea.swift`

### Step 1: 了解当前调用站

- `contextChipsRow` (L288)：调用 `contextChip(systemImage:label:tint:onRemove:)` 2 次
- `fileChipsRow` (L504)：循环调用 `FileThumbnailView` 或 `fileChip(_:)`
- `inputDirectiveChipsRow` (L525)：循环调用 `inputDirectiveChip(_:)`

### Step 2: 替换 `fileChipsRow`

将 `fileChipsRow` 变量整体替换：

**旧实现**（L504–L523）：
```swift
var fileChipsRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 8) {
            ForEach(attachedFiles) { file in
                if file.isImage || file.isPDF {
                    FileThumbnailView(
                        file: file,
                        onRemove: { attachedFiles.removeAll { $0.id == file.id } },
                        onTap: { viewingMedia = MediaItem(url: file.url) }
                    )
                    .padding(.top, 4)
                } else {
                    fileChip(file)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.bottom, 6)
    }
}
```

**新实现**：
```swift
var fileChipsRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 8) {
            ForEach(attachedFiles) { file in
                AttachmentEntryChipView(
                    file: file,
                    onRemove: { attachedFiles.removeAll { $0.id == file.id } },
                    onTap: { viewingMedia = MediaItem(url: file.url) }
                )
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 6)
    }
}
```

### Step 3: 替换 `contextChipsRow`

**旧实现**（contextChip 调用部分保持行数不变，仅替换 chip 构造）：

```swift
var contextChipsRow: some View {
    HStack(spacing: 6) {
        if let fileURL = workspaceState.selectedFile,
           showFileContext || (showSelectionContext && workspaceState.editorSelectedText?.isEmpty == false) {
            // 旧：contextChip(systemImage: "text.cursor", label: combinedFileContextLabel, tint: .orange) { ... }
            FileIconChip(
                systemImage: "text.cursor",
                label: combinedFileContextLabel,
                tint: .orange,
                onRemove: {
                    showFileContext = false
                    showSelectionContext = false
                }
            )
        } else if showFileContext, let fileURL = workspaceState.selectedFile {
            // 旧：contextChip(systemImage: "doc.text", label: ..., tint: .accentColor) { ... }
            FileIconChip(
                systemImage: "doc.text",
                label: WorkspaceFileContextFormatter.displayLabel(for: fileURL),
                tint: .accentColor,
                onRemove: { showFileContext = false }
            )
        }
        Spacer(minLength: 0)
    }
}
```

### Step 4: 替换 `inputDirectiveChipsRow`

```swift
var inputDirectiveChipsRow: some View {
    HStack(spacing: 6) {
        ForEach(activeInputDirectives, id: \.id) { directive in
            FileIconChip(
                systemImage: "command",
                label: directiveLabel(directive),
                tint: .accentColor,
                onRemove: { activeInputDirectives.removeAll { $0.id == directive.id } }
            )
        }
        Spacer(minLength: 0)
    }
}

private func directiveLabel(_ directive: ChatInputDirective) -> String {
    switch directive {
    case .skill(let value):
        return "Skill: \(value.displayName)"
    }
}
```

### Step 5: 删除三个旧函数

删除以下函数体（整段）：
- `func contextChip(systemImage:label:tint:onRemove:)` 约 L479–L503
- `func fileChip(_ file:)` 约 L567–L590
- `func inputDirectiveChip(_ directive:)` 约 L534–L566
- `func fileIcon(for name:)` —— 若 `FileIconSymbolResolver` 仍有其他调用站则保留，否则删除

### Step 6: 编译验证（无测试回归）

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-cv-fa1-task4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning: |Build succeeded|Build FAILED"
```
预期：`Build succeeded`

### Step 7: Commit

```bash
git add agentGui/Views/ChatView+InputArea.swift
git commit -m "refactor(cv-fa1): replace contextChip/fileChip/inputDirectiveChip with AttachmentEntryChipView"
```

---

## Task 5: 向 Xcode 项目注册新文件

> Xcode 项目需要在 `project.pbxproj` 中添加对 `AttachmentEntryChipView.swift` 和测试文件的引用。

### Step 1: 在 Xcode 中添加（GUI 操作）

1. 打开 `agentGui.xcodeproj`
2. 将 `AttachmentEntryChipView.swift` 拖入 `agentGui/Views/` Group（target: agentGui）
3. 将 `AttachmentEntryChipViewTests.swift` 拖入 `agentGuiTests/` Group（target: agentGuiTests）

或在终端验证文件已被 xcodebuild 识别（如果使用 create_file 工具创建的文件已自动加入工程）：

```bash
grep "AttachmentEntryChipView" agentGui.xcodeproj/project.pbxproj | head -5
```

如果无输出，需手动在 Xcode 中添加文件引用。

### Step 2: 全量测试 smoke

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-cv-fa1-smoke \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/AttachmentEntryChipViewTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|failed|Test Suite"
```
预期：所有 5 个测试通过。

### Step 3: Commit

```bash
git add agentGui.xcodeproj/project.pbxproj
git commit -m "chore(cv-fa1): register AttachmentEntryChipView files in Xcode project"
```

---

## Task 6: 验收检查

### 验收清单

| 项目 | 验证方式 |
|------|---------|
| ① 三个 chip 函数已删除 | `grep -r "func contextChip\|func fileChip\|func inputDirectiveChip" agentGui/` 无输出 |
| ② `FileThumbnailView` 调用站已替换 | `grep -r "FileThumbnailView" agentGui/Views/ChatView+InputArea.swift` 无输出 |
| ③ `AttachmentEntryChipView.swift` 编译无警告 | xcodebuild 输出无 warning |
| ④ 测试全通过 | `** TEST SUCCEEDED **` |
| ⑤ 外观一致性 | 在 Simulator / 真机：文件 chip / 聚焦文件 chip / 指令 chip 圆角均为 8pt；× 按钮位置和大小一致 |
| ⑥ hover 行为 | 鼠标悬停时 × 可见 + 1.02x 缩放 |
| ⑦ Loading 状态 | 将 `file.uploadStatus = .uploading` 注入后 chip 区显示 ProgressView |

### 最终全量构建

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-cv-fa1-final \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

---

## 后续 Feature 依赖说明

| Feature | 依赖本 Feature 的内容 |
|---------|----------------------|
| CV-FA2  | `AttachmentOrigin` 枚举（已在 `AttachedFile.swift` 定义，CV-FA2 复用并镜像到 `MessageAttachment.originRaw`）|
| CV-FA3  | `AttachmentOriginTint` 颜色映射（CV-FA3 的 `AttachmentPillView` 可直接复用） |
| CV-FA5  | `FileThumbnailView` 若还有残留调用站，CV-FA5 清理阶段删除整个结构体 |

---

## 不做的事项

| 提议 | 理由 |
|------|------|
| 修改 `MediaThumbnailCell` | 属于消息历史区域，CV-FA3 处理 |
| 向 `MessageAttachment` 添加 `originRaw` | CV-FA2 任务范围 |
| 聚焦文件持久化迁移 | CV-FA2 任务范围 |
| 在本 Feature 删除 `FileThumbnailView` 结构体 | 若 CV-FA3/FA5 尚未完成，`MediaViewerView` 中可能有引用；保留到 CV-FA5 统一清理 |
