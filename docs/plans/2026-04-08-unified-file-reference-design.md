# ChatView 统一文件引用设计文档

> **调研来源:** VS Code GitHub Copilot Chat (TypeScript)、Open WebUI (Svelte)、当前 agentGui 实现 (SwiftUI)
>
> **目标:** 将 ChatView 中三种文件引用类型（项目文件 @Mention、当前聚焦文件、外部附件）统一为一致的组件、交互、动效，并清理冗余代码。

---

## 一、现状问题分析

### 1.1 三种文件引用的现状

| 类型 | 英文名 | 数据模型 | 输入区渲染 | 消息历史渲染 |
|------|--------|---------|-----------|------------|
| 项目文件 @Mention | `.project` | `MessageAttachment` (SwiftData) | `MentionAwareEditor` 内嵌 mention token | 气泡底部 `FileReferencePillView` 列表 |
| 当前聚焦文件 | `.focused` | **无持久化，拼接进 `textContent`** | `contextChip(systemImage:label:tint:onRemove:)` | **纯文本，无结构化渲染** |
| 外部附件 | `.external` | 临时 `AttachedFile` struct → 发送时转 `MessageAttachment` | 图片/PDF → `FileThumbnailView`；其他 → `fileChip()` | 图片/PDF → `MediaThumbnailCell` + `mediaGrid`；其他文件 → `fileReferenceBadge(count:)`（仅显示数量）|

### 1.2 已确认的冗余与缺陷

#### 重复代码

| 问题 | 文件 A | 文件 B | 差异 |
|------|--------|--------|------|
| Chip 背景/圆角/dismiss 逻辑重复 | `contextChip()` L479 | `fileChip()` L567 | 字体大小、tint颜色、没有 dismiss |
| 缩略图加载/PDF badge 逻辑重复 | `FileThumbnailView` (MediaViewerView.swift L174) | `MediaThumbnailCell` (MediaViewerView.swift L236) | 尺寸(72px vs 80px)、点击行为 |
| `inputDirectiveChip()` 与 `fileChip()` 几乎一致 | `ChatView+InputArea.swift` L530 | L567 | 图标颜色、cornerRadius |

#### 功能缺失

- **`fileReferenceBadge(count:)` 不可交互**：显示"引用了 N 个文件"但无法点击展开/跳转，外部附件发送后丢失可及性
- **聚焦文件未持久化**：当前文件上下文被格式化成字符串追加到 `textContent`，消息历史中无法识别，且无法享受状态追踪（modified/missing）
- **外部附件无状态追踪**：`MessageAttachmentWatcher` 只监控 `.project` 来源文件，外部文件删除后 UI 无感知
- **Agent 消息 `ArtifactShelf` 自成一套**：`ArtifactChipButton` 与其他类型 pill 视觉不统一

### 1.3 竞品参考

#### VS Code GitHub Copilot Chat

```typescript
// 统一类型联合 (chatVariableEntries.ts)
export type IChatRequestVariableEntry =
  | IChatRequestFileEntry          // kind: 'file'
  | IImageVariableEntry            // kind: 'image'
  | IChatRequestImplicitVariableEntry  // kind: 'implicit' (聚焦文件/选区)
  | IPromptFileVariableEntry       // kind: 'promptFile'
  | ITerminalVariableEntry         // kind: 'terminal'
  | ... // 共 23 种 kind，但统一接口
```

关键设计原则：
- **单一 `kind` 字段区分 23 种附件类型，不写 23 个不同模型**
- `AbstractChatAttachmentWidget` 抽象基类提供：删除按钮、aria 标签、悬停动画
- `IChatAttachmentWidgetRegistry` 工厂模式：按 `kind` 注册渲染器，新类型无需改主流程
- `OmittedState` 枚举统一表达引用状态（NotOmitted / Partial / Full / ImageLimitExceeded）
- **隐式引用（聚焦文件）与显式引用走同一渲染路径**，仅 `kind` 不同

