# ArtifactShelf UX Improvement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade message deliverable rendering so files, folders, and web links are visually distinct, clickable with the correct open behavior, and command summaries are collapsed by default to three visible rows.

**Architecture:** Keep the persistence layer unchanged and implement this as a presentation-plus-view feature. Extend artifact presentation models with a typed resource kind, classify tool-call paths inside `AgentExecutionProjection`, and keep open behavior in the UI layer while extracting the routing decision into a small pure helper so it can be tested without driving SwiftUI clicks. Folded command summaries remain local view state inside `ArtifactShelfView`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, AppKit `NSWorkspace`, Observation `@Environment`, Swift Testing, existing `AgentExecutionProjection`, `ArtifactShelfView`, and `WorkspaceState`.

---

## 1. 实施原则

- 不改 `Message`、`ToolCall`、`SwiftData` schema；只改 projection、presentation、view。
- 先写失败测试，再实现最小代码；每个任务完成后跑对应 focused tests。
- 点击打开策略必须可测试，不能把全部决策埋进 `Button` action 里。
- Markdown / 文本文件统一走应用内部编辑器，保持与现有 `WorkspaceState.selectedFile` 打开路径一致。
- 命令摘要折叠状态只存在于视图层，不下沉到模型或持久化层。
- 保持 YAGNI：本次不做右键菜单、不做引用卡增强、不做命令输出详情展开。

## 2. 相关文件

### 设计输入

- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-24-artifact-shelf-ux-improvement-design.md`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Enums.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentExecutionProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ArtifactShelfView.swift`

### 新增测试文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ArtifactShelfProjectionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ArtifactShelfOpenDispatchTests.swift`

### 可能新增的通用工具文件

- 如仓库内不存在可复用的鼠标指针修饰器，再新增：
  `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/View+HoverCursor.swift`

## 3. 任务拆解

### Task 1: 为资源分类建立失败测试，固定 projection 契约

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ArtifactShelfProjectionTests.swift`
- Modify later: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentExecutionProjection.swift`
- Modify later: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Enums.swift`

**Step 1: 写失败测试，覆盖分类与去重规则**

新增测试覆盖：

- `edit` tool call 生成 `changedFiles`
- `read/search/fetch` tool call 生成 `referencedFiles`
- `http/https` 字符串分类为 `.webURL`
- 本地存在目录分类为 `.localFolder`
- 本地存在文件分类为 `.localFile`
- 重复 path 只保留一个 chip
- `execute` tool call 只进入 `commandSummaries`

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct ArtifactShelfProjectionTests {

    @Test func makeArtifactsClassifiesURLFileAndFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appending(path: "README.md")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("# Demo".utf8))
        let folderURL = root.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let readFile = ToolCall.stub(kind: .read, filePath: fileURL.path)
        let readFolder = ToolCall.stub(kind: .read, filePath: folderURL.path)
        let fetchURL = ToolCall.stub(kind: .fetch, filePath: "https://example.com/spec")
        let execute = ToolCall.stub(kind: .execute, title: "xcodebuild test")

        let presentation = AgentExecutionProjection.makeArtifactsForTests(
            from: [readFile, readFolder, fetchURL, execute]
        )

        #expect(presentation.referencedFiles.count == 3)
        #expect(presentation.commandSummaries.count == 1)
        #expect(presentation.referencedFiles[0].kind == .localFile(fileURL.standardizedFileURL))
    }
}
```

**Step 2: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ArtifactShelfProjectionTests
```

Expected: FAIL，因为 `ArtifactResourceKind`、`kind` 字段和测试入口都还不存在。

**Step 3: 在 `Enums.swift` 新增 `ArtifactResourceKind`**

最小实现：

```swift
enum ArtifactResourceKind: Equatable {
    case localFile(URL)
    case localFolder(URL)
    case webURL(URL)
    case unknown(String)

    var systemImage: String {
        switch self {
        case .localFile: "doc.fill"
        case .localFolder: "folder.fill"
        case .webURL: "link"
        case .unknown: "questionmark.square"
        }
    }

