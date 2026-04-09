# BlockDocumentEditor 交互缺陷修复文档

## 文档信息

- 日期：2026-03-29
- 状态：待修复
- 范围：`BlockDocumentEditor`、`BlockRowView`、`BlockTableEditor`、块级多选与表格单元格交互

## 一、问题概览

本次评审聚焦 `BlockDocumentEditor` 的三个交互缺陷：

1. block 无法稳定进入编辑状态。
2. 表格中的文字无法进行原生 selection。
3. multi block selection 的可触发区域过大，侵占正文交互。

结论不是“某个手势写错了”，而是当前块编辑器把三类本应分离的交互混在了一起：

1. 容器级块选择。
2. `NSTextView`/表格单元格的原生文本交互。
3. 画布级 marquee 多选。

现状中这三者分别挂在 `List` 容器、整行 `onTapGesture` 和全局 `DragGesture` 上，导致命中优先级错误，最终表现为“点击像是选块，不像是进编辑”“表格像按钮，不像文本控件”“拖拽像框选，不像选字”。

相关代码位置：

1. [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift)
2. [agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift](agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift)
3. [agentGui/Views/Editor/BlockRowView.swift](agentGui/Views/Editor/BlockRowView.swift)
4. [agentGui/Views/Editor/BlockTableEditor.swift](agentGui/Views/Editor/BlockTableEditor.swift)
5. [docs/spec/2026-03-22-block-document-editor-multi-select-requirements.md](docs/spec/2026-03-22-block-document-editor-multi-select-requirements.md)

## 二、现状评审结论

### 1. P0: block 编辑入口被整行块选择手势抢占

`BlockRowView` 当前把整行都包进 `.onTapGesture { onBlockTap?() }`，而 `BlockDocumentEditor` 收到 `onBlockTap` 后会立即走 `handleBlockTap(_:)`，更新块级 selection、清空 inline selection、清掉 focus，并重新激活块选择命令响应器。见：

1. [agentGui/Views/Editor/BlockRowView.swift](agentGui/Views/Editor/BlockRowView.swift)
2. [agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift](agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift)

这意味着正文区域的单击并没有和“块选择入口”解耦。对用户来说，正文点击应该优先尝试把对应 `NSTextView` 变成 first responder，而不是先进入块级单选。

### 2. P0: 表格单元格在未聚焦态退化成 Button，天然失去文本选择能力

`BlockTableEditor` 当前使用 residency 策略，只保留一个 mounted editor。未 mounted 的单元格并不是只读 `NSTextView`，而是一个 `Button`。同时 cell 容器外层还额外挂了 `.onTapGesture { activateCell(cellID) }`。见：

1. [agentGui/Views/Editor/BlockTableEditor.swift](agentGui/Views/Editor/BlockTableEditor.swift)

这个设计的直接后果是：

1. 鼠标拖拽先命中 Button，而不是文本系统。
2. 未聚焦单元格不存在可拖选的原生文本视图。
3. residency 只有 1 个 mounted editor，使跨单元格或重复点选时的 selection 语义不断丢失。

### 3. P0: marquee 多选挂在整个 List 画布，触发面过宽

`BlockDocumentEditor` 把 `marqueeGesture` 直接挂在整个 `List` 容器上；同时块行本身也没有独立的 selection rail 或空白区入口。见：

1. [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift)
2. [agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift](agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift)

这和需求文档里“框选仅允许从块左侧选择带、块间空隙或编辑器留白区域发起；正文区域保留原生文本选中”的约束不一致。结果是正文拖拽、表格拖拽、块级框选都在竞争同一块命中面。

### 4. P1: `List` 作为交互画布放大了命中与手势冲突

当前编辑器滚动容器仍是 `List`。这对简单展示无害，但对需要区分 selection rail、正文编辑区、表格、拖拽框选、块重排的复合编辑器并不理想。已有仓库备注也已经明确：`List` 不适合作为块编辑器交互画布。见：

1. [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift)
2. [docs/spec/2026-03-22-block-document-editor-multi-select-requirements.md](docs/spec/2026-03-22-block-document-editor-multi-select-requirements.md)

本轮修复不要求立即把 `List` 整体替换掉，但需要先把交互入口与正文区域隔离，否则同类问题会反复出现。

## 三、修复原则

