# ChatView 性能与功能迭代设计文档

> **调研来源:** Open WebUI (Svelte)、VS Code GitHub Copilot Chat (TypeScript)、当前 agentGui 实现 (SwiftUI)
>
> **目标:** 将 ChatView 的性能瓶颈、文件引用交互、UI 动效三个维度拆分为可独立交付的小 Feature，逐步迭代至生产级水准。

---

## 一、现状分析

### 1.1 当前架构概览

```
Message (SwiftData @Model)
    ↓ @Query
ChatView.task(id: refreshKey)
    ↓
ChatMessageListProjectionModel.refresh()
    ↓ Actor off-main-thread
ChatMessageListSnapshotBuilder.build()  ← 语义指纹缓存
    ↓
ChatMessageListSnapshot (immutable rows)
    ↓ @Observable
SwiftUI List → MessageBubbleView → MarkdownMessageView / AgentMessageStepFlowView
```

**优势:**
- 语义指纹增量重建，1000+ 消息仅重建尾部行
- Actor 隔离，不阻塞主线程
- Generation 追踪，丢弃过期投影

**待改进:**
- 无虚拟化/分页，所有消息一次性全量渲染到 List
- 文件引用以纯文本内嵌 `textContent`，无结构化模型
- 文件引用无实时同步、无存在性校验
- 动效零散，缺乏一致的 motion system
- 流式消息滚动策略过于简单

### 1.2 竞品亮点

#### Open WebUI
| 模式 | 做法 |
|------|------|
| 分页加载 | 每次 20 条，滚动到顶部触发 Load More |
| 流式节流 | `requestAnimationFrame` 批量更新，结构变更立即重建 |
| 文件引用 | 结构化 `{type, id, name, status, url, content_type}` + 拖放/粘贴/HEIC 转换 |
| 上传状态 | `uploading → uploaded → processed` 三态流转 |
| 滚动锚定 | `scrollHeight - scrollTop <= clientHeight + 50px` 检测底部 |

#### VS Code Copilot Chat
| 模式 | 做法 |
|------|------|
| 虚拟列表 | `CachedListVirtualDelegate` + `ITreeRenderer`，DOM 节点复用 |
| 内容 Diff | `diff()` 比较已渲染 parts 与新内容，仅替换变化部分 |
| 渐进渲染 | 按词速率 (words/s) 逐块渲染 Markdown，50ms 定时器驱动 |
| 文件引用 | `ChatAttachmentModel` 结构化管理，文件变更 watcher 自动移除 |
| 内容分部件 | references / markdownContent / toolInvocation / thinking / codeBlock 各自独立 ContentPart |
| 高度缓存 | `CachedListVirtualDelegate` + `ResizeObserver` 动态高度 |
| Group Hover | request/response 联动 hover 状态 |

### 1.3 差距总结

| 维度 | 当前状态 | 目标 |
|------|----------|------|
| **渲染性能** | 全量 List，≤500 条可接受 | 分页 + 惰性渲染，1000+ 流畅 |
| **流式体验** | 整块刷新 | 渐进渲染 + 节流 + 打字机效果 |
| **文件引用** | 纯文本嵌入 | 结构化模型 + 富交互 UI |
| **动效系统** | 零散硬编码 | 统一 Motion Token + 一致过渡 |
| **滚动策略** | 简单 scrollTo | 智能锚定 + 用户意图检测 |

---

## 二、Feature 拆分

### Feature CV-P1: 消息分页懒加载

**动机:** 长会话（500+ 条）全量渲染导致首次渲染延迟和内存占用过高。

**设计:**
- 在 `ChatMessageListProjectionModel` 引入 `pageSize = 40`，默认仅投影最新 N 条
- 滚动到顶部时触发 `loadMoreMessages()`，前置追加更早的消息行
- 投影缓存跨分页保留，已构建的 snapshot 无需重建
- 新增 `ChatMessageListPaginationState`：`.initial` / `.loadingMore` / `.fullyLoaded`
- 顶部显示轻量 ProgressView 指示加载中

**修改文件:**
- `ChatMessageListProjectionModel.swift` — 分页状态 + loadMore 方法
- `ChatMessageListSnapshotBuilder.swift` — 接受 range 参数
- `ChatView+MessageList.swift` — 滚动到顶部检测 + 加载指示器

**验收标准:**
- 1000 条消息首屏渲染 < 100ms
- 向上滚动无感加载，无跳动

---

### Feature CV-P2: 流式渲染节流与渐进输出

