# AgentGui 写作功能需求说明

> **版本**: 1.0
> **日期**: 2026-03-07
> **目标**: 将 agentGui 从通用 AI Agent 客户端转型为专业的 AI 辅助写作工具

---

## 一、项目现状分析

### 1.1 当前架构概述

```
agentGui/
├── Models/              # SwiftData 数据模型
│   ├── Session         # 会话（对话线程）
│   ├── Message         # 消息
│   ├── ToolCall        # 工具调用记录
│   ├── AgentRound      # Agentic Loop 轮次
│   └── AppSettings     # 全局设置
├── Views/              # SwiftUI 视图
│   ├── MainSplitView   # 三栏布局（文件/编辑器/聊天）
│   ├── ChatView        # 聊天界面
│   ├── FileEditorView  # 文件编辑器
│   └── WorkspacePanelView # 文件浏览器
├── Services/           # 核心服务
│   ├── ClaudeService   # Claude API 封装
│   └── SkillService    # 技能系统
└── Models/
    └── SubagentDefinition  # 子代理定义（explorer/coder/reviewer 等）
```

### 1.2 现有功能清单

| 功能 | 状态 | 写作适用性 |
|------|------|-----------|
| Claude API 对话 | ✅ | 高 - 核心能力 |
| Agentic Loop | ✅ | 高 - 复杂写作任务 |
| 子代理系统 | ✅ | 中 - 需增加写作专用子代理 |
| Skills 系统 | ✅ | 高 - 可扩展写作技能 |
| 文件浏览器 | ✅ | 中 - 需增强项目管理 |
| 文件编辑器 | ⚠️ | 低 - 简单 TextEditor，需增强 |
| Markdown 渲染 | ✅ | 高 - 支持代码/表格/图表 |
| 消息持久化 | ✅ | 高 - 写作历史记录 |
| 文件拖拽/@mention | ✅ | 中 - 素材引用便利 |
| Extended Thinking | ✅ | 高 - 长文本生成质量 |

### 1.3 当前局限性

1. **编辑器功能简陋**: 使用原生 TextEditor，缺乏写作辅助功能
2. **无文档管理**: 没有"项目"概念，文件组织能力弱
3. **无预览功能**: 无法预览最终渲染效果
4. **无导出功能**: 无法导出为 PDF/EPUB 等格式
5. **无写作专用子代理**: 现有子代理面向开发，不适合写作场景
6. **无版本历史**: 缺少文档版本管理和回溯

---

## 二、写作场景核心需求

### 2.1 目标用户画像

| 用户类型 | 核心需求 | 使用场景 |
|---------|---------|---------|
| **内容创作者** | 灵感捕捉、大纲生成、内容润色 | 撰写博客、公众号文章、脚本 |
| **学术研究者** | 文献整理、论文写作、引用管理 | 撰写论文、研究报告 |
| **小说作者** | 情节规划、人物设定、章节写作 | 长篇小说、短篇小说创作 |
| **技术作者** | 技术文档整理、代码示例生成 | API 文档、教程编写 |
| **翻译人员** | 双语对照、术语一致性 | 翻译本地化内容 |

### 2.2 核心功能需求

#### F1: 文档项目管理
- [ ] **项目概念**: 一个项目包含多个相关文档（章节、草稿、素材）
- [ ] **项目模板**: 小说项目、论文项目、博客项目等
- [ ] **文档树**: 项目的文档结构可视化
- [ ] **项目级设置**: 独立的 AI 模型、提示词、样式设置

#### F2: 增强编辑器
- [ ] **语法高亮**: Markdown 语法实时高亮
- [ ] **行号显示**: 便于定位和讨论
- [ ] **大纲面板**: 自动提取标题结构
- [ ] **字数统计**: 实时字数/段落/阅读时间
- [ ] **专注模式**: 隐藏无关界面，仅显示编辑区
- [ ] **打字机模式**: 当前行居中

#### F3: AI 写作辅助
- [ ] **续写**: 根据上下文智能续写
- [ ] **润色**: 改善表达、调整语气
- [ ] **缩写**: 提炼核心观点
- [ ] **扩写**: 丰富细节和论证
- [ ] **翻译**: 多语言翻译
- [ ] **风格转换**: 正式/非正式/创意等风格切换

#### F4: 预览与导出
- [ ] **实时预览**: 分屏预览 Markdown 渲染效果
- [ ] **导出 PDF**: 支持自定义样式
- [ ] **导出 EPUB**: 电子书格式
- [ ] **导出 HTML**: 可定制的 HTML 模板
- [ ] **导出 DOCX**: Word 兼容格式

