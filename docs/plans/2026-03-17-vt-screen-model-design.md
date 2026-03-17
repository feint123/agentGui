# 2026-03-17 VT Screen Model 设计方案

日期：2026-03-17

目标：为未知 TUI 建立一个真正的 VT screen model，替换当前基于 transcript 行文本的 `TerminalSurfaceExtractor`，让终端交互理解建立在“屏幕状态”而不是“字符猜测”之上。

关联对象：

1. `TerminalTaskRuntime`
2. `PtyProcessController`
3. `TerminalSurfaceExtractor`
4. `AgentLoopToolExecutionCoordinatorBuilder`
5. `TerminalInteractionPlanner`
6. 终端任务 UI 与 `ToolCall`

关联文档：

1. `docs/technical-spec/2026-03-16-bash-interactive-orchestration.md`
2. `docs/bash tool.md`

---

## 1. 结论先行

当前 `TerminalSurfaceExtractor` 的问题不是“规则还不够多”，而是输入抽象层级错了。

像 `create-vue`、`create-next-app`、`npm init` 一类现代 CLI，普遍基于 Clack、Enquirer、Ink、Prompts、Inquirer 或自研渲染层，通过 ANSI 控制序列反复重绘当前屏幕。PTY transcript 只是这些重绘动作的线性历史，不是最终屏幕状态。

因此，对于未知 TUI，长期正确方案应是：

1. 先解析 VT 控制序列。
2. 再维护主屏/备用屏、光标、属性、滚动区域等真实 screen state。
3. 最后从 screen state 投影出交互语义，如单选、多选、文本输入、确认对话框。

推荐架构不是继续增强 `TerminalSurfaceExtractor`，而是把它拆成三层：

1. `TerminalVTParser`：解析字节流和控制序列。
2. `TerminalScreenModel`：维护可查询的屏幕缓冲区。
3. `TerminalSurfaceProjector`：把屏幕状态转换成现有 `TerminalSurfaceSnapshot` 或其后继模型。

这意味着当前 `TerminalSurfaceExtractor` 应直接移除，不保留兼容层，不再承担任何主路径职责。

## 2. 为什么 transcript extractor 天然不稳

当前方案把终端看成“最后若干行字符串”，然后试图从这些字符串里找：

1. 可见选项。
2. 当前焦点。
3. 已选状态。
4. 提示语。

这在普通 shell prompt 上还能工作，但对重绘式 TUI 有三个结构性缺陷：

1. 同一个逻辑控件会被多次擦除、重画、移动，transcript 中既包含当前状态，也包含过时状态。
2. 光标定位、清屏、行擦除等行为不会自然映射成“新的一行文本”，所以 transcript 看到的往往是打散后的字符序列。
3. 一些关键语义根本不在字符内容里，而在位置、样式、光标和 buffer 切换上。

最新的 `create-vue` 日志已经证明了这一点：`◆  Target directory ...` 这种屏幕在 transcript 里既可能变成一条 prompt，也可能被拆成竖排字符，还可能把前面的 `> npx` 当成选项。问题不在某一条规则，而在整个输入模型本身无法区分“shell 历史”和“当前屏幕”。

所以长期方案必须把“当前屏幕”变成一等数据模型，而不是从历史文本里倒推。

## 3. 设计目标

这个 VT screen model 的目标应当严格限制在“支持终端交互理解”，而不是实现一个完整终端模拟器产品。

建议目标：

1. 正确维护 primary screen 与 alternate screen。
2. 正确处理 cursor move、erase、insert、scroll、SGR 样式等常见 TUI 所依赖的序列。
3. 在任意时刻导出稳定的 `ScreenSnapshot`。
4. 在 snapshot 之上识别常见控件模式，如单选、多选、确认框、文本输入。
5. 与现有 planner/approval/takeover 体系兼容。

明确非目标：

1. 不追求完整实现 xterm 全部 DEC 私有扩展。
2. 不在第一版支持鼠标事件、图像协议、六字体切换等高级功能。
3. 不尝试让 unknown TUI 在第一版就实现全自动操作。
4. 不用它替代已知脚手架的非交互 adapter。

也就是说，这个 screen model 是未知 TUI 的基础设施，不是“所有交互都必须走 TUI 理解”的唯一方案。

## 4. 备选路线与推荐方案

### 4.1 方案 A：继续增强 transcript extractor

做法：继续在 `TerminalSurfaceExtractor` 上增加字符拼接、选项识别、prompt 模式库和更多特殊规则。

优点：

1. 改动小。
2. 短期能修一些已知问题。

缺点：

