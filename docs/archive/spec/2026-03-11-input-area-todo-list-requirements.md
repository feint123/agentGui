# InputArea TodoList 内联卡片需求文档

日期：2026-03-11

关联对象：`ChatView+InputArea`、`TodoListView`、`WorkspacePanelView`、`ClaudeService.sessionTodoLists`、`SessionTaskStateStore`

## 1. 背景

当前 TodoList 的展示位置在左侧 `WorkspacePanelView` 中，与以下内容共享侧栏空间：

- 工作目录栏
- GitPanel
- 文件树

这带来两个明显问题：

- TodoList 与当前输入动作距离较远。用户在发送下一条消息前，无法自然地把“当前计划”和“当前输入”放在同一视觉焦点里。
- 侧栏已经承担目录浏览和 Git 摘要，TodoList 继续占用该区域，会进一步压缩文件树可用空间。

与此同时，`ChatView+InputArea` 已经存在成熟的近输入区浮层模式：

- `slashPopupCard`
- `mentionPopupCard`

这类卡片的优点是：

- 与输入动作距离近
- 反馈及时
- 视觉权重可控
- 不需要额外切换视线到侧栏

因此，本次需求要把 TodoList 从侧栏迁移到输入区附近，成为一个类似 `slashPopupCard` 的轻量内联卡片，而不是继续留在 `WorkspacePanelView`。

## 2. 目标

本次需求的核心目标是：

> 将当前会话的 TodoList 从侧栏迁移到 `inputArea`，以近输入区浮层卡片的方式展示，让用户在编排下一步输入时可以直接参考当前任务列表。

完成后应达到以下结果：

- TodoList 不再占用侧栏主空间
- 用户在输入区即可看到当前会话任务进展
- TodoList 的视觉形态与 `slashPopupCard` 保持同一交互家族
- TodoList 不抢占输入主流程，在需要时可见，在不需要时保持轻量
- `slash`、`@mention`、TodoList 三类输入辅助面板的优先级清晰，不产生叠层混乱

## 3. 设计结论

本次需求的明确结论如下：

- TodoList 的主展示位置从 `WorkspacePanelView` 移到 `ChatView.inputArea`
- TodoList 使用类似 `slashPopupCard` 的浮层卡片样式，而不是继续用侧栏 `DisclosureGroup` 结构
- TodoList 的数据来源不变，仍然优先使用 `SessionTaskStateStore` 的持久化结果，并回退到 `claudeService.sessionTodoLists`
- 输入辅助浮层同一时刻只保留一个主卡片区域，避免 `slashPopupCard`、`mentionPopupCard`、TodoList 卡片同时竞争视觉焦点

## 4. 设计原则

### 4.1 输入优先

TodoList 迁移到输入区的目的，不是做一个新的常驻面板，而是服务“当前输入前的任务确认”。因此它必须围绕输入动作存在。

### 4.2 轻量而可扫读

TodoList 卡片应该让用户在 1 到 2 秒内看清：

- 当前还有多少未完成项
- 当前正在进行哪一项
- 下一条消息应该继续推进什么

不应为了保留旧侧栏样式而把它做成一个高密度、长滚动、长期展开的列表面板。

### 4.3 与现有浮层家族一致

TodoList 卡片应与 `slashPopupCard`、`mentionPopupCard` 属于同一种交互家族：

- 出现在输入框上方
- 视觉上是悬浮卡片而非主布局块
- 支持平滑出现/隐藏
- 在主输入区域附近完成浏览与选择

### 4.4 单焦点规则

输入区同一时刻只能有一个主要辅助焦点。若 `slash` 或 `@mention` 已经激活，TodoList 卡片应让位，而不是与其并排或叠层共存。

## 5. 现状问题

### 5.1 侧栏位置不合适

- TodoList 与输入行为割裂
- 侧栏主任务是文件浏览，不适合承载持续任务规划提示
- TodoList 会进一步挤压文件树浏览高度

### 5.2 展示样式不匹配当前使用场景

当前 `TodoListView` 是一个 `DisclosureGroup`：

