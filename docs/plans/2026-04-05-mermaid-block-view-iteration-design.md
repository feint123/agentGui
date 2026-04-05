# MermaidBlockView 迭代设计文档

**日期：** 2026-04-05  
**状态：** 设计阶段  
**关联文件：** `agentGui/Views/MermaidBlockView.swift`

---

## 一、背景与现状

`MermaidBlockView` 已从 `MarkdownMessageView.swift` 中提取为独立文件。当前实现提供：

- 主题跟随 Light/Dark（`zincLight` / `zincDark`）
- 宽度手动调节（±100px，200~1600px 步进）
- 图表 / 源码切换
- 基于 `BeautifulMermaid 1.0.1`（纯 Swift，ELK 布局引擎，无 WebView）

支持的图表类型（库层面）：Flowchart · State · Sequence · Class · ER · XY Chart。

---

## 二、竞品调研

| 产品 | Mermaid 渲染方式 | 主题/Dark Mode | 图表类型数 | 导出 | 错误提示 | 自适应高度 | 交互缩放 |
|------|----------------|---------------|---------|------|---------|----------|---------|
| **Claude.ai Web** | JS（mermaid.js） | ✅ 自动 | 全量 20+ | PNG 下载 | ✅ 内联红色错误 | ✅ 自动 | ❌ |
| **Cursor IDE** | WKWebView (mermaid.js) | ✅ | 全量 | SVG复制 | ✅ | ✅ | ❌ |
| **Craft App** | BeautifulMermaid（即本库） | ✅ + 多主题 | 6 | PNG导出 | ⚠️ 降级空白 | ✅ | ✅ Pinch |
| **Notion** | WKWebView | ✅ | 全量 | ❌ | ✅ | ✅ | ❌ |
| **GitHub** | @mermaid-js/mermaid | ✅ | 全量 | ❌ | ❌ 空白 | ✅ | ❌ |
| **当前 agentGui** | BeautifulMermaid NSView | ✅ zinc only | 6 | ❌ | ❌ 无提示 | ❌ 固定250px | ❌ 手动步进 |

**差距总结：**
1. **高度固定 250px** — 复杂图表被截断，简单图表留白明显
2. **无错误提示** — 语法错误时显示空白，用户无感知
3. **无导出功能** — 竞品普遍支持 PNG/SVG 导出
4. **主题单一** — 库内置 17 种主题，只用了 2 种
5. **宽度控制粗糙** — ±100px 按钮体验差，拖拽更直觉
6. **缺少全屏/放大** — 大型图表（ER、Class）可读性差
7. **图表类型标识缺失** — 用户无法一眼识别图表类型

---

## 三、迭代目标

以 **Craft App Mermaid** 体验为参照，在 macOS 原生框架内达到甚至超越竞品水准。

核心体验原则：
- **即见即所得**：渲染结果要与内容自适应，不截断也不留白
- **静默降级**：渲染失败给出明确的错误引导而非空白
- **快速导出**：一键复制图片/SVG，融入工作流
- **视觉精致**：主题跟随 app 整体风格，工具栏简洁

---

## 四、Feature 划分

> 改动较大，按独立可交付单元划分为 4 个 Feature。

---

### Feature M-1：自适应高度渲染

**优先级：** P0（最影响可用性）

**问题：** `MermaidNSView` 固定 `.frame(width: diagramWidth, height: 250)`，复杂图表截断，简单图表留白。

**方案：**

使用 `BeautifulMermaid` 的 `MermaidDiagramView`（SwiftUI 原生）+ `@Observable` 替代 `NSViewRepresentable`，或利用 `MermaidImageRenderer` 异步渲染后获取图像真实尺寸计算高度比。

```swift
// 推荐：先异步渲染为 NSImage，再根据图像真实宽高比自适应 frame
@MainActor
func renderedImage(source: String, theme: DiagramTheme, width: CGFloat) async -> NSImage?

// 计算 height = width / (image.size.width / image.size.height)
```

**交付物：**
- 替换固定高度为动态计算高度
- 渲染占位（骨架屏 SkeletonBlock）
- 单元测试：height > 0，宽高比合理

**文件：** `agentGui/Views/MermaidBlockView.swift`

---

### Feature M-2：错误状态与降级展示

**优先级：** P0

**问题：** BeautifulMermaid 解析失败时视图为空白，无任何提示。

**方案：**

包裹 `try/catch`，捕获渲染错误后以 `callout` 样式展示错误详情。

```swift
enum MermaidRenderState {
    case loading
    case success(NSImage, CGFloat) // image + aspectRatio  
    case failure(String)           // error description
}
```