1. 输入不稳定，规则再多也仍然建立在错误抽象上。
2. 每支持一个新 TUI，都会引入新的例外处理。
3. 容易和 `BashPromptAnalyzer` 职责重叠。

结论：不推荐作为长期方案，应被直接替换，而不是继续保留。

### 4.2 方案 B：自研最小 VT parser + screen buffer

做法：在现有 PTY runtime 内增加一个增量 parser，把字节流实时应用到 screen model，再由 projector 导出交互语义。

优点：

1. 数据模型正确。
2. 与现有 Swift 架构和测试体系兼容。
3. 可以按需求渐进支持序列子集。

缺点：

1. 一次性工程量明显高于继续写 heuristics。
2. 必须认真处理宽字符、换行、自动换行、擦除和 scroll semantics。

结论：这是推荐方案。

### 4.3 方案 C：接入现成 VT 库

做法：引入 `libvterm`、`xterm.js parser` 同类能力，Swift 只包装 screen snapshot 和 projector。

优点：

1. 控制序列正确性更高。
2. 少踩 parser 细节坑。

缺点：

1. 当前仓库是纯 Swift/macOS 应用，引入 C/JS 依赖会显著增加构建与分发复杂度。
2. UI、tests、snapshot 桥接成本不低。

结论：可作为备选，不应是第一落点。除非自研 parser 在两三个迭代后仍无法稳定支撑目标 TUI，否则优先走方案 B。

## 5. 推荐架构

### 5.1 数据流

推荐把当前：

`PTY output -> TerminalSurfaceExtractor -> TerminalSurfaceSnapshot`

替换为：

`PTY bytes -> TerminalVTParser -> TerminalScreenModel -> TerminalSurfaceProjector -> TerminalSurfaceSnapshot`

职责划分：

1. `TerminalVTParser` 只负责解释字节流和控制序列。
2. `TerminalScreenModel` 只负责维护屏幕状态。
3. `TerminalSurfaceProjector` 只负责从当前 screen state 抽取交互语义。
4. `TerminalInteractionPlanner` 只消费 projector 生成的结构化 surface。

这样做的直接好处是：parser 和 projector 的 bug 不再互相污染。现在一条日志里看见的“选项错了”，可能是 strip ANSI、行重组、模式判断任何一步出错；拆层后每一层都能单独测试和观测。

### 5.2 模块建议

建议新增以下组件：

1. `TerminalVTParser`
2. `TerminalVTParserState`
3. `TerminalScreenModel`
4. `TerminalScreenBuffer`
5. `TerminalScreenCell`
6. `TerminalCursorState`
7. `TerminalSurfaceProjector`
8. `TerminalScreenSnapshot`

现有 `TerminalSurfaceExtractor` 应直接删除，所有调用点统一切换到 `TerminalSurfaceProjector` 或新的 `TerminalInteractionSurface` 管线。

## 6. 核心数据模型

### 6.1 `TerminalScreenCell`

单元格应包含：

1. `scalar` 或 grapheme cluster 文本。
2. `displayWidth`。
3. `foregroundColor`。
4. `backgroundColor`。
5. `attributes`，如 bold、dim、inverse、underline。
6. `isContinuationCell`，用于宽字符续位。

重点不是颜色本身，而是保留足够信息给 projector 用。例如一些 prompt framework 会用反色、加粗或符号前缀表达焦点项。

### 6.2 `TerminalScreenBuffer`

建议维护：

1. `width`
2. `height`
3. `lines: [TerminalScreenLine]`
4. `scrollback`
5. `scrollRegion`

同时要区分：

1. `primaryBuffer`
2. `alternateBuffer`
3. `activeBuffer`

因为大量 TUI 会在 alternate screen 中渲染，退出时再回到 shell 主屏。当前 extractor 只看最后几行文本，无法可靠区分这两者。

### 6.3 `TerminalCursorState`

建议字段：

1. `row`
2. `column`
3. `isVisible`
4. `originMode`
5. `wrapPending`

其中 `wrapPending` 很关键，它决定了下一个可打印字符是覆盖当前行末还是先换到下一行，这对 prompt framework 的一行一行重绘有直接影响。

### 6.4 `TerminalScreenSnapshot`

这是 projector 的输入，应包含：

1. 当前 active buffer 的二维 cells。
2. 光标状态。
3. 当前 title、cwd、command line 等 shell integration metadata。
4. active buffer 类型。
5. 最近一次 resize 信息。

这个 snapshot 不直接暴露给 planner，而是先经过 projector 压缩为现有 `TerminalSurfaceSnapshot` 或新的 `TerminalInteractionSurface`。