#### F5: 素材与知识库
- [ ] **素材库**: 独立的素材存储区域
- [ ] **快速插入**: 从素材库快速插入内容
- [ ] **标签管理**: 为素材打标签，便于检索
- [ ] **全文搜索**: 跨项目搜索内容

#### F6: 版本管理
- [ ] **自动保存**: 编辑时自动创建快照
- [ ] **版本历史**: 查看和恢复历史版本
- [ ] **版本对比**: 可视化显示差异
- [ ] **版本标签**: 为重要版本打标签

---

## 三、技术改造方案

### 3.1 数据模型扩展

```swift
// 新增模型

@Model
final class WritingProject {
    var id: UUID
    var name: String
    var projectType: ProjectType  // novel/thesis/blog/technical
    var createdAt: Date
    var updatedAt: Date
    var templateId: String?

    @Relationship(deleteRule: .cascade)
    var documents: [WritingDocument] = []

    @Relationship(deleteRule: .cascade)
    var materials: [MaterialItem] = []
}

@Model
final class WritingDocument {
    var id: UUID
    var title: String
    var content: String
    var contentType: DocumentContentType  // markdown/plain/html
    var order: Int
    var wordCount: Int
    var readingTime: Int  // minutes

    @Relationship(deleteRule: .cascade)
    var versions: [DocumentVersion] = []

    @Relationship(deleteRule: .cascade)
    var project: WritingProject?
}

@Model
final class DocumentVersion {
    var id: UUID
    var content: String
    var createdAt: Date
    var versionLabel: String?  // 用户自定义标签
    var isAutoSnapshot: Bool
}

@Model
final class MaterialItem {
    var id: UUID
    var title: String
    var content: String
    var tags: [String]
    var sourceUrl: String?
    var createdAt: Date
}

enum ProjectType: String, Codable {
    case novel = "小说"
    case thesis = "论文"
    case blog = "博客"
    case technical = "技术文档"
    case custom = "自定义"
}
```

### 3.2 子代理扩展

```swift
// SubagentDefinition.swift 新增

static let writer = SubagentDefinition(
    name: "writer",
    displayName: "写作者",
    description: "专业写作辅助：生成、润色、改写、翻译各类文本内容。",
    systemPrompt: """
    You are a professional writing assistant. Your task is to help with various writing needs.

    Capabilities:
    - Generate original content based on prompts
    - Polish and improve existing text
    - Rewrite in different styles (formal, casual, creative, etc.)
    - Translate between languages
    - Expand or summarize content

    Rules:
    - Maintain the original meaning when polishing/rewriting
    - Adapt the style to the specified tone
    - For translation, preserve formatting and structure
    - Return clean, ready-to-use text
    """,
    enableTextEditor: true,
    enableBash: false,
    maxRounds: 8
)

static let outline_planner = SubagentDefinition(
    name: "outline_planner",
    displayName: "大纲规划师",
    description: "帮助构建文档结构：章节规划、大纲生成、内容组织。",
    systemPrompt: """
    You are an expert at structuring content. Your job is to create well-organized outlines.

    Rules:
    - Analyze the topic and create a logical structure
    - Use clear hierarchy (chapters, sections, subsections)
    - Provide brief descriptions for each section
    - Consider narrative flow and coherence
    - Output as Markdown with proper heading levels
    """,
    enableTextEditor: true,
    enableBash: false,
    maxRounds: 6
)

static let researcher = SubagentDefinition(
    name: "researcher",
    displayName: "研究员",
    description: "阅读、整理、总结资料，为写作提供素材和背景信息。",
    systemPrompt: """
    You are a research assistant. Your job is to gather and synthesize information.

    Rules:
    - Read and analyze source materials carefully
    - Extract key points and relevant information
    - Organize findings in a clear, structured manner
    - Cite sources appropriately
    - Use the text editor tool ONLY with "view" command
    """,
    enableTextEditor: true,
    enableBash: false,
    maxRounds: 10
)
```

### 3.3 写作专用 Skills

```
~/.claude/skills/writing/
├── SKILL.md           # 主技能定义
├── novel-writing.md   # 小说写作专项
├── academic-writing.md # 学术写作专项
├── copywriting.md     # 文案写作专项
└── translation.md     # 翻译专项
```

### 3.4 UI 架构调整

```
原布局: [文件浏览器] [文件编辑器] [聊天面板]
新布局: [项目导航] [编辑器 + 预览] [AI 助手]

项目导航:
  ├─ 项目列表
  ├─ 文档树 (当前项目的文档结构)
  └─ 素材库

编辑器:
  ├─ 工具栏 (格式化、AI 操作)
  ├─ 编辑区 (增强的编辑器)
  └─ 大纲/预览切换

AI 助手:
  ├─ 快捷操作按钮
  ├─ 聊天界面
  └─ 写作工具箱
```