1. 块级选择入口与正文编辑入口必须分离。
2. 文本输入与文本 selection 优先于块级单选和 marquee。
3. 表格单元格始终保留原生文本视图，只在可编辑性上切换，不再退化为 Button。
4. marquee 只能从明确的选择热区发起，不能挂在整个正文画布上抢拖拽。
5. 命令响应器不能在文本视图重新获焦后抢回 first responder。

## 四、Feature 拆分

### Feature 1：块正文编辑入口修复

#### 目标

让普通文本块、标题块、列表块在正文区域点击后稳定进入编辑态；块级单选仅由明确的块选择热区触发。

#### 问题根因

1. `BlockRowView` 把整行容器都当成块选择命中面。
2. `handleBlockTap(_:)` 一旦触发，会清掉 inline selection、focus 和 responder。
3. 当前没有单独的 selection rail，正文区域只能和块选择共享命中面。

#### 修复方案

1. 在 `BlockRowView` 中引入明确的块选择热区，建议使用左侧 rail 或 drag handle 邻近区域，而不是整行 `.onTapGesture`。
2. 正文内容区不再绑定 `onBlockTap`；正文区点击只负责让对应 `BlockTextEditor` 或只读内容激活后进入编辑态。
3. `onReadOnlyActivate` 继续承担从只读内容切到编辑态的职责，但不再与整行块选择手势竞争。
4. `BlockEditorCommandResponder` 只在块级 selection 仍然有效时激活；文本视图获得焦点后不得立即抢回 first responder。

#### 影响文件

1. [agentGui/Views/Editor/BlockRowView.swift](agentGui/Views/Editor/BlockRowView.swift)
2. [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift)
3. [agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift](agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift)
4. [agentGui/Views/Editor/BlockTextEditor.swift](agentGui/Views/Editor/BlockTextEditor.swift)

#### 验收标准

1. 点击正文区域时，block 可直接进入编辑态，光标落点正确。
2. 点击块左侧 selection rail 时，进入块级单选而不是文本编辑。
3. `Command`/`Shift` 块选择仍可用，但不会在正文点击时误触。
4. 文本视图获焦后，块级命令响应器不会抢占 first responder。

#### 测试要求

1. 新增块编辑入口 focused tests，覆盖正文点击、rail 点击、只读态切编辑态。
2. 补 UI 冒烟，覆盖标题、列表、普通段落三类 block。

### Feature 2：表格单元格原生文本选择恢复

#### 目标

让表格单元格在未编辑和已编辑状态下都保持可选字、可拖选、可连续操作的原生文本交互。

#### 问题根因

1. `BlockTableEditor` 仅保留一个 mounted editor。
2. 未 mounted 单元格被渲染成 `Button`，不具备文本系统语义。
3. cell 外层的 `onTapGesture` 会和文本命中叠加，进一步削弱原生 selection。

#### 修复方案

1. 移除“未聚焦时退化为 Button”的模式，所有单元格常驻 `BlockTableCellTextEditor` 或等价的只读/可编辑 `NSTextView`。
2. 将“是否可编辑”与“是否存在文本视图”解耦：未聚焦时可设 `isEditable = false`，但必须保留文本系统以支持 selection。
3. 提升或取消 `BlockTableCellResidency(maxMountedEditors: 1)` 的限制，至少不能让同一张表只有一个真实文本视图常驻。
4. 删除 cell 容器外层与文本视图重复的 `onTapGesture`，避免原生拖选被重新解释成 cell 激活。

#### 影响文件

1. [agentGui/Views/Editor/BlockTableEditor.swift](agentGui/Views/Editor/BlockTableEditor.swift)
2. [agentGui/Views/Editor/BlockRowView.swift](agentGui/Views/Editor/BlockRowView.swift)
3. [agentGui/Views/Editor/BlockTextEditor.swift](agentGui/Views/Editor/BlockTextEditor.swift)

#### 验收标准

1. 表格单元格中的文字可直接拖选，不需要先切进单独编辑模式。
2. 单元格聚焦切换不会导致上一次 selection 异常丢失或闪断。
3. 表格内复制、剪切、键盘移动仍按原生文本控件工作。
4. 表格操作不会误触块级多选或整行块选择。

#### 测试要求

