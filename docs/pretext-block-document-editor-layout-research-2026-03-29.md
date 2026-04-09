# PreTeXt 与 BlockDocumentEditor 排版/性能适配研究报告

日期：2026-03-29

## 1. 研究结论

结论先行：PreTeXt 不能作为 BlockDocumentEditor 的“可直接移植排版算法”来源，也不太可能通过引入它而让编辑器性能获得大幅提升。

原因很直接：PreTeXt 的核心定位不是交互式编辑器排版引擎，而是一个面向教材、论文、专著的语义化标记与发布系统。它擅长的是“单一结构化源 -> 多目标格式转换”，而不是“用户每次敲键后在本地做增量布局、命中测试、可见区虚拟化和输入响应”。

如果把它硬套到 BlockDocumentEditor，最大的结果不是性能提升，而是引入一条更重的离线转换链路，把当前的交互问题换成另一组更昂贵的同步与桥接问题。

更准确的结论是：

- 不能直接复用的，是 PreTeXt 所谓“排版能力”本身。
- 可以借鉴的，是它的语义优先、转换分层、批处理昂贵步骤、静态输出与交互体验分离这些工程思路。
- 真正能显著提升 BlockDocumentEditor 性能的，仍然是编辑器自身的布局容器、虚拟化策略、增量序列化、行列映射缓存和交互命中面重构。

## 2. 研究目标与判断标准

本次调研要回答的问题不是“PreTeXt 优不优秀”，而是更具体的三个问题：

1. PreTeXt 是否拥有可嵌入 BlockDocumentEditor 的运行时排版算法。
2. 即便没有，是否存在可迁移的布局/分块/缓存机制，能明显降低当前编辑器的渲染与交互成本。
3. 如果不能直接迁移，PreTeXt 中有哪些设计思想值得转化为 BlockDocumentEditor 的工程方案。

本报告用以下标准判断“是否适用”：

- 是否面向交互式编辑，尤其是按键级增量更新。
- 是否解决可见区虚拟化、命中测试、选区映射、滚动稳定性这些编辑器问题。
- 是否能在 macOS 本地 SwiftUI/AppKit 架构中低成本落地。
- 是否可能在当前瓶颈位置上带来数量级收益，而不是只改善导出质量或模型表达。

## 3. PreTeXt 到底是什么

根据 PreTeXt 官网、Guide 与公开仓库，PreTeXt 的本质是一个语义化文档系统：作者用结构化标记编写教材、课程材料、论文与专著，然后通过转换链路生成 HTML、PDF、EPUB、RevealJS、Jupyter 等多种输出。

从公开资料看，它的关键词始终是：

- single source
- conversion
- templates
- HTML / LaTeX / EPUB / Jupyter output
- accessibility

这与交互式 block editor 的问题域并不相同。

外部资料要点如下：

- PreTeXt 官网明确把它定义为 authoring and publishing system，而不是 editor runtime 或 layout engine。
- 项目 README 把核心原则描述为“结构化标记语言”和“多格式转换”。
- 仓库实现以 XSLT、Python、CSS、JavaScript 为主，重点在转换、打包、样式与输出兼容，而不是本地实时增量排版。

外部资料来源：

- https://pretextbook.org/
- https://pretextbook.org/why-pretext.html
- https://pretextbook.org/guide.html
- https://github.com/PreTeXtBook/pretext
- https://raw.githubusercontent.com/PreTeXtBook/pretext/master/README.md

## 4. PreTeXt 的“排版”实际由谁完成

这一步是本报告最关键的判断。

PreTeXt 虽然能生成高质量排版结果，但它并不自己承担一个通用运行时排版器的角色。它主要做的是：

1. 用结构化源描述内容与语义。
2. 通过 XSLT/Python 把内容转换为目标格式。
3. 把最终排版工作交给下游系统。

这些下游系统包括：

- HTML/CSS 浏览器布局引擎
- LaTeX/PDF 处理链
- MathJax/SRE 数学公式渲染
- EPUB 阅读器

也就是说，PreTeXt 的“排版能力”大多来自它为不同输出目标生成了合适的中间表示与配置，而不是它自己内部存在一套类似 TextKit、浏览器 layout tree、Knuth-Plass 行分割器、虚拟列表布局器那样的统一运行时排版内核。

从公开仓库也能看到这个边界：