## 7. Parser 边界与首批支持序列

第一版不需要全量 VT，但必须覆盖现代 Node CLI 常用子集。

建议首批支持：

1. 普通可打印字符与 UTF-8 解码。
2. `CR`、`LF`、`BS`、`TAB`。
3. `ESC` 基本序列。
4. `CSI` cursor move、cursor position、erase in line、erase in display。
5. `CSI SGR` 样式序列。
6. `DECSET/DECRST` 中与 alternate screen 和 cursor visibility 相关的模式。
7. `OSC 633`、`OSC 133`、`OSC 1337` 的 shell integration 子集。

需要优先实现的行为不是“所有颜色都正确”，而是：

1. `create-vue`、Clack、Prompts 一类重绘式表单不会被打散。
2. radio/confirm/select 的当前可见内容在 snapshot 中稳定可读。
3. 退出 alternate screen 后 shell prompt 能回到主屏缓冲区。

## 8. Surface projector 设计

有了 screen model 后，交互理解应从“按行正则”转成“按屏语义投影”。

推荐 projector 输出两类内容：

1. `semanticSurface`
2. `diagnosticSurface`

`semanticSurface` 提供：

1. `interactionType`
2. `promptText`
3. `options`
4. `focusedOption`
5. `selectionState`
6. `inputFieldRange`
7. `isAlternateScreen`

`diagnosticSurface` 提供：

1. 当前屏幕 plain-text dump。
2. 光标位置。
3. 高亮 cell 概览。
4. raw screen diff。

关键是：projector 不应该试图识别“这是不是 create-vue”。它只负责识别“这是一个 confirm/radio/select/text input screen”。命令级特化由另一个 adapter 层处理。

## 9. 与已知命令 adapter 的关系

即使引入真正的 VT screen model，也不应该取消已知脚手架的非交互 adapter。

长期最稳的组合是：

1. 已知脚手架优先走 command adapter，尽量生成非交互命令。
2. 未知或不可参数化 TUI 走 VT screen model + planner。
3. 高风险场景走 user approval / takeover。

原因很简单：

1. `create-vue` 官方支持 flags，没必要让 agent 去“看懂”它的所有 TUI 细节。
2. screen model 的职责是支撑未知 TUI，而不是取代所有命令级知识。
3. 这样能让 unknown TUI 的复杂度不压垮 known scaffolders 的成功率。

所以 screen model 是长期底座，但不是唯一优化方向。

## 10. 与现有代码的整合方式

### 10.1 `TerminalTaskRuntime`

建议在 runtime 中新增一个与 task 绑定的 screen session：

1. `taskId -> TerminalScreenModel`
2. 每次 PTY 输出到达时增量 apply。
3. 需要时导出 `TerminalScreenSnapshot`。

不要每轮 observation 都重新从 transcript 重建整屏，那会失去 VT parser 的最大价值，也会浪费性能。

### 10.2 `AgentLoopToolExecutionCoordinatorBuilder`

当前 builder 做的是：

1. 读 output tail。
2. 调 analyzer。
3. 调 extractor。
4. 再调 planner。

替换后应变成：

1. 读 runtime 当前 `TerminalScreenSnapshot`。
2. 先跑低成本 prompt fallback。
3. 再跑 `TerminalSurfaceProjector`。
4. 最后把 projector 结果交给 planner。

也就是说，builder 不再关心 ANSI 或 transcript repair，只消费“已经稳定的 screen snapshot”。

### 10.3 UI 与日志

当前 bash tool UI 不应继续把 detail 面板当成 metadata 摘要区。引入 VT screen model 之后，detail 的主职责应改成“可视化当前终端屏幕”。

也就是说，detail 需要直接渲染 `TerminalScreenSnapshot`，给用户一个可视的终端视图，而不是只展示：

1. 当前状态。
2. 规划摘要。
3. transcript 路径。
4. completion reason。

推荐改成两层：

1. **主视图层**：VT screen 视图。
2. **次级信息层**：planner / approval / takeover / diagnostic metadata。

其中主视图层应满足：

1. 按 screen buffer 还原当前终端可见区域。
2. 保留基本样式能力，至少支持焦点、高亮、反色、选中态。
3. 在用户接管时，这个区域就是用户理解当前终端状态的主要入口。
4. 在 planner 失败时，用户也能直接从该视图判断 agent 看到了什么。

次级信息层才展示更有用的诊断信息：

1. 当前 active buffer 类型。
2. 光标位置。
3. 当前聚焦选项。
4. 最新 screen snapshot 摘要。
5. planner summary。
6. approval / takeover state。

