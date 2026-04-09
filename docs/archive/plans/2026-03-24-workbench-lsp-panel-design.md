# Workbench LSP 面板拆分与重设计方案

日期：2026-03-24

## 摘要

本方案用于重构 Workbench 侧栏中的 LSP 面板。目标有两个：

- 结构上，将目前内嵌在 WorkbenchSidebarView 中的 WorkbenchLSPPanelView 提取到独立文件，恢复侧栏入口文件的职责边界。
- 体验上，将当前“摘要卡片 + 两个 popover”的交互改为“面板内直接可见的分区列表”，让用户在不离开当前上下文的情况下完成状态判断、诊断浏览和服务管理。

推荐方向不是继续给现有卡片堆叠更多按钮，而是把 LSP 面板重构为一个更接近 Xcode Issue Navigator、macOS Settings 分组列表、GitHub Desktop 紧凑状态区的混合形态：顶部展示当前工作区与当前文件的 LSP 状态，中段直接显示最近诊断列表，底部以可展开服务列表提供安装、重检、启动、停止、重启等操作。

这样做的价值很直接：

- 诊断信息不再藏在弹出层里，扫描路径更短。
- 服务管理操作与其运行状态在同一视觉区域，减少来回打开弹层的成本。
- 侧栏源码结构更清晰，LSP 面板后续可以独立演化，而不会继续膨胀 WorkbenchSidebarView。

## 当前现状

当前实现位于 WorkbenchSidebarView 内部私有类型中，主要问题有四类。

### 1. 结构耦合过高

WorkbenchSidebarView 当前同时承担：

- 顶部导航按钮容器。
- 各工作台 panel 的切换。
- LSP 面板完整实现。

这使得一个本应稳定的壳层文件同时持有导航、容器动画、LSP 数据接线、状态区、诊断区、管理区和两个 popover 交互。文件职责已经超出“sidebar shell”的合理范围，不利于维护，也不利于复用或测试。

### 2. 信息架构割裂

当前 LSP 面板本体只显示：

- 服务 ID。
- 当前状态。
- 诊断计数。
- 一个最近诊断摘要。

而用户真正需要看的详细信息和高频动作，被拆进两个单独 popover：

- 诊断详情。
- 服务管理。

这导致主面板只能做“发现入口”，不能真正完成任务。用户需要先理解摘要，再点击，再在弹层里继续理解上下文，信息链路偏长。

### 3. popover 不适合侧栏持续操作

Popover 在这里有明显问题：

- 信息密度一高就会变成小窗里的滚动区域，可读性下降。
- 弹层遮挡主面板，用户难以在“摘要”和“详情”之间稳定对照。
- 管理操作执行后，用户需要重新确认摘要是否变化，视线往返成本高。
- 对于 macOS 侧栏这种本来就窄的空间，popover 更像临时逃逸口，不像稳定工作区。

### 4. 视觉层级还不够像系统级工具面板

当前三块 glass 卡片方向是对的，但中层信息组织仍偏“网页卡片”，不是“专业 macOS 工具侧栏”：

- 关键信息没有形成强主次层级。
- 诊断列表不够像问题导航器。
- 服务管理入口更像“打开另一个界面”，不是当前面板的连续延伸。

## 设计目标

- 将 WorkbenchLSPPanelView 从 WorkbenchSidebarView 拆出到独立文件。
- 在当前 panel 中直接展示诊断列表与服务管理列表，不再依赖 popover。
- 保持与现有 Workbench 玻璃质感、圆角分区、紧凑侧栏节奏一致。
- 提升信息密度，但避免过度拥挤，符合 Apple 的可扫描性和层级清晰原则。
- 让高频动作可以在一屏内完成，减少状态跳转。
- 为未来增加更多诊断筛选、日志查看、文件跳转预留结构空间。

## 非目标

- 本次不重做 ClaudeService 或 LSP 状态计算逻辑。
- 本次不引入新的后台刷新机制。
- 本次不扩展成完整 IDE 级 Problems 面板。
- 本次不改造设置窗口中的 LSP 管理配置体系，只在 Workbench 内做面板级重排与轻量操作整合。

## 设计依据与优秀产品借鉴

本次设计不复制某个竞品的具体外观，而是吸收几类成熟产品的信息组织方式。

### 1. Xcode Issue Navigator

可借鉴点：