**动机:** Agent 流式响应时频繁触发完整 Projection 重建，造成 UI 卡顿。

**设计（借鉴 Open WebUI + VS Code):**
- 新增 `StreamingThrottlePolicy`：
  - **结构性变更**（新消息 / 新 round / toolCall 状态变更）→ 立即刷新
  - **内容追加**（streaming text delta）→ 合并到下一个 `CADisplayLink` 帧
- Agent 消息的 `MessageRowSnapshot` 增加 `renderedWordCount` 追踪
- 渐进渲染：每帧按速率渲染 N 个词（默认 80 words/s），直到追上流
- 流式完成后执行一次完整 snapshot 重建确保最终一致性

**修改文件:**
- 新建 `ChatStreamingThrottlePolicy.swift`
- `ChatMessageListProjectionModel.swift` — 区分 structural / content 变更
- `AgentMessageStepFlowView.swift` — 接入渐进渲染 word count

**验收标准:**
- 流式输出期间主线程帧率 ≥ 55fps
- 打字机效果自然流畅

---

### Feature CV-P3: 智能滚动锚定

**动机:** 用户回溯阅读时新消息强制跳转底部，破坏阅读连续性。

**设计:**
- 重构 `ChatMessageListAutoScrollPolicy`：
  - **底部检测:** 视口底部距离 ≤ 60pt 时视为 "在底部"
  - **用户回溯检测:** 用户主动上滑超过 1 屏高度 → 锁定滚动位置
  - **新消息指示器:** 回溯状态下，右下角浮现 "↓ N 条新消息" badge
  - **点击 badge:** `.easeOut(0.25)` 滚动到底部并解除锁定
- **流式追尾:** 在底部状态下，streaming 追加保持自动滚动

**修改文件:**
- `ChatMessageListAutoScrollPolicy.swift` — 完整重写
- `ChatView+MessageList.swift` — 新消息 badge overlay
- 新建 `NewMessagesBadgeView.swift`

**验收标准:**
- 回溯 5+ 屏后接收新消息不跳动
- badge 显示新消息数量，点击回底部

---

### Feature CV-F1: 结构化文件引用模型

**动机:** 文件引用作为纯文本嵌入 `Message.textContent` 无法支持富交互，且无法追踪文件状态。

**设计（借鉴 VS Code ChatAttachmentModel）:**
- 新增 `MessageAttachment` SwiftData @Model：
  ```swift
  @Model final class MessageAttachment {
      var id: UUID
      var filePath: String
      var fileType: FileType  // .swift, .image, .pdf, .directory, .other
      var displayName: String
      var lineRange: ClosedRange<Int>?  // 可选行范围引用
      var status: AttachmentStatus  // .valid, .missing, .modified
      var message: Message?
  }
  
  enum AttachmentStatus: String, Codable {
      case valid, missing, modified
  }
  ```
- `Message` 新增 `attachments: [MessageAttachment]` relationship
- 发送时将 `attachedFiles` 写入 `MessageAttachment`（不再拼接到 textContent）
- 快照构建时从 relationship 读取而非文本解析

**修改文件:**
- 新建 `MessageAttachment.swift`
- `Message.swift` — 新增 relationship
- `ChatView+Actions.swift` — 发送时创建 attachment 记录
- `MessageRowSnapshot.swift` — 从结构化数据构建 attachment snapshot
- 迁移：旧消息文本解析兼容层

**验收标准:**
- 新消息使用结构化 attachment 存储
- 旧消息通过解析层向前兼容

---

### Feature CV-F2: 文件引用富交互 UI

**动机:** 当前文件引用仅显示路径列表和 badge 计数，缺乏可操作性。

**设计（借鉴 Open WebUI 缩略图 + VS Code 引用展开）:**
- **Inline 文件标签:** 类似 VS Code 的 pill 样式，显示文件图标 + 文件名 + 可选行号
  ```
  [📄 ClaudeService.swift:42-68] [📄 Message.swift] [🖼️ screenshot.png]
  ```
- **Hover 预览:** 鼠标悬停展示前 10 行代码预览 popover（使用 CodeEditorViewModel 渲染）
- **Click 交互:**
  - 单击：在 workspace 代码编辑器中打开文件并跳转到行
  - Option+Click：在独立窗口打开预览
- **状态标记:**
  - ✅ 文件存在 → 正常颜色
  - ⚠️ 文件已修改（对比发送时）→ 黄色标记
  - ❌ 文件已删除 → 红色删除线 + tooltip "文件已不存在"
- **图片引用:** LazyVGrid 缩略图不变，但增加 status overlay