#### Open WebUI

```svelte
<!-- 单一 FileItem.svelte 组件，props 控制所有变体 -->
<FileItem
  item={file}
  name={file.name}
  type={file.type}         <!-- 'file' | 'collection' | 'note' | 'chat' -->
  size={file.size}
  loading={file.status === 'uploading'}
  dismissible={true}
  edit={true}
  small={true}            <!-- compact 模式 -->
  modal={...}             <!-- 点击行为 -->
/>
```

关键设计原则：
- **单一组件，props 驱动所有变体**（large/small、dismissible、loading等）
- `loading` 状态显示 `<Spinner/>` 代替图标 → 统一 uploading/uploaded/processed 三态流转
- 图片单独处理（thumbnail 逻辑不走 FileItem），但删除按钮逻辑完全复用
- `colorClassName` prop 支持主题化，不在组件内硬编码颜色

---

## 二、设计方案

### 2.1 统一数据模型

```swift
// MessageAttachment.swift 扩展
enum AttachmentOrigin: String, Codable {
    case project   // @Mention 项目文件
    case focused   // 当前聚焦文件/选区（新增，原先内联到 textContent）
    case external  // 用户手动上传的外部文件
}

// MessageAttachment 新增字段
var originRaw: String = AttachmentOrigin.project.rawValue

// 计算属性
var origin: AttachmentOrigin { AttachmentOrigin(rawValue: originRaw) ?? .external }
```

输入区临时模型 `AttachedFile` 扩展：

```swift
struct AttachedFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    var origin: AttachmentOrigin = .external   // 新增：来源标记
    var uploadStatus: UploadStatus = .pending  // 新增：上传状态

    enum UploadStatus { case pending, uploading, uploaded }
}
```

### 2.2 统一组件架构

```
输入区                          消息历史
─────────────────────          ─────────────────────────────
AttachmentEntryChipView        AttachmentPillView
  ├── .project  (mention)        ├── .project  → 可点击跳转 + option+click 预览
  ├── .focused  (contextChip)    ├── .focused  → 可点击打开文件
  ├── .external (fileChip)       └── .external → 可点击打开
  │   ├── image  → thumbnail
  │   └── other  → icon+name
  └── loading state → skeleton

MediaAttachmentGridView（图片/PDF 专属宫格视图，复用 AttachmentPillView 作为单格）
```

---

## 三、Feature 拆分

### Feature CV-FA1: 统一输入区 `AttachmentEntryChipView`

**动机:** `contextChip()`、`fileChip()`、`inputDirectiveChip()` 三个几乎相同的胶囊 chip 独立实现，`FileThumbnailView` 与 `MediaThumbnailCell` 缩略图逻辑重复。

**设计:**

```swift
struct AttachmentEntryChipView: View {
    let file: AttachedFile
    var onRemove: () -> Void
    var onTap: (() -> Void)? = nil

    var body: some View {
        if file.isImage || file.isPDF {
            MediaThumbnailChip(file: file, onRemove: onRemove, onTap: onTap)
        } else {
            FileIconChip(file: file, onRemove: onRemove)
        }
    }
}

// 底层共享 chip 样式
struct _ChipContainer<Content: View>: View {
    let tint: Color
    var isLoading: Bool = false
    @ViewBuilder var content: () -> Content
    var onRemove: (() -> Void)?          // nil → 不显示 × 按钮
    // 统一：ultraThinMaterial 背景、cornerRadius 8、border opacity 0.10、× 按钮样式
}
```

- `contextChip()` 调用 `AttachmentEntryChipView(file:origin:.focused,…)`
- **删除 `fileChip()`、`contextChip()`、`inputDirectiveChip()` 三个独立函数**
- `AttachedFile` 增加 `origin` 字段，聚焦文件创建时标记 `.focused`
- Loading 状态：`UploadStatus.uploading` 时 icon 替换为 `ProgressView()`（对标 Open WebUI `<Spinner/>`）