- 错误与警告直接列出，而不是先给一个摘要再点进去。
- 列表项强调严重级别、文件位置、消息文本三件事。
- 当前状态和问题列表是连续信息流，不被弹层打断。

对应到本设计：诊断区应直接以内联列表呈现最近问题，而不是只保留一个摘要条目。

### 2. macOS Settings

可借鉴点：

- 分组列表的层级清晰，标题、说明文、控件区有稳定节奏。
- 低频配置通过 DisclosureGroup 或分区展开，而不是开新窗口。

对应到本设计：服务管理应以内联 section 展示服务行，并允许展开查看详细状态和日志片段。

### 3. GitHub Desktop 与专业开发工具侧边栏

可借鉴点：

- 顶部显示稳定的仓库或环境摘要。
- 中部呈现“可处理的对象列表”。
- 每一行既能快速阅读状态，也能就地执行动作。

对应到本设计：LSP 面板应形成“状态摘要 -> 诊断列表 -> 服务列表”的顺序，而不是卡片里再打开卡片。

## 可选方案对比

### 方案 A：保留现有卡片，只把 popover 改成 sheet 或独立窗口

优点：

- 改动最小。
- 复用现有详情视图成本低。

缺点：

- 根因没有解决，详情依旧脱离主面板。
- sheet 或独立窗口对侧栏任务来说更重。
- 用户仍需跨 surface 理解上下文。

结论：不推荐。

### 方案 B：改成单个大 List，状态、诊断、服务全部做成 section

优点：

- 最符合 macOS 列表范式。
- 可天然获得 section、row、分隔线和键盘导航。

缺点：

- 当前 Workbench 其他 panel 主要是 ScrollView + glass section 语言，纯 List 会显得风格跳脱。
- List 在窄侧栏中对复杂自定义 row 和玻璃材质的控制略生硬。

结论：可以实现，但不是最适合当前应用整体风格的方案。

### 方案 C：保留 glass section 外壳，在 section 内采用列表式 row 组织

优点：

- 兼容当前 Workbench 的视觉语言。
- 可以获得类似系统分组列表的扫描体验。
- 行级交互和扩展区更容易定制。

缺点：

- 需要自己维护 row 分隔和展开状态。
- 比直接套 List 多一点视图工作。

结论：推荐。

## 推荐方案

采用方案 C。

整体结构保留当前面板的纵向滚动容器与 glass 分区，但每个分区内部改成更强的信息列表结构：

1. Overview Section：展示当前工作区、绑定服务、运行状态、当前文件和诊断摘要。
2. Diagnostics Section：直接展示诊断计数、受影响文件数、最近更新时间，以及最近诊断列表。
3. Services Section：直接展示服务列表，每个服务项可以就地执行操作，并通过展开区查看版本、路径、最后错误、安装日志片段。

这样既保留 agentGui 当前 Workbench 的材质和卡片节奏，也让内容组织更像一个专业工具面板。

## 新的信息架构

### 1. Overview Section

用途：回答“当前 LSP 对这个工作区和当前文件到底处于什么状态”。

显示内容：

- 标题：LSP。
- 主状态行：服务名或未绑定状态 + 状态 badge。
- 次级信息：当前文件、工作目录。
- 诊断摘要：错误数、警告数、受影响文件数。

交互要求：

- 若当前未选择文件，状态文案明确显示“选择文件以查看状态”。
- 若当前工作目录为空或 LSP 被禁用，展示系统风格的次要说明，不把错误伪装成可操作状态。

### 2. Diagnostics Section

用途：把“问题是否存在、问题是什么、最近影响到哪里”直接暴露给用户。

显示内容：

- section header：诊断。
- 概览行：错误、警告、信息、提示的 compact badges。当前模型已提供错误和警告，信息和提示若数据缺失可以先不显示。
- 元信息行：受影响文件数、最近更新时间。
- 列表主体：最近诊断 items，默认显示 5 到 8 条，按最近顺序排列。

单个诊断行建议包含：

- 严重级别圆点和文案。
- 文件名。
- 主消息，最多两行。
- 次要元信息，例如 source、line、column。

空态建议：

- 没有诊断时显示一个低强调度的空态行，而不是留空。
- 文案应简短，例如“当前项目没有诊断信息”。

### 3. Services Section

用途：让用户不离开 panel 就能知道服务安装状态、运行状态，并直接执行常用操作。

显示内容：

- section header：服务管理。
- 辅助说明：一句话说明这是当前工作区可用服务列表。
- 服务列表：每个 provider 一行摘要，点击后展开详细区。