1. 新增 `BlockTableEditor` focused tests，覆盖单元格 selection、聚焦切换、同步 markdown。
2. 增加 UI 冒烟，验证鼠标拖选与复制。

### Feature 3：Multi Block Selection 触发区收口

#### 目标

把 multi block selection 的触发区域收敛到 selection rail、块间空隙或画布留白，避免与正文拖拽和表格交互冲突。

#### 问题根因

1. `marqueeGesture` 挂在整个 `List` 容器上。
2. block row 没有单独的 selection rail 合同，导致正文区域也落在块级手势覆盖范围内。
3. 当前命中策略只看整行 frame 相交，不区分起手区域是否允许进入 marquee。

#### 修复方案

1. 为 `BlockRowView` 增加显式 selection rail / selection hotspot，并把 marquee 起手条件限制在这些区域。
2. 将 `marqueeGesture` 从整个正文画布挪到可控入口，正文 `NSTextView`、表格单元格、资源块内容区不再响应块级 DragGesture。
3. 保留块间空隙和画布留白发起框选的能力，满足空白处也能开始多选的需求。
4. 对 drag reorder handle、selection rail、正文编辑区三类区域建立互斥优先级：重排 > 文本交互 > marquee。

#### 影响文件

1. [agentGui/Views/Editor/BlockDocumentEditor.swift](agentGui/Views/Editor/BlockDocumentEditor.swift)
2. [agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift](agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift)
3. [agentGui/Views/Editor/BlockRowView.swift](agentGui/Views/Editor/BlockRowView.swift)
4. [agentGui/Views/Editor/BlockEditorMarqueeSelectionController.swift](agentGui/Views/Editor/BlockEditorMarqueeSelectionController.swift)
5. [agentGui/Views/Editor/BlockEditorBlockSelectionCoordinator.swift](agentGui/Views/Editor/BlockEditorBlockSelectionCoordinator.swift)

#### 验收标准

1. 从 selection rail 或留白区域拖拽可触发 multi block selection。
2. 从正文文本区域拖拽不会进入 marquee，而是保留原生文字 selection。
3. 从表格单元格拖拽不会触发 marquee。
4. 多选、块重排、正文编辑三者之间命中优先级稳定，不出现误触。

#### 测试要求

1. 新增 marquee 入口 focused tests，覆盖 rail 起手、留白起手、正文拖拽不框选。
2. 保留现有多选测试，并增加表格/正文冲突回归场景。

## 五、推荐实施顺序

1. 先做 Feature 2。
原因：表格单元格退化成 Button 是最明确的错误状态，且会持续吞掉文本交互。
2. 再做 Feature 1。
原因：块正文点击进入编辑态需要在块级选择入口收口后才能稳定成立。
3. 最后做 Feature 3。
原因：多块选择的起手区需要在正文和表格交互边界稳定后再收口，否则容易边改边回归。

## 六、测试与回归矩阵

### Focused Tests

1. block 正文点击进入编辑态。
2. rail 点击触发块级单选。
3. 表格单元格拖选文本。
4. 正文拖拽不触发 marquee。
5. 留白区域拖拽可触发 marquee。

### Manual Smoke

1. 段落块点击后直接输入。
2. 列表块点击后直接输入。
3. 表格内拖选复制文本。
4. `Command + 点击` 多选多个 block。
5. 从 rail 框选多个 block。
6. 在表格中拖拽时不会误出现块级框选高亮。

## 七、风险与注意事项

1. 如果继续保留整行 `onTapGesture`，Feature 1 和 Feature 3 会互相打架，无法真正收口。
2. 如果表格仍然保留 Button 占位态，任何“支持表格 selection”的补丁都只是表象修复。
3. 如果 marquee 仍挂在整个 `List` 上，即使加了更多判断，正文区域也会继续受手势竞争影响。
4. 若后续继续扩展块编辑器交互，建议评估把 `List` 替换成更可控的 `ScrollView + LazyVStack` 画布；本轮可不做，但要避免再把复杂交互叠加到 `List` 语义上。

## 八、结论

这三个问题本质上不是独立 bug，而是同一个交互边界问题的三个外显症状：

1. 块选择入口过宽。
2. 文本系统未被保留为第一优先级。
3. 画布级手势越过了 selection rail 与正文区域的边界。

因此修复也必须按 Feature 收敛边界，而不是继续在现有整行手势和 Button 占位模型上打补丁。