**修改文件:**
- 新建 `AttachmentEntryChipView.swift`
- `ChatView+InputArea.swift` — 替换 `contextChipsRow`/`fileChipsRow` 为统一 `AttachmentEntryChipView`
- `AttachedFile.swift` — 新增 `origin`、`UploadStatus`

**验收标准:**
- 输入区三种文件引用外观一致（圆角、材质、× 按钮对齐）
- 图片上传中显示骨架/spinner，上传完成后显示缩略图
- 删除 `contextChip()`、`fileChip()`、`inputDirectiveChip()` 三个函数，无回归

---

### Feature CV-FA2: 聚焦文件从文本内联迁移到 `MessageAttachment`

**动机:** 当前聚焦文件被格式化成 `"当前文件: <path>\n选区内容:\n<text>"` 追加到 `textContent`。这使得：
1. 消息历史中无法识别该引用（无法变色、无法点击跳转）
2. `MessageAttachmentWatcher` 无法监控文件状态变化
3. 文件路径与正文内容混杂，影响 API prompt 的语义清晰度

**设计:**

- 发送时，将聚焦文件单独创建 `MessageAttachment(origin: .focused, filePath: …, lineRange: …, selectedText: …)`
- `textContent` 不再包含文件路径/选区信息
- API prompt 构造层（`ClaudeService`）从 `message.attachments.filter{ $0.origin == .focused }` 读取上下文并注入 prompt
- `MessageAttachment` 新增 `selectedText: String?` 字段存储选区文本（仅 `.focused` 使用）
- 向后兼容：旧消息 `textContent` 中的 `"当前文件:"` 前缀通过 fallback 解析层兼容

**修改文件:**
- `MessageAttachment.swift` — 新增 `originRaw: String`、`selectedText: String?`
- `ChatView+Actions.swift` — 发送时将聚焦文件写入 `MessageAttachment` 而非拼接 textContent
- `ClaudeService.swift` / prompt 构造逻辑 — 从 attachment 读取聚焦文件上下文
- `MessageRowSnapshot.swift` — 兼容 fallback 解析旧格式

**验收标准:**
- 新消息发送后，聚焦文件以 `MessageAttachment` 形式存储
- 消息历史中聚焦文件显示为 pill（非纯文本）
- 旧消息正常渲染（兼容层处理 `"当前文件:"` 前缀）

---

### Feature CV-FA3: 统一消息历史 `AttachmentPillView`

**动机:**
- `fileReferenceBadge(count:)` 对外部附件仅显示"引用了 N 个文件"，无法点击，用户无法知道是哪些文件
- `FileReferencePillView`（项目文件）与 `MediaThumbnailCell`（图片）是两套风格
- 需要全部引用在消息气泡底部以统一 pill 排列展示

**设计（借鉴 VS Code `AbstractChatAttachmentWidget` 基类思路）:**

```swift
/// 统一的附件 pill，替代 FileReferencePillView + MediaThumbnailCell + fileReferenceBadge
struct AttachmentPillView: View {
    let entry: AttachmentSnapshotEntry

    var body: some View {
        Group {
            switch entry.fileKind {
            case .image, .pdf:
                MediaThumbnailPill(entry: entry)    // 保留缩略图，但复用 pill 容器
            default:
                FileIconPill(entry: entry)           // 文件图标 + 名称
            }
        }
        .attachmentPillStyle(status: entry.status)  // 统一状态颜色/线条
        .onTapGesture { handleTap() }
        .simultaneousGesture(TapGesture().modifiers(.option).onEnded { showPreview = true })
        .onHover { hovered in
            withAnimation(ChatMotion.hoverSpring) { isHovered = hovered }
        }
    }
}
```

状态颜色规则（对标 VS Code `OmittedState`）：