这样当交互失败时，问题会被定位为：

1. parser 没正确维护 screen。
2. projector 没正确识别语义。
3. planner 没正确规划动作。

而不是像现在一样全部混成“extractor 没识别出来”。

### 10.4 bash tool UI 改动点

围绕 VT screen model，bash tool UI 应至少有以下改动：

1. `ToolCallDetailContentView` 不再把 execute detail 设计成 metadata 卡片列表。
2. execute detail 的主区域改成 `TerminalScreenView`，直接渲染 screen snapshot。
3. planner summary、interaction phase、approval state、task id、cwd、completion reason 等退居侧栏、底栏或折叠诊断区。
4. 用户接管输入区应与 `TerminalScreenView` 紧邻，而不是和 metadata 文本块并列，形成“看屏幕 -> 发输入”的连续操作路径。
5. 如果 screen model 当前不可用，才降级到 plain-text transcript 视图，而不是默认展示 metadata。
6. detached 任务与非交互 bash 仍可保留轻量 detail，但 attached interactive task 必须优先显示可视终端视图。

推荐 UI 结构：

1. 顶部：任务标题 + 当前交互阶段 + stop/takeover controls。
2. 中部主区域：`TerminalScreenView`。
3. 底部操作区：发送文本、发送回车、方向键、Space、Ctrl-C。
4. 折叠诊断区：task id、buffer type、cursor、planner summary、transcript path。

这样 UI 语义才会与底层架构一致：既然系统已经围绕 `screen state` 建模，用户看到的主界面也应该是 screen，而不是 metadata。

## 11. 测试策略

这个设计能否落地，核心不在代码量，而在测试分层是否正确。

建议四层测试：

### 11.1 Parser tests

输入：原始字节流 / escape sequences。

断言：

1. cursor move 正确。
2. erase 正确。
3. alternate screen 切换正确。
4. style 和宽字符处理正确。

### 11.2 Screen model tests

输入：一系列 parser events。

断言：

1. 屏幕 cells 正确。
2. scroll region 和 wrap 行为正确。
3. primary/alternate buffer 切换正确。

### 11.3 Projector tests

输入：人工构造的 `TerminalScreenSnapshot`。

断言：

1. 能识别 confirm/radio/select/text input。
2. 焦点与选中态提取正确。
3. prompt text 稳定。

### 11.4 End-to-end TUI fixtures

输入：真实 `create-vue`、Clack、Prompts 录制流。

断言：

1. unknown TUI 至少能稳定进入 `planningInteraction`。
2. 高置信场景能自动推进。
3. 低置信场景能进入 approval/takeover，而不是卡死。

## 12. 演进路线

### Phase A：引入 screen model，不改 planner contract

目标：在不重写 planner contract 的前提下，直接移除 transcript extractor，把输入切换成 screen snapshot。

完成标志：

1. `TerminalSurfaceExtractor` 已被删除。
2. `create-vue` confirm screen 能稳定被识别成问题句或 confirm surface。

### Phase B：projector 语义替换现有 heuristics

目标：让 `selectionMode`、`visibleOptions`、`focusedOptionIndex` 来自 screen model，而不是字符匹配。

完成标志：

1. Clack/Prompts/Ink 类界面可稳定导出 interaction surface。

### Phase C：未知 TUI planner 接入

目标：planner 不再面向“最后 40 行文本”，而是面向 screen snapshot + semantic surface。

完成标志：

1. planner 在未知 TUI 上具备稳定的结构化输入。
2. approval/takeover 触发率和误判率明显下降。

### Phase D：细节增强

目标：补齐 resize、宽字符、组合字符和复杂 style 对 projector 的影响。

## 13. 最终建议

长期方案应明确为：

1. 不再把 transcript extractor 当作未知 TUI 的主方案。
2. 不保留旧 `TerminalSurfaceExtractor` 兼容层，直接删除旧路径。
3. 采用“VT parser + screen buffer + semantic projector”的三层模型。
4. 已知脚手架继续优先走非交互 adapter。
5. planner 只消费结构化 screen state，不直接消费渲染历史文本。

如果要替换当前 extractor，这个 VT screen model 不是可选优化，而是正确抽象层本身。

下一步如果继续推进，应单独产出实现计划，围绕以下文件展开：

1. `agentGui/Services/Terminal/TerminalVTParser.swift`
2. `agentGui/Services/Terminal/TerminalScreenModel.swift`
3. `agentGui/Services/Terminal/TerminalSurfaceProjector.swift`
4. `agentGui/Services/Terminal/TerminalTaskRuntime.swift`
5. `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