    var openableURL: URL? {
        switch self {
        case .localFile(let url), .localFolder(let url), .webURL(let url):
            return url
        case .unknown:
            return nil
        }
    }
}
```

**Step 4: 在 `AgentExecutionProjection.swift` 扩展 presentation 模型**

新增：

```swift
struct ArtifactChipPresentation: Equatable, Identifiable {
    let id: String
    let displayName: String
    let path: String
    let kind: ArtifactResourceKind
}
```

并补充分类函数：

```swift
nonisolated private static func classifyKind(for rawPath: String) -> ArtifactResourceKind {
    if (rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://")),
       let url = URL(string: rawPath) {
        return .webURL(url)
    }

    let fileURL = URL(fileURLWithPath: rawPath).standardizedFileURL
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) {
        return isDirectory.boolValue ? .localFolder(fileURL) : .localFile(fileURL)
    }

    if rawPath.hasSuffix("/") {
        return .localFolder(fileURL)
    }

    return .localFile(fileURL)
}
```

`makeArtifactChips(from:)` 更新为：

```swift
return ArtifactChipPresentation(
    id: toolCall.id.uuidString,
    displayName: toolCall.fileName ?? fileURL.lastPathComponent,
    path: path,
    kind: classifyKind(for: path)
)
```

**Step 5: 仅为测试暴露最小入口**

不要把整个 `makeArtifacts(from:)` 改成 public。只增加 internal test hook：

```swift
extension AgentExecutionProjection {
    nonisolated static func makeArtifactsForTests(from toolCalls: [ToolCall]) -> ArtifactShelfPresentation {
        makeArtifacts(from: toolCalls)
    }
}
```

如果团队更偏好 `fileprivate` + 同文件测试入口，也可以把这个 helper 放在 `#if DEBUG` 下，但保持默认构建可编译。

**Step 6: 重新跑 focused tests，确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 7: Commit**

```bash
git add agentGui/Models/Enums.swift agentGui/ViewModels/AgentExecutionProjection.swift agentGuiTests/ArtifactShelfProjectionTests.swift
git commit -m "feat: classify artifact shelf resources"
```

### Task 2: 为打开分发策略建立失败测试，固定“内部编辑器 vs 系统打开”契约

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ArtifactShelfOpenDispatchTests.swift`
- Modify later: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ArtifactShelfView.swift`

**Step 1: 写失败测试，覆盖打开策略**

新增测试覆盖：

- `.md`、`.markdown`、`.txt` 走内部编辑器
- `.swift`、`.json`、`.yaml`、无扩展名脚本走内部编辑器
- `.png`、`.pdf` 等二进制文件走系统默认应用
- `.localFolder` 走 Finder
- `.webURL` 走浏览器
- `.unknown` 不执行打开

测试建议不要直接测 `NSWorkspace` 副作用，而是先测一个纯路由器：

```swift
import Foundation
import Testing
@testable import agentGui

struct ArtifactShelfOpenDispatchTests {

    @Test func markdownFilesRouteToInternalEditor() {
        let url = URL(fileURLWithPath: "/tmp/Notes.md")
        let action = ArtifactOpenDispatcher.resolve(for: .localFile(url))
        #expect(action == .openInEditor(url.standardizedFileURL))
    }

    @Test func pdfFilesRouteToSystemOpen() {
        let url = URL(fileURLWithPath: "/tmp/Guide.pdf")
        let action = ArtifactOpenDispatcher.resolve(for: .localFile(url))
        #expect(action == .openExternally(url.standardizedFileURL))
    }
}
```

**Step 2: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ArtifactShelfOpenDispatchTests
```

Expected: FAIL，因为 `ArtifactOpenDispatcher` 和 `ArtifactOpenAction` 还不存在。

**Step 3: 在 `ArtifactShelfView.swift` 中新增纯分发器**

即使设计文档要求“打开逻辑留在 View 层”，也把“决策”抽成同文件 internal helper，既不新增架构层级，又能测试：

```swift
enum ArtifactOpenAction: Equatable {
    case openInEditor(URL)
    case openExternally(URL)
    case none
}

enum ArtifactOpenDispatcher {
    static let appEditableExtensions: Set<String> = [
        "md", "markdown",
        "txt", "text",
        "swift", "py", "js", "ts", "jsx", "tsx",
        "json", "yaml", "yml", "toml", "xml",
        "sh", "bash", "zsh",
        "css", "html", "htm",
    ]