**UI 设计：**
- Loading：SkeletonBlock（与其他骨架屏一致）
- Success：异步渲染图像
- Failure：橙色 Callout，显示 "无法渲染此图表" + 错误摘要 + "查看源码" 快捷按钮

**文件：** `agentGui/Views/MermaidBlockView.swift`

---

### Feature M-3：图表导出（PNG / 复制到剪贴板）

**优先级：** P1

**竞品参照：** Claude.ai 支持 PNG 下载，Cursor 支持 SVG 复制。

**方案：**

工具栏添加导出按钮，利用 `MermaidImageRenderer` 以 Retina（scale=2.0）渲染 PNG，支持：

1. **复制图片** — `NSPasteboard` 写入 `NSImage`（直接可粘贴到 Keynote/Notion 等）
2. **保存为 PNG** — `NSSavePanel` 文件保存

```swift
// M-3 工具栏新增按钮：
Menu {
    Button("复制图片") { copyImage() }
    Button("存储为 PNG…") { savePNG() }
} label: {
    Image(systemName: "square.and.arrow.up")
        .font(.caption)
}
.menuStyle(.borderlessButton)
```

**文件：** `agentGui/Views/MermaidBlockView.swift`

---

### Feature M-4：主题扩展 + 图表类型标识

**优先级：** P1

**4a — 主题跟随 Accent Color**

当前仅 `zincLight`/`zincDark`，忽略了 App 的强调色。使用 `DiagramTheme` 的两色构造器，将系统 accent color 映射为图表强调色：

```swift
private func buildTheme(colorScheme: ColorScheme, accent: Color) -> DiagramTheme {
    let bg = colorScheme == .dark ? "#1c1c1e" : "#ffffff"
    let fg = colorScheme == .dark ? "#f2f2f7" : "#1c1c1e"
    let accentHex = accent.toHex() ?? "#007AFF"
    return DiagramTheme(background: bg, foreground: fg, accent: accentHex)
}
```

**4b — 图表类型标识 Badge**

工具栏 `"mermaid"` 文字替换为动态图表类型：解析 source 首行关键词，显示对应图标 + 类型名：

| 关键词 | 图标 | 显示名 |
|--------|------|--------|
| `graph`, `flowchart` | `arrow.triangle.branch` | Flowchart |
| `sequenceDiagram` | `arrow.left.arrow.right` | Sequence |
| `classDiagram` | `rectangle.3.group` | Class |
| `stateDiagram` | `arrow.trianglehead.2.counterclockwise.rotate.90` | State |
| `erDiagram` | `tablecells` | ER |
| `xychart-beta` | `chart.bar.xaxis` | XY Chart |

**文件：** `agentGui/Views/MermaidBlockView.swift`  
辅助扩展：`agentGui/Utilities/Color+Hex.swift`（若已存在则复用）

---

## 五、不在本次范围内

- **Gantt / Timeline / Mindmap** — BeautifulMermaid 尚不支持；待库升级后补充
- **点击节点交互** — 库限制（Parser Limitations：不支持 Click callbacks）
- **Live 编辑模式** — 属于编辑器功能，需单独 Feature
- **拖拽调整宽度** — M-1 自适应高度后意义降低，暂不引入拖拽句柄

---

## 六、实现顺序建议

```
M-1（自适应高度）→ M-2（错误状态）→ M-3（导出）→ M-4（主题+标识）
```

M-1 和 M-2 共同解决"基本可用性"问题，应优先完成。M-3/M-4 是体验提升，可并行开发。

---

## 七、测试策略

| Feature | 测试文件 | 关键用例 |
|---------|---------|---------|
| M-1 | `MermaidBlockViewRenderTests` | 渲染后高度 > 0，宽高比在 0.1~10 之间 |
| M-2 | `MermaidBlockViewRenderTests` | 非法 source 进入 `.failure` 状态，callout 内容非空 |
| M-3 | 手工验证 | 粘贴板含 NSImage，PNG 文件可打开 |
| M-4 | `MermaidDiagramTypeDetectorTests` | 各关键词正确映射图类型 |

---

## 八、依赖确认

- `BeautifulMermaid` ≥ 1.0.1 — ✅ 已引入（`MermaidImageRenderer`、`DiagramTheme` 两色构造器均在 1.0.x 可用）
- `Color+Hex` 扩展 — 需确认项目内是否已有；若无，M-4 需新增
- `SkeletonBlock` — ✅ 已存在于 `agentGui/Views/SkeletonBlock.swift`