- `xsl/README.md` 明确说明 XSL stylesheets 的主要职责是把 PreTeXt XML 转成多种输出格式。
- `pretext/lib/pretext.py` 中的 HTML、LaTeX、PDF、EPUB 入口，本质是编排转换与打包流程。
- 数学公式的处理依赖 MathJax/SRE 的 page 工具链，而不是 PreTeXt 自己实现的数学排版器。
- LaTeX/PDF 生成明确走“XML -> LaTeX -> PDF”路径。

所以如果把问题换成一句话，答案会更清楚：

PreTeXt 更像“语义化出版编译器”，不是“交互式编辑器排版内核”。

## 5. BlockDocumentEditor 当前真正的性能问题在哪里

结合仓库现状，BlockDocumentEditor 的热点问题主要集中在交互画布、全量同步、视图失效和选区计算，而不是“缺一个更高级的排版算法”。

### 5.1 容器仍然是 List，天然不适合作为块编辑器交互画布

当前编辑器仍把主内容挂在 [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift#L110-L165) 的 `List` 上，同时又叠加自定义框选、拖拽重排、原生文本编辑、表格交互与命中面分离。

仓库现有备注已经明确指出这点：

- [docs/bug/2026-03-29-block-document-editor-interaction-bugs.md](docs/bug/2026-03-29-block-document-editor-interaction-bugs.md#L58-L69)
- [docs/block-document-editor-refactor-analysis-2026-03-18.md](docs/block-document-editor-refactor-analysis-2026-03-18.md#L193-L220)

这类问题首先是容器模型与交互模型不匹配，不是出版排版算法缺失。

### 5.2 文档同步仍然包含全量序列化路径

当前外部文本变化与内部回写都要走 `BlockMarkdownCodec.serialize`，见：

- [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift#L434-L444)
- [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift#L768-L781)

这说明编辑器内部虽然已经有结构化 `BlockDocument`，但大量交互仍然会回落到整篇文档序列化比较。这里的开销是数据同步策略问题，不是文字排版算法问题。

### 5.3 选区映射包含前缀文档重序列化

`lineRange(for:)` 为了把块内选区映射回源文件行号，会先序列化从头到当前块的前缀文档，再回头查当前块文本位置，见 [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift#L881-L901)。

这是一条典型的 $O(n)$ 交互路径。它说明当前瓶颈更接近：

- 缺少 prefix-sum / 行号索引
- 缺少块级源映射缓存
- 缺少稳定的 block offset table

这和 PreTeXt 的离线出版转换完全不是同一个层次的问题。

### 5.4 文本编辑器的成本来自 NSTextView 嵌入与高度重算

`BlockTextEditor` 当前为每个活跃块嵌入 `NSTextView`，并在宽度变化、文本变化、样式变化时重新应用样式与高度计算，见 [agentGui/Views/Editor/BlockTextEditor.swift](agentGui/Views/Editor/BlockTextEditor.swift#L41-L149)。

这类成本主要来自：

- SwiftUI 与 AppKit bridge
- TextKit 布局失效
- block 级高度测量
- 视图生命周期与 first responder 编排

这也不是 PreTeXt 能替代的部分。

### 5.5 当前 residency 只限制“重编辑器挂载数”，没有解决整体布局与失效传播

仓库已经引入 `BlockEditorResidency` 来只挂载少量重编辑器，但这最多只能降低活跃 `NSTextView` 数量，并不能从根上解决：

- `List` 作为画布的交互冲突
- 块列表整体失效传播
- 全量序列化与前缀重算
- 自定义框选所需几何采样

对应实现可见：

- [agentGui/Views/Editor/BlockEditorResidency.swift](agentGui/Views/Editor/BlockEditorResidency.swift#L1-L24)
- [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift#L143-L161)

这意味着当前性能天花板主要由容器与数据同步策略决定，不是单纯由“文本块排版质量”决定。

## 6. PreTeXt 可否直接应用到 BlockDocumentEditor

### 6.1 直接套用 PreTeXt 排版算法

结论：不可行。

原因：PreTeXt 并不存在一个可直接嵌入的统一运行时排版算法内核。它的强项是：

- 结构化语义表达
- 输出模板化
- 离线转换
- 输出目标适配

而 BlockDocumentEditor 需要的是：

- 每次击键后的局部增量更新
- 稳定滚动与高度估算
- 可见区虚拟化
- 原生文本命中测试
- 块级与文本级选择共存
- 拖拽、框选、表格与输入法协同

这两者不是同一种技术资产。

### 6.2 把 PreTeXt 作为中间文档模型引入

结论：不建议。

原因：

- 当前编辑器的权威工作状态已经是 `BlockDocument`，见 [docs/plans/2026-03-17-block-document-editor-undo-redo-design.md](docs/plans/2026-03-17-block-document-editor-undo-redo-design.md#L58-L70)。
- 再引入一层 PreTeXt XML 或类似出版语义树，只会增加结构转换、同步和丢失信息的风险。
- 它可能有利于导出出版物，但对本地编辑性能帮助有限。

如果未来要做导出到教材/长文档系统，可以把 PreTeXt 作为“导出目标”研究，而不是“编辑器内部核心模型”。

### 6.3 借用 PreTeXt 的分块/分文件思想

结论：有一定启发，但收益主要在工程架构，不在运行时排版。

PreTeXt 在 HTML/EPUB 生成时大量使用 chunking、file-wrap、不同输出目标的静态资源编排。这些思想可以迁移为：

- 把 BlockDocumentEditor 的运行时模型、导出模型、持久化模型彻底分离
- 对昂贵派生结果做块级缓存，而不是全量重算
- 在后台批量生成导出预览，而不是把导出逻辑塞进交互主线程

但这仍然不是“直接提速编辑排版”的路径。

## 7. PreTeXt 真正值得借鉴的部分

虽然不能直接迁移排版算法，但 PreTeXt 有几类思路值得借鉴。

### 7.1 语义优先，而不是展示优先

PreTeXt 的核心价值在于先把内容结构表达清楚，再针对输出目标做转换。

对 BlockDocumentEditor 而言，这对应着：

- 保持 `BlockDocument` 作为权威结构模型
- 不让 UI 层承担文档事实来源
- 把导出、回写、行号映射、只读预览这些派生能力移出 View

这与仓库里已有的重构方向是一致的，见 [docs/block-document-editor-refactor-analysis-2026-03-18.md](docs/block-document-editor-refactor-analysis-2026-03-18.md#L69-L108)。

### 7.2 把昂贵转换当作批处理，而不是交互路径的一部分

PreTeXt 对数学、EPUB 打包、LaTeX/PDF 生成等昂贵步骤，基本都是批处理思路。

对当前编辑器，这意味着：

- Markdown 全量序列化不应频繁落在击键级主链路上
- 行号映射不应靠临时序列化前缀文档获得
- 只读渲染、导出 HTML、富文本预览应尽量后台化

这是可以借鉴的，而且对性能有现实意义。

### 7.3 输出样式与内容结构分离

PreTeXt 明确把结构和样式模板分开。对 block editor 而言，这意味着：

- block family 的视觉呈现不应与编辑事务逻辑耦死
- 样式切换不应迫使整个编辑器状态机重构
- 只读态与编辑态的 display pipeline 应保持清晰边界

这有助于减少无谓的视图失效。

### 7.4 分目标优化，而不是追求一个万能内核

PreTeXt 的 HTML、LaTeX、EPUB、Jupyter 都不是强行共用一个“万能排版器”，而是共用语义源，分目标生成。

对应到 BlockDocumentEditor，可以得出一个重要结论：

不要试图让“编辑态视图”“只读态视图”“导出态表示”“搜索索引态表示”完全复用一条渲染链。

应当共用结构模型，但允许多条派生管线。

## 8. 哪些收益被高估了

如果把 PreTeXt 引入 BlockDocumentEditor，最容易被高估的有三点。

### 8.1 误以为语义模型会自动带来运行时性能

语义模型更清晰，通常会改善可维护性和导出质量，但不会自动解决：

- 滚动卡顿
- 首响应器切换
- 命中测试冲突
- 视图失效传播
- 高度估算与虚拟化

这些仍然要靠编辑器专用的数据结构与容器设计解决。

### 8.2 误以为出版级排版等于编辑器级排版

出版系统追求的是高质量最终输出，允许：

- 更重的离线处理
- 多阶段转换
- 较长生成时间
- 格式特化

交互式编辑器追求的是：

- 小于一帧的响应预算
- 局部更新
- 稳定选区
- 可见区内最小化失效

这两类系统的优化目标本来就不同。

### 8.3 误以为引入更复杂的中间层就会提升性能

对当前 BlockDocumentEditor 来说，再增加一个 XML/转换层，几乎可以确定会先增加：

- 数据映射成本
- 调试难度
- 同步一致性风险
- 状态边界复杂度

而不是先增加性能。

## 9. 如果目标是“大幅提速”，更应该做什么

下面这些方向，比研究 PreTeXt 迁移更接近真实收益点。

### 9.1 把 List 画布替换为专用滚动容器

优先级最高。

建议把主画布从 `List` 迁到更可控的容器，例如：

- `ScrollView + LazyVStack`，配合自定义命中层
- 更进一步，使用 AppKit 容器或自定义虚拟化布局

原因不是“SwiftUI List 慢”这么简单，而是它对块级选择、正文文本交互、表格单元格、框选、拖拽重排的契约都不匹配。

现有仓库证据：

- [docs/bug/2026-03-29-block-document-editor-interaction-bugs.md](docs/bug/2026-03-29-block-document-editor-interaction-bugs.md#L37-L69)
- [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift#L110-L165)

### 9.2 建立块级布局缓存与可见区虚拟化

需要的不是出版排版器，而是编辑器布局索引：

- 每个 block 的估算高度
- 可见区 block range
- 滚动偏移到 block index 的快速映射
- 编辑态与只读态高度缓存分离

这样才能把重型 `NSTextView`、表格与几何采样限制在可见区附近。

### 9.3 把序列化与行号映射改为增量索引

建议新增两类基础设施：

- `BlockDocumentSynchronizer`
- `BlockSelectionLineMapper`

这也与现有重构分析建议一致，见 [docs/block-document-editor-refactor-analysis-2026-03-18.md](docs/block-document-editor-refactor-analysis-2026-03-18.md#L193-L220)。

具体做法：

- 缓存每个 block 的序列化结果
- 维护前缀换行数数组
- block 变更时只更新受影响区间
- 选区映射直接查 prefix index，而不是临时序列化前缀文档

这条线的收益会比任何“引入出版系统”都实在。

### 9.4 把只读显示与编辑显示彻底分层

当前 residency 已经说明系统在尝试这么做，但还不彻底。

更完整的方向应该是：

- 只读态使用轻量渲染树
- 编辑态只为 active block 和近邻 block 挂载重编辑器
- selection rail、框选层、拖拽层独立于正文文本命中区域

这样才能避免不同交互在一个命中面上竞争。

### 9.5 将昂贵派生工作后台化

例如：

- 只读 Markdown 富文本派生
- 导出 HTML
- 语法高亮预处理
- 大文档统计与索引

这些更接近 PreTeXt 的思路，但要以“后台批处理派生”为目标，而不是“把 PreTeXt 引入主编辑链路”。

## 10. 推荐决策

如果目标是“大大提升 BlockDocumentEditor 性能”，建议做以下决策：

1. 不把 PreTeXt 作为编辑器运行时排版方案引入。
2. 可以把 PreTeXt 作为导出/发布方向的参考对象，但仅限离线管线。
3. 立项优先级应转向：容器替换、虚拟化、增量同步、选区映射缓存、命中面重构。
4. 若需要借鉴 PreTeXt，只借鉴其“语义模型 + 分目标转换 + 批处理昂贵步骤”的工程哲学。

## 11. 最终判断

综合判断如下：

### 适配结论

- 直接复用 PreTeXt 排版算法：否。
- 借用其文档结构思想：可以，但主要提升可维护性，不会直接带来大幅性能收益。
- 借用其批处理与转换分层思路：可以，适合导出和后台派生任务。
- 作为 BlockDocumentEditor 性能优化主线：不推荐。

### 预期收益判断

- 直接集成 PreTeXt：高成本，低性能回报。
- 用 PreTeXt 思路指导架构重构：中等成本，中等长期收益。
- 聚焦容器、虚拟化、增量索引：中高成本，但最有希望带来显著体感提升。

一句话总结：

PreTeXt 值得研究，但它解决的是“如何把语义文档高质量发布到多个目标”的问题；BlockDocumentEditor 当前急需解决的是“如何让一个复杂块编辑器在本地交互里只做最少必要工作”的问题。前者不能替代后者。