### 3.5 编辑器选型

**推荐方案**: 使用 [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor)

| 特性 | TextEditor (当前) | CodeEditSourceEditor |
|------|------------------|---------------------|
| 语法高亮 | ❌ | ✅ |
| 行号 | ❌ | ✅ |
| 主题 | ❌ | ✅ |
| 代码补全 | ❌ | ✅ |
| 多光标 | ❌ | ✅ |
| 大纲提取 | ❌ | 需自行实现 | 需自行实现 |
| 性能 | 一般 | 优秀 (Tree-sitter) |

---

## 四、实现优先级

### P0 - 核心功能 (第一阶段)

1. **WritingProject/WritingDocument 数据模型**
   - 实现项目和文档的核心数据结构
   - 项目创建/删除/重命名
   - 文档 CRUD 操作

2. **增强编辑器**
   - 集成 CodeEditSourceEditor
   - Markdown 语法高亮
   - 行号显示

3. **写作子代理**
   - 实现 writer / outline_planner / researcher
   - 集成到工具选择器

4. **UI 布局调整**
   - 项目导航面板
   - 编辑器+预览分屏

### P1 - 增强功能 (第二阶段)

5. **预览功能**
   - Markdown 实时预览
   - 分屏同步滚动

6. **导出功能**
   - PDF 导出
   - HTML 导出

7. **素材库**
   - 素材 CRUD
   - 标签系统
   - 快速插入

8. **字数统计**
   - 实时字数
   - 阅读时间估算

### P2 - 高级功能 (第三阶段)

9. **版本管理**
   - 自动快照
   - 版本历史
   - 版本对比

10. **EPUB/DOCX 导出**
    - 电子书格式
    - Word 格式

11. **专注模式**
    - 全屏编辑
    - 打字机模式

12. **高级 AI 功能**
    - 风格迁移
    - 语气调整
    - 多语言翻译

### P3 - 优化与扩展 (第四阶段)

13. **全文搜索**
    - 跨项目搜索
    - 高亮匹配

14. **协作功能**
    - 评论系统
    - 批注

15. **云端同步**
    - iCloud 集成
    - 项目分享

16. **插件系统**
    - 自定义编辑器扩展
    - 自定义导出格式

---

## 五、关键设计决策

### 5.1 编辑器技术栈

| 方案 | 优势 | 劣势 | 推荐度 |
|------|------|------|--------|
| WebView + Monaco | 功能完整、生态丰富 | 性能差、内存占用高 | ⭐⭐ |
| WKWebView + CodeMirror 6 | 轻量、可定制 | JS桥接复杂 | ⭐⭐⭐ |
| CodeEditSourceEditor | 原生 Swift、Tree-sitter | 维度较低 | ⭐⭐⭐⭐⭐ |
| NSTextView + 自定义高亮 | 完全可控 | 开发成本高 | ⭐⭐⭐ |

**决策**: 使用 **CodeEditSourceEditor**

### 5.2 预览渲染方案

| 方案 | 优势 | 劣势 | 推荐度 |
|------|------|------|--------|
| 复用 MarkdownMessageView | 代码复用 | 非实时、滚动不同步 | ⭐⭐ |
| WebView + cmark-gfm | 功能完整 | 性能开销 | ⭐⭐⭐ |
| 原生 SwiftUI + cmark | 性能好 | 功能受限 | ⭐⭐⭐⭐ |
| Ink (MacEditor) | 专为 macOS 设计 | 需调研 | ⭐⭐⭐⭐ |

**决策**: 使用 **cmark + SwiftUI** 扩展现有渲染器

### 5.3 导出格式支持

```
优先支持:
  ├─ PDF    (使用 PDFKit)
  ├─ HTML   (自定义模板)
  └─ Markdown (原生)

后续支持:
  ├─ EPUB   (使用 EPUBKit)
  └─ DOCX   (考虑使用 LibreOffice 转换或手动生成)
```

### 5.4 AI 操作集成点

```
三种集成方式:

1. 聊天对话 (现有)
   用户: "帮我润色这段话"
   AI: 直接修改文件内容

2. 选中操作 (新增)
   选中文本 → 右键菜单 → AI 操作
   └─ 润色 / 扩写 / 缩写 / 翻译

3. 工具栏按钮 (新增)
   编辑器顶部快捷按钮
   └─ 续写 / 生成大纲 / 检查语法
```

---

## 六、文件结构建议