**修改文件:**
- 新建 `FileReferencePillView.swift` — pill 标签组件
- 新建 `FileReferencePreviewPopover.swift` — hover 预览
- `MessageBubbleView.swift` — 替换 `fileReferenceBadge()` 为 pill 列表
- `MessageRowSnapshot.swift` — 增加 attachment status 计算

**验收标准:**
- 文件引用可 hover 预览、可点击跳转
- 已删除文件有明确视觉提示

---

### Feature CV-F3: 文件存在性实时监控

**动机:** 文件引用在发送后可能被删除或移动，用户无法感知。

**设计（借鉴 VS Code FileWatcher 模式）:**
- 新建 `MessageAttachmentWatcher` actor：
  - 对当前活跃 session 中所有 `MessageAttachment` 注册 `DispatchSource.makeFileSystemObject`
  - 文件删除/重命名事件 → 更新 `MessageAttachment.status`
  - 文件内容变更 → 标记 `.modified`
- **作用域控制:** 仅监控当前 session 的附件，切换 session 时重置 watcher
- **性能保护:** 单 session 最多监控 200 文件，超过阈值后仅检查最近 50 条消息的附件

**修改文件:**
- 新建 `MessageAttachmentWatcher.swift`
- `ChatView.swift` — session 切换时启停 watcher
- `MessageAttachment.swift` — status 变更 → SwiftData 持久化

**验收标准:**
- 删除已引用文件后 2 秒内 UI 更新状态
- session 切换时 watcher 正确释放

---

### Feature CV-A1: 统一 Motion Token 系统

**动机:** 当前动效参数（spring dampingFraction、duration、easeInOut）硬编码在多处，风格不一致。

**设计:**
- 新建 `ChatMotionTokens.swift`：
  ```swift
  enum ChatMotion {
      // 入场
      static let enterSpring = Animation.spring(response: 0.38, dampingFraction: 0.82)
      static let enterDuration: TimeInterval = 0.25
      
      // 退场
      static let exitDuration: TimeInterval = 0.18
      static let exitOpacity = AnyTransition.opacity
      
      // 流式内容
      static let streamingAppend = Animation.easeOut(duration: 0.12)
      
      // 滚动
      static let scrollToBottom = Animation.easeOut(duration: 0.22)
      
      // 交互反馈
      static let hoverScale: CGFloat = 1.02
      static let pressScale: CGFloat = 0.97
      static let hoverSpring = Animation.spring(response: 0.28, dampingFraction: 0.76)
  }
  ```
- 所有现有硬编码动效参数迁移到 Token

**修改文件:**
- 新建 `ChatMotionTokens.swift`
- `MessageBubbleView.swift` — 替换硬编码
- `AgentMessageStepFlowView.swift` — 替换硬编码
- `ChatView+MessageList.swift` — 替换硬编码
- `ChatView.swift` — 替换硬编码

**验收标准:**
- 所有 ChatView 相关动效参数引用 `ChatMotion.*`
- 视觉一致性：入场/退场/交互反馈风格统一

---

### Feature CV-A2: 消息入场/退场动效重构

**动机:** 新消息出现无明显入场动画，删除消息无退场效果。

**设计:**
- **用户消息入场:**
  ```swift
  .transition(.asymmetric(
      insertion: .move(edge: .trailing)
          .combined(with: .opacity)
          .animation(ChatMotion.enterSpring),
      removal: .scale(scale: 0.95, anchor: .trailing)
          .combined(with: .opacity)
          .animation(.easeOut(duration: ChatMotion.exitDuration))
  ))
  ```
- **Agent 消息入场:**
  ```swift
  .transition(.asymmetric(
      insertion: .move(edge: .leading)
          .combined(with: .opacity)
          .animation(ChatMotion.enterSpring),
      removal: .opacity
          .animation(.easeOut(duration: ChatMotion.exitDuration))
  ))
  ```
- **Thinking/ToolCall 展开:**
  - 保留现有 execution theater transition 但迁移到 Motion Token
  - 新增 shimmer 加载骨架屏效果（借鉴 Open WebUI skeleton loading）
- **Hover Actions Bar:** 统一使用 `ChatMotion.hoverSpring` + opacity

**修改文件:**
- `MessageBubbleView.swift` — 入场/退场 transition
- `AgentMessageStepFlowView.swift` — 迁移到 Motion Token
- `ToolCallBubbleView.swift` — 迁移到 Motion Token
- 新建 `SkeletonShimmerView.swift` — 骨架屏加载效果