- 更像“面板中的一个折叠区块”
- 不像“输入前的轻量参考卡片”
- 与 `slashPopupCard` 的交互语言不一致

### 5.3 输入辅助面板缺少统一编排

当前 `inputArea` 已有：

- slash 命令建议
- mention 文件建议

但 TodoList 仍在输入区之外，导致“输入辅助信息”被拆散在两个区域，用户需要来回移动视线。

## 6. 范围定义

### 6.1 在本次范围内

- 将 TodoList 的主展示位置迁移到 `inputArea`
- 设计一个类似 `slashPopupCard` 的 Todo 卡片
- 定义 Todo 卡片的显示时机、隐藏时机、优先级和尺寸约束
- 从 `WorkspacePanelView` 中移除 TodoList 展示
- 保持现有 Todo 数据读取逻辑不变

### 6.2 不在本次范围

- 不新增 Todo 编辑能力
- 不新增手动勾选、拖拽排序、批量操作
- 不改变 `update_todo_list` 工具的数据结构
- 不改造 Todo 持久化模型
- 不把 TodoList 做成完整任务中心或独立标签页

## 7. 功能需求

### 7.1 展示位置

TodoList 卡片应出现在 `ChatView.inputArea` 上方，位置与 `slashPopupCard`、`mentionPopupCard` 一致或同层。

推荐结构：

- 上方：输入辅助卡片区
- 下方：输入框主体

TodoList 卡片不应插入到消息列表中，也不应继续停留在 `WorkspacePanelView` 侧栏内。

### 7.2 显示时机

TodoList 卡片应在以下条件满足时显示：

- 当前存在选中会话
- 当前会话存在非空 TodoItems
- 当前没有激活更高优先级的输入辅助卡片

其中更高优先级卡片为：

1. `slashPopupCard`
2. `mentionPopupCard`

TodoList 卡片默认优先级低于这两类即时输入建议。

### 7.3 隐藏时机

TodoList 卡片应在以下场景隐藏：

- 当前会话无 TodoItems
- 用户进入 slash 命令选择态
- 用户进入 mention 文件选择态
- 用户切换到没有 Todo 的会话

本次不强制要求用户手动关闭后“永久隐藏”，但要为后续支持“折叠/收起”预留空间。

### 7.4 卡片内容

TodoList 卡片至少应展示以下信息：

- 标题，例如“任务列表”或“当前计划”
- 进度摘要，例如 `2/5`
- 若干条 Todo 项
- 当前状态标识：pending / in-progress / done / cancelled

其中内容层级应做轻量化处理：

- 优先保证标题和进度摘要易读
- 列表项不应过高密度
- notes 若展示，应弱化为辅助文本

### 7.5 列表项展示策略

Todo 卡片中的列表项应服务于“快速扫读”，而不是完整任务管理。

建议要求：

- 默认显示有限数量的任务项，例如最近或最关键的前若干项
- 超出上限时允许内部滚动，或提供“还有 N 项”提示
- `in-progress` 项视觉上应高于其他项
- `done` 项可继续显示，但应明显弱化

### 7.6 与旧 TodoListView 的关系

当前 `TodoListView` 是侧栏专用样式，不应直接原样搬入 `inputArea`。

本次应明确区分：

- 旧侧栏版 TodoList 作为旧布局实现被移除或不再作为主入口
- 新输入区版 Todo 卡片应针对浮层场景重新定义视觉与尺寸策略

是否复用部分行视图，可以作为实现细节处理，但需求层面不要求保留 `DisclosureGroup` 交互。

## 8. 交互需求

### 8.1 与 slashPopupCard 的关系

TodoList 卡片的视觉语言应接近 `slashPopupCard`，包括但不限于：

- 圆角卡片容器
- material 背景
- 浮层阴影
- 输入区上方弹出
- 平滑的 `opacity + scale` 过渡

但 TodoList 卡片不是命令选择器，不应强行复用 slash 行为，例如：

- 不需要键盘高亮选择模型
- 不需要按上下方向键切换候选
- 不需要 `Enter` 提交某一项

### 8.2 同层优先级

输入辅助区的优先级应为：