```
agentGui/
├── Models/
│   ├── WritingProject.swift       # 新增
│   ├── WritingDocument.swift      # 新增
│   ├── DocumentVersion.swift      # 新增
│   ├── MaterialItem.swift         # 新增
│   └── ProjectTemplate.swift      # 新增
│
├── Views/
│   ├── Writing/
│   │   ├── ProjectListView.swift      # 新增：项目列表
│   │   ├── ProjectDetailView.swift    # 新增：项目详情
│   │   ├── DocumentTreeView.swift     # 新增：文档树
│   │   ├── MaterialLibraryView.swift  # 新增：素材库
│   │   ├── EnhancedEditorView.swift   # 新增：增强编辑器
│   │   ├── PreviewSplitView.swift     # 新增：预览分屏
│   │   └── ExportOptionsSheet.swift   # 新增：导出选项
│   │
│   ├── Editor/
│   │   ├── EditorToolbar.swift        # 新增：编辑器工具栏
│   │   ├── EditorOutlinePanel.swift   # 新增：大纲面板
│   │   └── EditorStatusbar.swift      # 新增：状态栏(字数)
│   │
│   └── AI/
│       ├── WritingAssistantView.swift # 新增：写作助手
│       └── QuickAIActionsPanel.swift  # 新增：快捷操作
│
├── Services/
│   ├── ProjectService.swift           # 新增：项目管理
│   ├── DocumentService.swift          # 新增：文档管理
│   ├── VersionControlService.swift    # 新增：版本控制
│   ├── ExportService.swift            # 新增：导出服务
│   └── MaterialService.swift          # 新增：素材管理
│
├── Utils/
│   ├── MarkdownParser.swift           # 新增：增强 Markdown 解析
│   ├── WordCounter.swift              # 新增：字数统计
│   ├── Exporters/
│   │   ├── PDFExporter.swift
│   │   ├── HTMLExporter.swift
│   │   └── EPUBExporter.swift
│   └── Templates/
│       ├── ProjectTemplates.swift
│       └── ExportTemplates.swift
│
└── Resources/
    ├── Templates/         # 项目模板
    │   ├── Novel.template/
    │   ├── Thesis.template/
    │   └── Blog.template/
    └── Themes/            # 导出主题
        ├── Academic.html
        └── Modern.html
```

---

## 七、里程碑计划

| 里程碑 | 时间 | 交付物 |
|--------|------|--------|
| **M1: 数据模型** | Week 1-2 | Project/Document/Version 模型，基础 CRUD |
| **M2: 编辑器升级** | Week 3-4 | CodeEditSourceEditor 集成，语法高亮 |
| **M3: 写作子代理** | Week 5-6 | 3 个写作专用子代理 |
| **M4: UI 重构** | Week 7-8 | 新的三栏布局，项目导航 |
| **M5: 预览功能** | Week 9-10 | 分屏预览，实时渲染 |
| **M6: 导出功能** | Week 11-12 | PDF/HTML 导出 |
| **M7: 素材库** | Week 13-14 | 素材管理，标签系统 |
| **M8: 版本管理** | Week 15-16 | 自动快照，版本历史 |
| **M9: 优化打磨** | Week 17-18 | 性能优化，UI 细节 |
| **M10: 测试发布** | Week 19-20 | 测试，修复，发布 |

---

## 八、风险评估

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| CodeEditSourceEditor 维护停滞 | 高 | 保留降级方案，考虑切换到 WKWebView |
| Swift 6 并发模型复杂度 | 中 | 逐步迁移，充分测试 |
| PDF/EPUB 导出格式问题 | 中 | 使用成熟库，设置格式验证 |
| AI 生成内容质量不稳定 | 低 | 提供人工编辑能力，允许撤销 |
| 大文档性能问题 | 中 | 实现虚拟滚动，分块加载 |

---

## 九、成功指标

### 9.1 功能指标

- [ ] 支持至少 3 种项目模板
- [ ] 编辑器支持流畅编辑 10 万字文档
- [ ] AI 续写准确率 > 80%
- [ ] 导出 PDF 格式正确率 100%
- [ ] 版本快照性能 < 100ms

### 9.2 用户体验指标

- [ ] 冷启动时间 < 2s
- [ ] 编辑器响应延迟 < 16ms (60fps)
- [ ] AI 续写响应 < 3s
- [ ] 导出 5 万字 PDF < 5s

---

## 附录：参考项目

| 项目 | 参考价值 |
|------|---------|
| [Obsidian](https://github.com/obsidianmd/obsidian-sample-publish) | 知识库管理，插件系统 |
| [Typora](https://typora.io/) | 编辑器交互体验 |
| [Scrivener](https://www.literatureandlatte.com/scrivener/overview) | 项目管理，素材组织 |
| [Ulysses](https://ulysses.app/) | 文档库，导出功能 |
| [Notion](https://www.notion.so/) | AI 写作集成 |
| [Joplin](https://github.com/laurent22/joplin) | 开源笔记，同步方案 |