**验收标准:**
- 新消息入场有方向性滑入效果
- 删除消息有收缩淡出效果
- Agent 响应等待时显示 shimmer

---

### Feature CV-A3: Group Hover 联动

**动机:** VS Code 实现了 request/response 联动 hover，鼠标在请求上时响应也突出显示。

**设计:**
- Request 和 Response 通过 `requestId` 配对
- 鼠标进入 request 行 → response 行添加 `.group-hovered` 高亮背景
- 鼠标进入 response 行 → request 行添加 `.group-hovered` 高亮背景
- 使用 `@State private var hoveredGroupId: UUID?` 在列表层管理

**修改文件:**
- `ChatView+MessageList.swift` — hovered group state
- `MessageBubbleView.swift` — 接收 `isGroupHovered` binding + 背景高亮

**验收标准:**
- hover 请求时对应响应轻微高亮
- 过渡自然，无闪烁

---

### Feature CV-A4: 流式内容打字机效果

**动机:** 当前 streaming 内容一块块出现缺乏连续感。

**设计:**
- 在 `AgentMessageStepFlowView` 的 answer block 区域：
  - 新内容追加时使用 `ChatMotion.streamingAppend` 动画
  - 末尾闪烁光标指示器（streaming 期间可见）
  - 内容完成后光标消失动画
- 新建 `StreamingCursorView`: 竖线闪烁 0.5s 周期

**修改文件:**
- 新建 `StreamingCursorView.swift`
- `AgentMessageStepFlowView.swift` — answer block 末尾附加 cursor
- `MarkdownMessageView.swift` — streaming 状态下的增量渲染动画

**验收标准:**
- streaming 期间末尾有闪烁光标
- 新文本出现有轻微淡入效果

---

## 三、实施优先级与依赖关系

```
Phase 1 — 基础设施 (无 UI 变化)
├── CV-F1: 结构化文件引用模型         ← 数据层，其他 CV-F* 依赖
├── CV-A1: 统一 Motion Token 系统     ← 其他 CV-A* 依赖
└── CV-P2: 流式渲染节流              ← 独立，可并行

Phase 2 — 核心体验
├── CV-P1: 消息分页懒加载            ← 需要 snapshot builder 改造
├── CV-P3: 智能滚动锚定              ← 依赖 CV-P1 分页
├── CV-F2: 文件引用富交互 UI          ← 依赖 CV-F1
└── CV-A2: 消息入场/退场动效          ← 依赖 CV-A1

Phase 3 — 增强体验
├── CV-F3: 文件存在性实时监控          ← 依赖 CV-F1
├── CV-A3: Group Hover 联动           ← 独立
└── CV-A4: 流式内容打字机效果          ← 依赖 CV-P2 + CV-A1
```

```
依赖图:
CV-F1 ──→ CV-F2 ──→ CV-F3
CV-A1 ──→ CV-A2
CV-A1 ──→ CV-A4
CV-P2 ──→ CV-A4
CV-P1 ──→ CV-P3
```

---

## 四、不做的事项 (YAGNI)

| 提议 | 理由 |
|------|------|
| DOM 虚拟化 (NSTableView 级) | macOS SwiftUI List 已有懒加载，分页足以覆盖 |
| 文件内容快照 (发送时保存文件副本) | 存储开销大，已有 git / checkpoint 机制 |
| 拖拽重排消息 | 对话时序不应被打乱 |
| 消息分支/树状对话 | 复杂度极高，当前线性模型足够 |
| 实时协作编辑引用文件 | 超出 chat client 职责 |

---

## 五、竞品设计模式参考索引

| 模式 | Open WebUI | VS Code Copilot | 本文 Feature |
|------|-----------|----------------|-------------|
| 分页加载 | 20 条增量 | 虚拟列表 | CV-P1 |
| 流式节流 | requestAnimationFrame | 50ms timer + word rate | CV-P2 |
| 滚动锚定 | 50px 阈值 | scrollToEnd + Lock | CV-P3 |
| 文件模型 | `{type,id,status,url}` | `ChatAttachmentModel` + FileWatcher | CV-F1 + CV-F3 |
| 文件 UI | 缩略图 + remove btn | pill + context references | CV-F2 |
| Motion | CSS transition | class toggle | CV-A1 |
| 内容 Diff | — | `diff()` + 部件替换 | CV-P2 (增量) |
| Group Hover | CSS `group-hover` | JS mouseenter/leave | CV-A3 |
| 打字机 | — | word rate progressive | CV-A4 |