    static func resolve(for kind: ArtifactResourceKind) -> ArtifactOpenAction {
        switch kind {
        case .localFile(let url):
            let normalized = url.standardizedFileURL
            let ext = normalized.pathExtension.lowercased()
            if appEditableExtensions.contains(ext) || ext.isEmpty {
                return .openInEditor(normalized)
            }
            return .openExternally(normalized)
        case .localFolder(let url), .webURL(let url):
            return .openExternally(url.standardizedFileURL)
        case .unknown:
            return .none
        }
    }
}
```

**Step 4: 在 `ArtifactShelfView` 中把副作用集中到一个执行器**

```swift
@MainActor
private func open(_ kind: ArtifactResourceKind) {
    switch ArtifactOpenDispatcher.resolve(for: kind) {
    case .openInEditor(let url):
        workspaceState.selectedFile = url
    case .openExternally(let url):
        NSWorkspace.shared.open(url)
    case .none:
        break
    }
}
```

**Step 5: 重新跑 focused tests，确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Views/ArtifactShelfView.swift agentGuiTests/ArtifactShelfOpenDispatchTests.swift
git commit -m "feat: add artifact open dispatch policy"
```

### Task 3: 接入点击打开与资源类型图标，完成交付结果 chip 交互

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ArtifactShelfView.swift`
- Verify against: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`

**Step 1: 写最小视图改动计划，避免一次改太多**

本任务只做三件事：

- 注入 `@Environment(WorkspaceState.self)`
- 把 chip 改成 `Button`
- 图标从固定 `doc` 改成 `item.kind.systemImage`

**Step 2: 改 `ArtifactShelfView` 顶部环境依赖**

```swift
struct ArtifactShelfView: View {
    let presentation: ArtifactShelfPresentation
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View { ... }
}
```

**Step 3: 改 `artifactChip`，接入点击行为**

```swift
private func artifactChip(_ item: ArtifactChipPresentation, tint: Color) -> some View {
    Button {
        open(item.kind)
    } label: {
        HStack(spacing: 5) {
            Image(systemName: item.kind.systemImage)
                .font(.caption2)
            Text(item.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .foregroundStyle(item.kind.openableURL != nil ? tint : tint.opacity(0.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
    .buttonStyle(.plain)
    .disabled(item.kind.openableURL == nil)
    .help(item.path)
}
```

**Step 4: 只跑相关测试与编译检查**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ArtifactShelfProjectionTests -only-testing:agentGuiTests/ArtifactShelfOpenDispatchTests
```

Expected: PASS。

再跑一次构建：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED。

**Step 5: Commit**

```bash
git add agentGui/Views/ArtifactShelfView.swift
git commit -m "feat: make artifact shelf chips clickable"
```

### Task 4: 实现命令摘要折叠，默认最多显示三行

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ArtifactShelfView.swift`

**Step 1: 先写 focused UI regression 测试设计说明**

如果当前工程没有 SwiftUI view inspection 依赖，不要硬写脆弱的点击 UI 单测。用以下方式保证质量：

- 纯逻辑单测：新增 `visibleSummaryItems(items:isExpanded:limit:)` internal helper
- 构建验证：确保 view 代码编译通过
- 手工验证清单：在实现计划末尾给出具体验证步骤

**Step 2: 写失败测试，固定折叠逻辑**

把测试放到 `ArtifactShelfOpenDispatchTests.swift` 或新增 `ArtifactShelfSummaryFoldTests.swift` 均可；优先新增独立文件如果任务实现后逻辑超过 30 行。

示例：

```swift
@Test func collapsedSummaryShowsFirstThreeItemsOnly() {
    let items = (1...5).map { ArtifactSummaryLine(id: "\($0)", text: "cmd \($0)") }
    let visible = ArtifactShelfSummaryVisibility.visibleItems(items, isExpanded: false, limit: 3)
    #expect(visible.map(\.id) == ["1", "2", "3"])
}
```

**Step 3: 在 `ArtifactShelfView.swift` 中提取折叠 helper 与子视图**

建议实现：

```swift
enum ArtifactShelfSummaryVisibility {
    static func visibleItems(
        _ items: [ArtifactSummaryLine],
        isExpanded: Bool,
        limit: Int = 3
    ) -> [ArtifactSummaryLine] {
        isExpanded ? items : Array(items.prefix(limit))
    }
}
```

然后新增：

```swift
private struct CollapsibleSummarySection: View {
    let title: String
    let iconName: String
    let items: [ArtifactSummaryLine]
    let tint: Color
    @State private var isExpanded = false

    var body: some View { ... }
}
```

视图规则：

- 默认 `isExpanded = false`
- 仅当 `items.count > 3` 时显示“展开全部 N 条”
- 展开按钮使用 `.buttonStyle(.plain)`
- 每条 `Text(item.text)` 使用 `.lineLimit(3)`，避免单条摘要撑爆布局

**Step 4: 把命令摘要 section 切到新子视图**

原先：

