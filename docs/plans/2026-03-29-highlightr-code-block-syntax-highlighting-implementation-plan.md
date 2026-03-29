# Highlightr Code Block Syntax Highlighting Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 agentGui 中引入 Highlightr，让 BlockDocumentEditor 和 MarkdownMessageView 的代码块具备稳定、可回退、与当前 macOS UI 风格一致的语法高亮能力。

**Architecture:** 通过一个项目内的代码高亮适配层封装 Highlightr，而不是把第三方库直接散落到多个 SwiftUI/AppKit 视图里。MarkdownMessageView 走“缓存后的 NSAttributedString + 可选中文本视图”只读渲染路径；BlockDocumentEditor 则拆成“未编辑时显示高亮结果，编辑时继续使用现有 BlockTextEditor/NSTextView，只是在 code/source 模式下注入 Highlightr 样式”的双路径实现，以降低对现有焦点、slash 命令、选区和高度计算逻辑的扰动。

**Tech Stack:** Swift 6、SwiftUI、AppKit、JavaScriptCore、Highlightr、Foundation、Swift Testing、现有 BlockTextEditor / BlockInlineMarkdownStyler / MarkdownMessageView。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. 调研结论与方案选择

### 0.1 Highlightr 调研结论

- Highlightr 当前支持 SPM，Package.swift 声明了 macOS target，可直接作为 Xcode Swift Package 引入。
- README 明确给出两条主 API：`Highlightr.highlight(_:as:fastRender:)` 用于把代码字符串转成 `NSAttributedString`，`CodeAttributedString` 用于实时编辑场景。
- 源码确认 `highlight(_:as:)` 在显式语言无效时会退回 `highlightAuto`，传 `nil` 时也会直接走自动语言检测。
- 主题和高亮依赖内置的 highlight.js 与 CSS 资源，SPM 已把这些资源打进 package，无需手动拷贝静态文件。
- README 顶部已经标明该库在 2026 年起不再活跃维护，因此接入时必须隔离在项目自己的抽象层后面，不能让视图层直接依赖第三方 API。

### 0.2 现有代码现状