1. slash 命令建议
2. mention 文件建议
3. TodoList 卡片

同一时刻不应显示多个主卡片。尤其不能出现：

- slash 卡片和 TodoList 同时堆叠
- mention 卡片覆盖 TodoList 一部分
- TodoList 把输入框向下挤压到明显影响打字区域

### 8.3 会话切换联动

当用户切换会话时，TodoList 卡片应立即跟随当前会话数据刷新：

- 有 Todo 的会话显示卡片
- 无 Todo 的会话不显示卡片
- 不允许出现上一会话 Todo 残留在当前输入区

### 8.4 流式更新联动

当 agent 通过 `update_todo_list` 更新当前会话 Todo 状态时，TodoList 卡片应自动刷新，而不需要用户重新切换会话或手动展开侧栏。

## 9. 布局需求

### 9.1 输入区结构

迁移后，输入区结构应调整为：

- 输入辅助卡片区
- 输入框容器
- 底部上下文使用环等附属信息

TodoList 卡片应属于输入辅助卡片区，而不是输入框容器内部的正文内容。

### 9.2 高度约束

TodoList 卡片应为轻量区块，不得无限增高。

要求：

- 小窗口下仍要优先保证输入框高度可用
- Todo 卡片需要有明确最大高度策略
- 超出部分应内部滚动或摘要化，而不是持续推高整体输入区

### 9.3 宽度与边距

TodoList 卡片应与 `slashPopupCard` 对齐：

- 水平边距与输入框主体保持一致
- 不应单独做成全宽页眉式条带
- 不应脱离输入框区域独立漂浮到消息列表中

## 10. 数据与状态要求

### 10.1 数据来源

TodoList 卡片继续沿用当前会话级 Todo 数据源：

- 优先读取 `SessionTaskStateStore`
- 若持久化结果为空，则回退到 `claudeService.sessionTodoLists[sessionId]`

本次不改变写入路径。

### 10.2 状态同步

需要保证以下状态同步成立：

- 当前会话变化时，Todo 卡片同步变化
- Todo 数据变化时，卡片实时刷新
- 输入辅助态变化时，Todo 卡片按优先级让位或恢复

### 10.3 空状态

无 TodoItems 时，不显示占位卡片。

本次不要求在输入区显示“暂无任务列表”的空卡片，因为这会增加无效视觉噪音。

## 11. 验收标准

### 11.1 位置验收

- TodoList 不再显示在 `WorkspacePanelView` 侧栏中
- TodoList 出现在 `inputArea` 上方辅助卡片区

### 11.2 交互验收

- 当前会话存在 Todo 时，输入区可见 Todo 卡片
- 激活 slash 命令时，Todo 卡片让位给 `slashPopupCard`
- 激活 mention 建议时，Todo 卡片让位给 `mentionPopupCard`
- 退出 slash / mention 态后，若当前会话仍有 Todo，则 Todo 卡片恢复显示

### 11.3 布局验收

- Todo 卡片不会明显压缩输入框可用区域
- 小窗口下输入区仍可正常打字与发送
- Todo 卡片样式与 `slashPopupCard` 保持同一交互家族

### 11.4 数据验收

- 会话切换后 Todo 卡片内容立即跟随切换
- `update_todo_list` 更新后卡片自动刷新
- 不出现旧会话 Todo 残留或数据延迟错位

## 12. 优先级

- P0：把 TodoList 从侧栏迁到 inputArea，并建立与 slash/mention 的优先级规则
- P1：控制 Todo 卡片高度与摘要策略，避免输入区拥挤
- P2：再评估是否需要支持手动折叠、更多项展开或点击跳转等增强交互

## 13. 后续扩展方向

本次完成后，后续可以按需要再评估：

1. Todo 卡片手动折叠/展开
2. 仅显示进行中项和未完成项
3. 点击某项后将其注入输入上下文
4. 基于当前 Todo 高亮推荐下一条 slash 命令或执行建议

但这些都不属于本次范围。本次的重点只有一个：

> 把 TodoList 从侧栏挪到输入区附近，让它成为类似 `slashPopupCard` 的轻量输入辅助卡片。