| 状态 | `.project` | `.focused` | `.external` |
|------|-----------|-----------|------------|
| `.valid` | 蓝色 | 橙色（区分来源） | 灰色 |
| `.modified` | 黄色 + ⚠ badge | — | — |
| `.missing` | 红色删除线 | 红色删除线 | 红色删除线 |

**删除:**
- `fileReferenceBadge(count:)` 及其调用点（`MessageBubbleView.swift L285`）
- `MediaThumbnailCell` 独立实现（合并入 `MediaThumbnailPill`）

**修改文件:**
- 新建 `AttachmentPillView.swift` — 统一 pill 组件
- `MessageBubbleView.swift` — 替换 `fileReferencePillList` 和 `fileReferenceBadge` 为 `AttachmentPillView`
- `MediaViewerView.swift` — 删除 `MediaThumbnailCell`，media grid 改用 `AttachmentPillView`

**验收标准:**
- 所有类型附件在消息气泡底部显示为可点击 pill
- 图片 pill 显示缩略图预览
- 项目文件 pill 保留 Option+Click 代码预览功能
- 外部文件 pill 点击打开系统默认应用

---

### Feature CV-FA4: 外部附件状态追踪扩展

**动机:** `MessageAttachmentWatcher` 当前只监控 `origin == .project` 的文件。外部附件（如截图、PDF）删除后 UI 无感知，用户以为引用仍然有效。

**设计:**

- 扩展 `MessageAttachmentWatcher` 同时监控 `.external` 和 `.focused` 来源附件
- 监控策略与 `.project` 相同：`DispatchSource.makeFileSystemObject` 监听 delete/rename 事件
- 外部文件被删除 → `attachment.statusRaw = AttachmentStatus.missing.rawValue`
- **性能保护**（与 `.project` 共享计数）：单 session 最多监控 200 个文件

**修改文件:**
- `MessageAttachmentWatcher.swift` — 移除 `origin == .project` 的过滤条件

**验收标准:**
- 删除任意类型已引用附件后 2 秒内 pill 显示红色删除线
- Session 切换时 watcher 正确重置

---

### Feature CV-FA5: 冗余代码清理

**动机:** 在 FA1–FA4 交付后，以下代码完全被新组件替代，可以删除。

**待删除清单:**

| 文件 | 目标代码 | 替代者 |
|------|---------|--------|
| `ChatView+InputArea.swift` | `contextChip()` 函数 | `AttachmentEntryChipView(origin: .focused)` |
| `ChatView+InputArea.swift` | `fileChip()` 函数 | `AttachmentEntryChipView(origin: .external)` |
| `ChatView+InputArea.swift` | `inputDirectiveChip()` 函数 | `_ChipContainer` 复用 |
| `MediaViewerView.swift` | `FileThumbnailView` (L174–235) | `AttachmentEntryChipView` 的媒体变体 |
| `MediaViewerView.swift` | `MediaThumbnailCell` (L236–300) | `MediaThumbnailPill` (内嵌于 `AttachmentPillView`) |
| `MessageBubbleView.swift` | `fileReferenceBadge(count:)` | `AttachmentPillView` 列表 |
| `FileReferencePillView.swift` | 整个文件 | `AttachmentPillView` |

**修改文件:**
- 上述所有文件，逐一删除旧实现，确保测试通过

**验收标准:**
- `xcodebuild test` 全量通过
- 无引用到已删除函数/类型
- 代码行数净减少 ≥ 200 行

---

## 四、交互与动效规范

### 4.1 统一交互模型

所有三种类型的附件 pill 遵循以下交互层次：

| 手势 | 行为 | 适用类型 |
|------|------|---------|
| 单击 | 打开文件（`workspaceState.showFileDetail` 或 `NSWorkspace.shared.open`） | 全部 |
| Option+Click | 弹 `FileReferencePreviewPopover`（代码文件显示前 10 行）| `.project`、`.focused` |
| 右键 | 系统菜单（Reveal in Finder / Copy Path）| 全部 |
| Hover | 背景轻微加深，`scaleEffect(1.02)` | 全部 |