服务摘要行建议包含：

- 服务名。
- 支持语言摘要。
- 安装状态。
- 运行状态。
- 行尾动作区，优先展示 1 到 2 个主动作，其余进菜单或折叠后展示。

服务展开区建议包含：

- 版本。
- 可执行文件路径。
- 最近失败原因。
- 安装日志片段，默认截断显示。
- 补充动作，例如 repair、recheck。

操作原则：

- 主动作优先级取决于当前状态，例如未安装优先显示安装，运行中优先显示停止或重启。
- 正在执行操作时，行内呈现 busy 状态，不冻结整个 panel。

## 视觉与交互设计

### 1. 总体视觉方向

采用“紧凑工具面板”而不是“营销型卡片”。

具体原则：

- 延续现有 glassEffect section 容器。
- section 内部使用更接近 grouped list 的 row 节奏。
- 标题层级克制，避免 oversized heading。
- 使用语义色表达状态，不引入新的品牌色体系。

### 2. 状态表现

状态文本继续复用现有 tone 逻辑，但表现形式升级为更清晰的 badge：

- positive：绿色低饱和 badge。
- warning：橙色低饱和 badge。
- negative：红色低饱和 badge。
- neutral：次要灰色 badge。

badge 应保持紧凑，不应喧宾夺主。

### 3. 行设计

诊断行与服务行都应遵守同一套 row 规则：

- 左侧固定状态图标或圆点。
- 中间主信息两层：标题 + 次信息。
- 右侧放数量、时间或动作。
- hover 时仅做轻微背景提亮，不做大幅缩放。

这会比当前用多个独立小块更像系统工具界面。

### 4. 展开机制

服务列表采用 inline expand，而不是 popover。

原因：

- 展开内容与摘要保持垂直邻接，更利于理解。
- 操作后状态更新在原地发生，反馈更明确。
- 更符合 macOS 侧栏中的 DisclosureGroup 使用习惯。

### 5. 打开设置的位置

“打开设置”保留，但降级为 Services Section 的次级动作入口，不再与“服务管理”并列成两个一级按钮。

这样更符合用户心智：

- Workbench panel 负责当前工作区即时操作。
- Settings 负责全局和高级配置。

## 组件拆分建议

### 文件拆分

建议新增以下文件：

- agentGui/Views/Workbench/WorkbenchLSPPanelView.swift

建议从 WorkbenchSidebarView 中移出：

- WorkbenchLSPPanelView
- 与它强耦合的私有 section / row 视图
- 相关的本地辅助展示方法

WorkbenchSidebarView 保留的职责应只剩：

- navigationBar
- currentPanelContainer
- panelView(for:)
- sidebar navigation button

### 视图层建议结构

WorkbenchLSPPanelView.swift 内建议拆成以下子视图或私有组件：

- WorkbenchLSPPanelView
- WorkbenchLSPOverviewSection
- WorkbenchLSPDiagnosticsSection
- WorkbenchLSPDiagnosticRow
- WorkbenchLSPServicesSection
- WorkbenchLSPServiceRow
- WorkbenchLSPServiceDetail
- WorkbenchLSPStatusBadge

是否全部抽成独立类型，取决于最终代码体量；但至少应把 panel 主体、诊断 row、服务 row 分开，避免再次回到单文件大段私有函数。

### 现有视图的处理策略

LSPDiagnosticsPopoverView 和 LSPManagementPopoverView 有两个可选去向：

1. 若重设计完成后已无复用场景，直接删除。
2. 若短期还要保留给其他入口复用，则保留其 presentation model，但 Workbench 内不再使用它们。

当前更推荐第一种，前提是确认没有其他调用方。

## 数据与状态复用策略

本次不建议重写 presenter，只建议把已有能力重新组合。

可直接复用：

- WorkspacePanelLSPFooterPresenter.status(...)
- WorkspacePanelLSPFooterPresenter.managementViewModel(...)
- LSPStatusPresentationTone
- LSPDiagnosticRowPresentation
- LSPManagementViewModel

建议新增轻量展示模型，用于让 inline 列表更稳定：

- WorkbenchLSPOverviewPresentation
- WorkbenchLSPDiagnosticsPresentation
- WorkbenchLSPServiceRowPresentation

是否一定新增这些 presentation struct，取决于最终视图复杂度。若当前实现保持简单，也可以先在 view 内组合，只要不把复杂逻辑堆回 body。