```swift
artifactSummarySection(title: "命令摘要", ...)
```

替换为：

```swift
CollapsibleSummarySection(
    title: "命令摘要",
    iconName: "terminal",
    items: presentation.commandSummaries,
    tint: .green
)
```

`验证摘要` 先保持原逻辑，避免一次扩大变更面。若后续确认也需要折叠，再单独追加。

**Step 5: 跑 focused tests 与构建**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ArtifactShelfOpenDispatchTests
```

Expected: PASS，如果折叠 helper 测试也放进该文件则一并通过。

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED。

**Step 6: Commit**

```bash
git add agentGui/Views/ArtifactShelfView.swift agentGuiTests/ArtifactShelfOpenDispatchTests.swift
git commit -m "feat: collapse artifact command summaries"
```

### Task 5: 补齐鼠标指针体验并做最终验证

**Files:**
- Modify or Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/View+HoverCursor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ArtifactShelfView.swift`

**Step 1: 检查仓库是否已有统一 hover cursor 工具**

如果已有，直接复用并跳到 Step 3。  
如果没有，新建最小工具文件：

```swift
import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func hoverCursor(_ cursor: NSCursor) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active:
                cursor.push()
            case .ended:
                NSCursor.pop()
            }
        }
    }
}
```

**Step 2: 仅在可点击 chip 上使用该 modifier**

```swift
.hoverCursor(.pointingHand)
```

避免在 disabled 状态下继续显示可点击光标。必要时把 modifier 包进条件分支。

**Step 3: 全量相关测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ArtifactShelfProjectionTests \
  -only-testing:agentGuiTests/ArtifactShelfOpenDispatchTests
```

Expected: PASS。

**Step 4: 跑质量烟测或构建**

优先：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

如果时间允许，再跑工作区已有 smoke task：

```bash
./scripts/run_quality_smoke.sh
```

Expected: BUILD SUCCEEDED；如 smoke 覆盖消息 UI，不应出现新增回归。

**Step 5: 手工验证清单**

在应用里手工验证：

- Agent 消息中出现 `.md` 文件 chip，点击后右侧上下文窗口显示内部编辑器
- `.swift`、`.json` 文件 chip 同样走内部编辑器
- `.png` 或 `.pdf` 文件 chip 打开系统默认应用
- 文件夹 chip 打开 Finder
- `https://...` chip 打开默认浏览器
- 命令摘要超过 3 条时默认只显示 3 条，并出现展开按钮
- 点击“展开全部 N 条”后显示完整列表，再次点击可以收起
- Hover 到可点击 chip 时显示 pointing hand

**Step 6: Commit**

```bash
git add agentGui/Utilities/View+HoverCursor.swift agentGui/Views/ArtifactShelfView.swift
git commit -m "polish: refine artifact shelf pointer behavior"
```

## 4. 风险与控制

- `ArtifactResourceKind` 使用 `URL` 作为关联值，比较时必须统一走 `standardizedFileURL`，否则测试容易因为路径标准化失败。
- 不要把 `NSWorkspace.shared.open` 直接写进多个 button action；统一走 `open(_:)`，避免行为分叉。
- 无扩展名文件默认走内部编辑器有收益，但也可能覆盖少量二进制可执行文件；本次接受该 tradeoff，后续若有误判再引入 MIME 或 UTI 判定。
- 如果 `ArtifactShelfView` 中逻辑开始超过 250 行，应在实现阶段把 `CollapsibleSummarySection` 或 `ArtifactOpenDispatcher` 拆到独立文件，但在本计划范围内先不预设拆分。

## 5. 完成定义

满足以下条件才算完成：

- 文件 / 文件夹 / URL 三类 artifact 在 UI 上有可见区分
- Markdown / 文本文件点击后通过 `WorkspaceState.selectedFile` 进入内部编辑器
- 非文本文件 / 文件夹 / URL 点击后走系统默认打开行为
- 命令摘要默认折叠为前三条，可展开和收起
- 新增 focused tests 通过
- Debug build 成功
- 无 SwiftData 模型迁移，无 unrelated file churn

## 6. 推荐执行顺序

1. 先完成 Task 1，锁定 projection 分类。
2. 再完成 Task 2，锁定打开分发策略。
3. 然后完成 Task 3，把交互接到真实 UI。
4. 接着完成 Task 4，补命令摘要折叠。
5. 最后完成 Task 5，做鼠标指针与整体回归。

Plan complete and saved to `docs/plans/2026-03-24-artifact-shelf-ux-improvement-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