### 4.2 统一动效规范（复用 `ChatMotion` Token）

```swift
// 所有 chip/pill 的 hover 动画
.animation(ChatMotion.hoverSpring, value: isHovered)     // spring(response:0.28, dampingFraction:0.76)
.scaleEffect(isHovered ? ChatMotion.hoverScale : 1.0)    // 1.02

// 输入区 chip 入场
.transition(.scale(scale: 0.85).combined(with: .opacity)
    .animation(ChatMotion.enterSpring))                   // spring(response:0.38, dampingFraction:0.82)

// 输入区 chip 退场（× 点击）
.transition(.scale(scale: 0.7).combined(with: .opacity)
    .animation(.easeOut(duration: ChatMotion.exitDuration))) // 0.18s
```

### 4.3 状态颜色 Token

```swift
extension Color {
    static var attachmentProject: Color { .accentColor }        // 蓝色
    static var attachmentFocused: Color { .orange }             // 橙色，区分来源
    static var attachmentExternal: Color { .secondary }         // 灰色
    static var attachmentModified: Color { .yellow }            // 修改
    static var attachmentMissing: Color { .red }                // 缺失
}
```

---

## 五、实施优先级与依赖关系

```
Phase 1 — 数据层 (无 UI 变化)
└── CV-FA2: 聚焦文件持久化    ← 数据模型变更，需迁移

Phase 2 — 组件层 (可并行)
├── CV-FA1: 统一输入区 Chip   ← 依赖 FA2 的 AttachedFile.origin 字段
└── CV-FA3: 统一消息历史 Pill ← 依赖 FA2 的 MessageAttachment.originRaw

Phase 3 — 扩展与清理
├── CV-FA4: 状态追踪扩展      ← 依赖 FA2 + FA3
└── CV-FA5: 冗余代码清理      ← 依赖 FA1 + FA3 全部完成
```

```
依赖图:
CV-FA2 ──→ CV-FA1
CV-FA2 ──→ CV-FA3 ──→ CV-FA4
CV-FA1 + CV-FA3 ──→ CV-FA5
```

---

## 六、不做的事项 (YAGNI)

| 提议 | 理由 |
|------|------|
| 将 `ArtifactShelfView` 统一进来 | ArtifactShelf 是 Agent 响应的输出侧，语义不同于输入侧的用户附件；统一会引入不必要耦合 |
| 上传进度条（百分比） | macOS 本地文件拖入是即时的，无上传延迟，Spinner 已足够 |
| 附件排序/拖拽重排 | 对话语义不依赖附件顺序 |
| 文件内容快照（发送时保存副本） | 存储开销大；已有 checkpoint 机制 |
| Multi-select 批量删除 | 使用场景极少，增加交互复杂度 |

---

## 七、竞品模式索引

| 模式 | VS Code Copilot | Open WebUI | 本文 Feature |
|------|----------------|------------|-------------|
| 统一类型联合 | `IChatRequestVariableEntry` union + `kind` | `type` prop | CV-FA2 |
| 工厂模式 | `IChatAttachmentWidgetRegistry` | 单组件 props | CV-FA1/FA3 |
| 隐式引用（聚焦文件）统一 | `kind: 'implicit'` 走同一渲染路径 | 图片单独列外 | CV-FA2 |
| 状态追踪 | `OmittedState` 枚举 | `status: uploading/uploaded/processed` | CV-FA3/FA4 |
| 基类共享逻辑 | `AbstractChatAttachmentWidget` | `_ChipContainer` pattern | CV-FA1/FA3 |
| Loading 状态统一 | — | `loading={file.status === 'uploading'}` → `<Spinner/>` | CV-FA1 |