- Markdown 消息代码块当前在 [agentGui/Views/MarkdownMessageView.swift](agentGui/Views/MarkdownMessageView.swift#L87) 进入 `CodeBlockView`，内部仍是普通 `Text`，只有等宽字体，没有语法高亮。
- BlockDocumentEditor 的激活编辑态使用 [agentGui/Views/Editor/BlockTextEditor.swift](agentGui/Views/Editor/BlockTextEditor.swift) 包装 `NSTextView`，样式入口在 [agentGui/Views/Editor/BlockInlineMarkdownStyler.swift](agentGui/Views/Editor/BlockInlineMarkdownStyler.swift#L27)。当前对 `.code` / `.source` 只做基础等宽字体，不做词法高亮。
- BlockDocumentEditor 的未激活只读态在 [agentGui/Views/Editor/BlockRowView.swift](agentGui/Views/Editor/BlockRowView.swift#L678) 仍是普通 `Text`。引用块里的内嵌代码渲染也在 [agentGui/Views/Editor/BlockRowView.swift](agentGui/Views/Editor/BlockRowView.swift#L972) 使用普通 `Text`。
- 代码语言来源已经存在：Markdown fence 解析把语言写进 `block.metadata.language`，源码文件还会通过 `languageHint(for:)` 用文件扩展名填充语言提示，见 [agentGui/Views/Editor/BlockMarkdownCodec.swift](agentGui/Views/Editor/BlockMarkdownCodec.swift#L245) 与 [agentGui/Views/Editor/BlockMarkdownCodec.swift](agentGui/Views/Editor/BlockMarkdownCodec.swift#L292)。

### 0.3 方案对比

**推荐方案：保留现有编辑器树，新增项目内高亮服务，并在不同消费端分别适配。**

- 优点：不需要重建 BlockTextEditor 的 `NSTextView` 生命周期，不会顺手打破 slash command、focus token、选择同步、drag/drop、高度计算这些当前已经稳定的编辑器行为。
- 优点：可以把“库已停止活跃维护”的风险收口在一处，未来若切换到 HighlighterSwift，只需要替换服务实现。
- 代价：要维护一层语言归一化、主题映射、缓存和 fallback 逻辑。

**备选方案 A：编辑器侧直接改用 CodeAttributedString。**

- 优点：更贴近 Highlightr 文档里推荐的实时高亮路径。
- 缺点：当前 BlockTextEditor 深度定制了 `NSTextView` 行为，替换 text storage / layoutManager 树会同时影响 markdown 隐藏标记、焦点恢复、命令拦截和高度计算，改动面过大，不适合作为首轮集成。

**备选方案 B：消息和编辑器都改成 HTML/WebView 渲染。**

- 缺点：会破坏原生文本选择、字体和系统滚动行为，也与当前 AppKit/SwiftUI 结构不一致，直接排除。

## 1. 实施约束

- 严格 TDD。先锁定语言归一化、fallback、缓存和高亮属性写入行为，再做视图接入。
- 不把 Highlightr API 直接散落到 SwiftUI 视图里；所有第三方调用必须经过单一适配层。
- 首轮范围只覆盖块级代码块：`DocumentBlockKind.code`、`DocumentBlockKind.source`，以及 MarkdownMessageView 解析出来的 `.code` block；不扩展到行内 code span。
- Mermaid 仍走现有 `MermaidBlockView` 分支，不与 Highlightr 混用。
- 对于语言值为空、`text`、`plain`、`plaintext` 或 Highlightr 不支持的语言，必须稳定退回普通等宽渲染，不能产生空白内容或闪退。
- 只做代码块高亮，不顺手改整个 BlockDocumentEditor 的挂载策略，也不处理非代码块只读文本选择模型。
- 由于仓库测试 scheme 仍可能构建 UITest target，实施时优先使用 focused `xcodebuild test`，若遇到本地签名噪音，用 `build-for-testing CODE_SIGNING_ALLOWED=NO` 做编译健康验证。

## 2. 代码锚点

本计划围绕以下现有实现展开：

- [agentGui/Views/MarkdownMessageView.swift](agentGui/Views/MarkdownMessageView.swift)
- [agentGui/Views/Editor/BlockRowView.swift](agentGui/Views/Editor/BlockRowView.swift)
- [agentGui/Views/Editor/BlockTextEditor.swift](agentGui/Views/Editor/BlockTextEditor.swift)
- [agentGui/Views/Editor/BlockInlineMarkdownStyler.swift](agentGui/Views/Editor/BlockInlineMarkdownStyler.swift)
- [agentGui/Views/Editor/BlockMarkdownCodec.swift](agentGui/Views/Editor/BlockMarkdownCodec.swift)
- [agentGui/Views/Editor/BlockEditorModels.swift](agentGui/Views/Editor/BlockEditorModels.swift)
- [agentGui.xcodeproj/project.pbxproj](agentGui.xcodeproj/project.pbxproj)

## 3. 目标文件集

### New files

- /Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift
- /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SyntaxHighlightedCodeTextView.swift
- /Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeSyntaxHighlightingServiceTests.swift
- /Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockInlineMarkdownStylerCodeHighlightTests.swift

### Modified files

- /Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj
- /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MarkdownMessageView.swift
- /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockRowView.swift
- /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift
- /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockInlineMarkdownStyler.swift

## 4. 任务拆解

### Task 1: 引入 Highlightr 并建立项目内高亮适配层

**Files:**
- Create: /Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift
- Create: /Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeSyntaxHighlightingServiceTests.swift
- Modify: /Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj

**Step 1: Write the failing test**

先写纯单元测试，不直接绑死第三方库，用协议或闭包注入假引擎，锁住以下行为：

- 语言归一化：`""`、`"text"`、`"plain"`、`"plaintext"` 会归一为 `nil` 或 plain fallback，而不是把这些值硬塞给高亮引擎。
- 明确语言不受支持时，服务会退回 plain monospace attributed string。
- 相同的 `code + normalizedLanguage + themeRole + fontSize` 请求命中缓存，不重复调用引擎。
- Highlightr 初始化失败或返回 `nil` 时，服务仍返回非空 attributed string。

示例：

```swift
@Test
func normalizesPlaintextLanguagesToFallback() {
    let engine = RecordingHighlightEngine()
    let service = CodeSyntaxHighlightingService(engine: engine)

    _ = service.highlightedString(
        code: "let value = 1",
        language: "plaintext",
        appearance: .light,
        fontSize: 12
    )

    #expect(engine.recordedLanguages == [nil])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeSyntaxHighlightingServiceTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为高亮服务和抽象层尚不存在。

**Step 3: Write minimal implementation**

实现最小可用高亮服务：

- 在新目录 `Services/SyntaxHighlighting/` 下定义项目内协议，例如：

```swift
protocol CodeSyntaxHighlighting {
    func highlightedString(code: String, language: String?, appearance: CodeHighlightAppearance, fontSize: CGFloat) -> NSAttributedString
}
```

- 用 `Highlightr` 作为默认 live engine，但隐藏在服务内部；不要让视图直接 import Highlightr。
- 做语言归一化：空字符串、`text`、`plain`、`plaintext`、`txt` 一律按“让引擎自动检测或 plain fallback”处理。
- 做主题角色映射：定义 `CodeHighlightAppearance.light` / `.dark`，不要在视图层散落主题名字。
- 做 cache key：`code + language + appearance + fontSize`。
- fallback 返回带基础等宽字体和主文本颜色的 `NSAttributedString`，保证任何失败分支都能显示原文。
- 在 Xcode project 中加入 `https://github.com/raspu/Highlightr/` 的 SPM dependency，并链接 app target。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui.xcodeproj/project.pbxproj agentGui/Services/SyntaxHighlighting/CodeSyntaxHighlightingService.swift agentGuiTests/CodeSyntaxHighlightingServiceTests.swift
git commit -m "feat: add highlightr-backed code highlighting service"
```

### Task 2: 为 MarkdownMessageView 添加可选择的高亮代码块渲染

**Files:**
- Create: /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SyntaxHighlightedCodeTextView.swift
- Modify: /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MarkdownMessageView.swift
- Test: /Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeSyntaxHighlightingServiceTests.swift

**Step 1: Write the failing test**

先补服务层测试，锁住消息渲染真正依赖的输出约束：

- Swift 代码高亮结果里，关键字与普通标识符具有不同前景色属性。
- 高亮结果保留原始文本内容，不会吞字符或改换行。
- 深色和浅色 appearance 返回不同的 theme 结果。

示例：

```swift
@Test
func highlightedStringPreservesSourceTextAndAppliesColoredTokens() {
    let service = CodeSyntaxHighlightingService.liveForTesting()
    let result = service.highlightedString(
        code: "let value = 1",
        language: "swift",
        appearance: .light,
        fontSize: 12
    )

    #expect(result.string == "let value = 1")
    #expect(result.hasDistinctForegroundColors(in: ["let", "value"]))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeSyntaxHighlightingServiceTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为还没有真实 Highlightr live path、theme mapping 与 attributed output 断言辅助。

**Step 3: Write minimal implementation**

实现要点：

- 新建 `SyntaxHighlightedCodeTextView.swift`，封装一个 `NSViewRepresentable`，内部使用只读 `NSTextView` 展示 `NSAttributedString`，保留消息代码块当前已有的横向滚动和文本选择能力。
- 让 `MarkdownMessageView.CodeBlockView` 从现有纯 `Text` 切到这个新视图。
- 继续保留 `mermaid` 分支，不进入 Highlightr。
- 语言标签仍来自 `block.language`；显示文案可以保留现有 header，但高亮服务应该接收归一化后的语言值。
- 视图容器继续使用现有 material/background/stroke 外观，不直接采用 Highlightr 的 theme background，避免和现有消息气泡视觉冲突。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS，然后做一次 focused 编译验证：

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-highlightr-markdown-derived \
  CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED。

**Step 5: Commit**

```bash
git add agentGui/Views/SyntaxHighlightedCodeTextView.swift agentGui/Views/MarkdownMessageView.swift agentGuiTests/CodeSyntaxHighlightingServiceTests.swift
git commit -m "feat: syntax highlight markdown message code blocks"
```

### Task 3: 给 BlockDocumentEditor 的激活编辑态注入实时高亮

**Files:**
- Create: /Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BlockInlineMarkdownStylerCodeHighlightTests.swift
- Modify: /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockTextEditor.swift
- Modify: /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockInlineMarkdownStyler.swift
- Modify: /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockRowView.swift

**Step 1: Write the failing test**

锁住编辑器路径的关键行为：

- 当 `kind == .code` 或 `.source` 时，styler 会把 Highlightr 输出的属性写入 `textStorage`。
- `language == "text"` 或 `"plain"` 时不会强行套语义色，但仍保留等宽字体和基础颜色。
- 高亮应用后 `typingAttributes` 仍保持基础等宽输入属性，不会把光标后续输入卡死在错误 token 样式里。
- 非 code/source block 继续保留当前 markdown inline 规则，不产生回归。

示例：

```swift
@MainActor
@Test
func codeBlocksApplyHighlightAttributesWithoutChangingPlainTypingAttributes() {
    let textView = BlockEditorTextView()
    textView.string = "let value = 1"

    BlockInlineMarkdownStyler.apply(
        to: textView,
        kind: .code,
        language: "swift",
        highlighter: .testingHighlightedKeyword
    )

    let keywordColor = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(keywordColor != NSColor.labelColor)
    #expect((textView.typingAttributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/BlockInlineMarkdownStylerCodeHighlightTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `BlockInlineMarkdownStyler` 目前没有 language/highlighter 注入点。

**Step 3: Write minimal implementation**

实现要点：

- 给 `BlockTextEditor` 增加 `language: String?` 参数，并从 `BlockRowView` 把 `block.metadata.language` 传进去。
- 给 `BlockInlineMarkdownStyler.apply(...)` 增加 `language:` 和可注入 highlighter 入口。
- 在 `.code` / `.source` 分支中，先设置基础字体与段落样式，再用高亮服务生成 attributed string，把 token 级 attributes 覆盖回 `textStorage`。
- 最后重置 `textView.typingAttributes` 到基础等宽属性，确保继续输入时不是“继承最后一个 token 颜色”。
- 非 `.code` / `.source` 的 markdown rule 分支保持原逻辑，避免顺手改动正文、列表、heading 的富文本表现。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockTextEditor.swift agentGui/Views/Editor/BlockInlineMarkdownStyler.swift agentGui/Views/Editor/BlockRowView.swift agentGuiTests/BlockInlineMarkdownStylerCodeHighlightTests.swift
git commit -m "feat: apply syntax highlighting in block code editors"
```

### Task 4: 给 BlockDocumentEditor 的未激活代码块补只读高亮

**Files:**
- Modify: /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockRowView.swift
- Test: /Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeSyntaxHighlightingServiceTests.swift

**Step 1: Write the failing test**

补服务层和纯渲染辅助测试，锁住只读路径所需行为：

- 同一段代码在只读渲染时能转换成 SwiftUI 可消费的 attributed 内容。
- fallback 分支仍保留原始文本与等宽字体。
- 引用块内嵌代码也走同一份高亮 helper，而不是继续手写普通 `Text`。

示例：

```swift
@Test
func quotedCodeUsesSameHighlightPipelineAsRegularCodeBlock() {
    let service = CodeSyntaxHighlightingService.liveForTesting()
    let regular = service.highlightedString(code: "print(1)", language: "swift", appearance: .light, fontSize: 12)
    let quoted = service.highlightedString(code: "print(1)", language: "swift", appearance: .light, fontSize: 12)

    #expect(regular.string == quoted.string)
    #expect(regular.length == quoted.length)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeSyntaxHighlightingServiceTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 BlockRowView 的只读 code/source 与 quote-inline-code 还未接入统一 helper。

**Step 3: Write minimal implementation**

实现要点：

- 在 `BlockReadOnlyTextContent` 的 `.code` / `.source` 分支中，用高亮服务生成 attributed output，再转成 SwiftUI `Text` 或小型只读专用 view；保持现有背景、圆角和 block 激活命中区。
- `QuoteInlineBlockView.inlineCode` 复用同一个 helper，避免出现“主代码块有高亮，引用里的代码块没有高亮”的不一致。
- 不在本轮把只读 code block 改造成可选中 `NSTextView`，保留当前点击进入编辑器的交互语义，只补足视觉高亮。

**Step 4: Run test to verify it passes**

运行同一命令并预期 PASS，然后执行 focused 编译检查：

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-highlightr-editor-derived \
  CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED。

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockRowView.swift agentGuiTests/CodeSyntaxHighlightingServiceTests.swift
git commit -m "feat: syntax highlight readonly block code views"
```

### Task 5: 收口主题选择、回归验证与文档记录

**Files:**
- Modify: /Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-29-highlightr-code-block-syntax-highlighting-implementation-plan.md
- Optional Modify: /Volumes/T7/文稿/Projects/agentGui/README.md

**Step 1: Write the failing verification checklist**

在当前计划文档末尾补一段明确的验收 checklist，覆盖：

- MarkdownMessageView 中 Swift / JSON / Bash fenced code block 有高亮。
- Mermaid block 仍渲染 Mermaid，不被 Highlightr 抢走。
- BlockDocumentEditor 在 `.code` 和 `.source` block 的激活态与非激活态都有高亮。
- 无语言的 fenced block、未知语言、空代码块都能正常显示。
- 深浅色外观切换后高亮主题也切换，不出现浅底浅字或深底深字。

**Step 2: Run verification commands**

建议执行：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/CodeSyntaxHighlightingServiceTests \
  -only-testing:agentGuiTests/BlockInlineMarkdownStylerCodeHighlightTests \
  CODE_SIGNING_ALLOWED=NO
```

若本地环境对 scheme 的 UITest target 仍有签名噪音，再执行：

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-highlightr-closeout-derived \
  CODE_SIGNING_ALLOWED=NO
```

**Step 3: Manual smoke pass**

手工验证以下场景：

- 打开一个非 Markdown 源文件，确认 `.source` block 根据扩展名语言提示高亮。
- 在 BlockDocumentEditor 中新建 ```swift 代码块，输入 `let value = 1`，确认输入过程中 token 颜色实时更新、光标与高度计算正常。
- 在聊天消息里贴入带三反引号的代码块，确认消息代码块可横向滚动、可选择、复制按钮仍可用。

**Step 4: Commit**

```bash
git add README.md docs/plans/2026-03-29-highlightr-code-block-syntax-highlighting-implementation-plan.md
git commit -m "docs: record highlightr syntax highlighting rollout"
```

## 5. 实现细节建议

### 5.1 语言归一化规则

- `nil`、空字符串、`text`、`plain`、`plaintext`、`txt`：传给引擎 `nil`，优先让 Highlightr 自动检测；若结果无明显 token 属性，再回退 plain monospace。
- `mermaid`：完全跳过 Highlightr。
- `.source` block：优先使用 `BlockMarkdownCodec.languageHint(for:)` 生成的扩展名提示。
- fence 语言值在进入引擎前统一 `lowercased().trimmingCharacters(in: .whitespacesAndNewlines)`。

### 5.2 主题策略

- 不直接复用 Highlightr 的 theme background，把背景仍交给现有 SwiftUI 容器绘制。
- 只把 token font / foregroundColor / underline 等属性带回项目 UI。
- 实施时先通过 `availableThemes()` 选定一个 light/dark 组合，并把名字封装在服务内部常量里；不要在多个视图里散写主题名。

### 5.3 风险点

- Highlightr 基于 JavaScriptCore，首次初始化可能比普通富文本更重，因此要做懒加载和结果缓存。
- 把外部 attributed string 回写进 `NSTextView` 时，最容易破坏 `typingAttributes`、选区和光标颜色，Task 3 的测试必须优先锁住这一点。
- SwiftUI `Text(AttributedString)` 对 AppKit attribute 的支持不如 `NSTextView` 完整，因此消息代码块与编辑中代码块不要强行统一成同一种最终 view 技术。

## 6. 完成定义

- Highlightr 通过 SPM 接入，工程可编译。
- MarkdownMessageView 的普通代码块显示语法高亮并保留文本选择。
- BlockDocumentEditor 的 `.code` / `.source` 在编辑态与未编辑态都能显示语法高亮。
- Mermaid、未知语言和 plain text 都有稳定 fallback。
- 至少有两组 focused 单测覆盖服务层与编辑器样式层。

## 7. 验收 Checklist

- MarkdownMessageView 中的 Swift / JSON / Bash fenced code block 显示语法高亮，并保留复制与横向滚动。
- Mermaid block 继续走 Mermaid 渲染分支，不进入 Highlightr。
- BlockDocumentEditor 的 `.code` 和 `.source` block 在激活态与非激活态都显示语法高亮。
- 无语言 fenced block、未知语言、`text` / `plain` / `plaintext` 与空代码块都能稳定显示原文。
- 深浅色外观切换后，高亮 token 颜色随主题切换，不出现低对比度文本。

---

Plan complete and saved to `docs/plans/2026-03-29-highlightr-code-block-syntax-highlighting-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按这份计划逐任务实现，并在每个阶段回报验证结果。

**2. Parallel Session (separate)** - 你在新会话里用 executing-plans skill 按这份计划串行执行。

Which approach?