## 交互细节建议

### 1. 诊断列表默认全展开

原因：

- 诊断本身就是这块面板的主要价值之一。
- 用户进入 LSP panel 的主要动机通常是查看问题，而不是只看摘要。

若后续发现列表过长，可增加“显示更多”行，而不是默认藏起来。

### 2. 服务列表默认收起详情

原因：

- 服务详情是次级信息。
- 安装日志和路径等内容不适合一上来全部展开。

默认只展示摘要行，点击后再显示详情，更符合扫描节奏。

### 3. 操作反馈

行内操作执行时建议：

- 用 ProgressView 或状态文案占据行尾区域。
- 禁用当前服务行的重复动作。
- 不阻断其他服务行的浏览。

### 4. 错误反馈

当前 actionError 是整段文字放在 section 底部。建议升级为：

- 服务行内错误优先在对应展开区展示。
- 面板级错误保留在 section footer 或顶部辅助提示中。

这样用户更容易知道是哪一个服务失败。

## Apple 设计规范对齐点

本次重设计应明确遵守以下原则：

- 使用分组 section 与稳定 row 节奏，而不是无边界卡片堆叠。
- 使用语义色和系统字号，避免人为放大视觉对比。
- 当前上下文相关动作保留在当前面板内，减少无必要弹层。
- 高频信息直接可见，低频或高级信息通过展开显露。
- 每个 row 的主标题、次标题、辅助状态和动作位置保持一致。
- 空态、禁用态、错误态都给出可理解文案，不只用颜色表达。

## 实施步骤建议

### 第一阶段：纯结构拆分

- 新建 WorkbenchLSPPanelView.swift。
- 从 WorkbenchSidebarView 移出 WorkbenchLSPPanelView。
- 保持现有 UI 不变，先确认编译与引用关系稳定。

### 第二阶段：移除 popover 依赖

- 删除 showsLSPDiagnosticsPopover 与 showsLSPManagementPopover 本地状态。
- 把诊断详情和服务管理内容直接并入 panel。
- 让“打开设置”变成内联次级动作。

### 第三阶段：列表化与视觉统一

- 重构 diagnosticsSection 为真正的 row list。
- 重构 managementSection 为服务摘要行 + 展开详情行。
- 调整 section header、badge、row spacing、hover 与 action 布局。

### 第四阶段：收尾与清理

- 视情况删除不再使用的 popover 视图。
- 补充或更新预览、UI 测试或快照基线。
- 检查窄宽度下的截断、滚动和 hover 行为。

## 测试与验证建议

至少覆盖以下场景：

- 无工作目录。
- 未选择文件。
- 当前文件无匹配服务。
- 服务未安装。
- 服务运行中。
- 服务启动失败或崩溃。
- 有诊断且 recentDiagnostics 为空和非空两种情况。
- 诊断数量较多时的滚动与截断。
- 正在执行安装或重检操作时的 busy UI。

若要补测试，优先级建议是：

1. presenter 与 management view model 的行为测试继续复用现有单元测试体系。
2. 新 panel 的 UI smoke 或 snapshot 验证 section 与空态。
3. 必要时补 accessibility identifier，保证后续 UI 自动化可定位 row 和 action。

## 风险与注意事项

- 若直接复用设置页里的 LSPManagementSectionView，可能会把“设置表单”的视觉语言带进 Workbench，造成风格不统一。建议复用行为模型，不直接照搬表单视图。
- 若诊断列表行数不受控，侧栏会快速变长。建议首版限制默认条数，并预留“更多”入口。
- 若服务行动作放得过多，会在窄侧栏中出现按钮拥挤。建议按状态只露出 1 到 2 个主动作。
- 若继续在 view body 内临时创建过多对象，后续维护性会下降。拆分文件时应顺带压缩 WorkbenchSidebarView 的职责。

## 结论

本次 Workbench LSP 面板重构，推荐采用“独立文件 + glass section 外壳 + section 内列表式内容”的方案。

这比继续使用 popover 更符合 LSP 作为持续观察与轻量管理工具的定位，也更符合 macOS 工具型应用在侧栏中的信息组织方式。拆分完成后，WorkbenchSidebarView 将回到容器职责；LSP 面板则成为一个可以独立演进的工作台模块。

如果进入实现阶段，建议先完成结构拆分，再替换交互，不要把“拆文件”和“重设计”混成一次大改，以降低回归风险。