# ChatView Agent Message 与 Subagent UI 低保真线框说明

日期：2026-03-10

关联需求文档：[docs/spec/2026-03-10-chatview-agent-message-ui-requirements.md](/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-chatview-agent-message-ui-requirements.md)

目标：用低保真方式说明 ChatView 中 agent message 的顺序流结构、执行中展开与完成后收起的行为，以及不同工具类型的基础 UI 形态。

说明：

- 本文强调结构与状态变化，不定义最终视觉稿
- 方向从“回答优先”调整为“执行顺序优先”
- subagent 继续保留任务卡样式
- 所有示意都应理解为浅色、轻边界、低嵌套版本

## 1. 总体结构

agent message 不是一张大回答卡，而是一条顺序执行流。

```text
┌──────────────────────────────────────────────────────────────────┐
│ sparkles  Claude                                10:32      [···]│
│                                                                  │
│  [结果块] 已完成初步分析，下面继续检查文件结构。                 │
│                                                                  │
│  [thinking] 推理摘要 · 320 字                                   │
│  [read]     ChatView.swift                            已读取 0.1s │
│  [read]     MessageBubbleView.swift                   已读取 0.1s │
│  [edit]     MessageBubbleView.swift                   已修改 0.3s │
│  [bash]     xcodebuild -scheme agentGui               已完成 3.2s │
│  [subagent] Explore · 梳理消息区结构                  已完成 8.4s │
│                                                                  │
│  [结果块] 结论：当前消息区应保持顺序执行流，但降低工具和思考项   │
│  的视觉重点。                                                    │
└──────────────────────────────────────────────────────────────────┘
```

规则：

- 所有步骤按执行顺序垂直排列
- 不依赖外层 timeline 线框表达顺序
- thinking 与 tool call 是轻量步骤行
- 结果块可穿插在执行流中，但不是唯一主角

## 2. 执行中态

执行中的步骤允许局部展开。

```text
┌──────────────────────────────────────────────────────────────────┐
│ sparkles  Claude                                10:32           │
│                                                                  │
│  [结果块] 正在整理 UI 结构判断。                                 │
│                                                                  │
│  [thinking] 思考中                                            v │
│      当前在比较 ChatView 与 MessageBubbleView 的职责边界。      │
│                                                                  │
│  [read] MessageBubbleView.swift                     已读取 0.1s  │
│  [edit] ToolCallBubbleView.swift                    等待执行     │
└──────────────────────────────────────────────────────────────────┘
```

或：

```text
┌──────────────────────────────────────────────────────────────────┐
│ sparkles  Claude                                10:32           │
│                                                                  │
│  [bash] xcodebuild -scheme agentGui                           v │
│      Running build...
│      Compile Swift source...
│                                                                  │
│  [subagent] Explore · 梳理消息区结构                 进行中      │
└──────────────────────────────────────────────────────────────────┘
```

规则：

- 只有当前活跃步骤可自动展开
- 非活跃步骤保持紧凑摘要态
- 展开的内容不应再套第二层重边框卡片

## 3. 完成后自动收起态

当步骤完成后，自动回到紧凑行。

```text
┌──────────────────────────────────────────────────────────────────┐
│ sparkles  Claude                                10:32      [···]│
│                                                                  │
│  [thinking] 推理摘要 · 320 字                                   │
│  [read]     MessageBubbleView.swift                   已读取 0.1s │
│  [bash]     xcodebuild -scheme agentGui               成功 3.2s  │
│                                                                  │
│  [结果块] 构建已通过，接下来可以继续调整 message UI。            │
└──────────────────────────────────────────────────────────────────┘
```

规则：

- 自动收起后只保留摘要、状态和耗时
- 历史输出不默认保持展开
- 用户可以手动再次展开查看详情

## 4. Thinking 行

thinking 不再是高饱和大卡片，而是浅色步骤行。

收起态：

```text
[thinking] 推理摘要 · 420 字
```

展开态：

```text
[thinking] 推理摘要 · 420 字                                  ^
    当前在判断 ChatView 中消息层级是否过深，重点检查 tool call
    与 subagent 的默认展示方式。
```

规则：

- 没有强紫色描边
- 没有独立厚卡片
- 完成后默认收起

## 5. 读取文件 UI

```text
[read] ChatView.swift                             已读取 · 0.1s
	agentGui/Views/ChatView.swift
```

展开态：

```text
[read] ChatView.swift                             已读取 · 0.1s  ^
	agentGui/Views/ChatView.swift
	摘要：发现消息列表位于 ChatView+MessageList 中，主视图本身
	主要负责整体布局和工作流侧栏。
```

重点：文件名是主信息，路径和摘要是次级信息。

## 6. 修改文件 UI

```text
[edit] MessageBubbleView.swift                    已修改 · 0.3s
	2 处变更
```

展开态：

```text
[edit] MessageBubbleView.swift                    已修改 · 0.3s  ^
	2 处变更
	- 调整 agent message 顺序流布局
	- 降低 tool call 卡片视觉层级
```

重点：变更摘要优先于完整 diff，完整 diff 仍可再展开。

## 7. 命令执行 UI

```text
[bash] xcodebuild -scheme agentGui                成功 · 3.2s
```

执行中展开态：

```text
[bash] xcodebuild -scheme agentGui                进行中        v
	Compile Swift source...
	Linking agentGui...
```

失败态：

```text
[bash] xcodebuild -scheme agentGui                失败 · 1.8s
	原因：重复符号错误
```

重点：命令本身和结果摘要最重要，长输出不是默认主内容。

## 8. 搜索 / 获取内容 UI

```text
[search] 查找 ChatView 中的 tool call 展示逻辑       命中 4 项
[fetch]  https://example.com/design-spec           已获取
```

展开态：

```text
[search] 查找 ChatView 中的 tool call 展示逻辑       命中 4 项  ^
	结果：MessageBubbleView、ArtifactDrawerView、
	ToolCallBubbleView、ExecutionSummaryBarView
```

## 9. 询问用户 UI

等待中：

```text
[ask] 选择 UI 基准方向                            等待用户回答
```

已完成：

```text
[ask] 选择 UI 基准方向                            已回答
      用户选择：Claude / ChatGPT
```

## 10. Subagent 任务卡

subagent 继续保留任务卡，但放在顺序流中。

收起态：

```text
┌──────────────────────────────────────────────────────────────┐
│ [subagent] Explore                                           │
│ 梳理 ChatView 和 MessageBubble 的结构差异                     │
│ 已完成 · 2 轮分析 · 8.4s · 产出文本结论                    v │
└──────────────────────────────────────────────────────────────┘
```

展开态：

```text
┌──────────────────────────────────────────────────────────────┐
│ [subagent] Explore                                           │
│ 梳理 ChatView 和 MessageBubble 的结构差异                     │
│ 已完成 · 2 轮分析 · 8.4s · 产出文本结论                    ^ │
│                                                              │
│ 结果摘要：当前消息区更适合做顺序执行流，而不是重回答卡。      │
│ 元数据：轮次数 2 / 返回类型 text                              │
│ [查看完整执行过程]                                          > │
└──────────────────────────────────────────────────────────────┘
```

规则：

- subagent 可以保留卡片感
- 但默认仍然收起，不展开内部 rounds
- 只有用户主动继续下钻，才显示完整过程

## 11. 失败态整体表现

失败项不需要重边框大红块，但应明显比普通步骤更醒目。

```text
│  [read] ChatView.swift                            已读取 0.1s │
│  [bash] xcodebuild -scheme agentGui               失败 1.8s   │
│         原因：重复符号错误                                  │
│  [结果块] 当前构建未通过，需要先修复链接错误。               │
```

规则：

- 失败步骤可保留一行原因摘要
- 不默认拉开完整错误输出
- 错误后的结果块可承接解释或下一步建议

## 12. 视觉限制规则

- 不再使用多层嵌套外框强调结构
- 过程项尽量使用浅背景、细分隔、轻图标
- 同一消息内部最多保留一层明确卡片感：subagent 任务卡或结果块
- 其它步骤尽量以扁平条目呈现

## 13. 验收用肉眼检查清单

- 用户能从上到下顺着步骤读懂 agent 的执行过程
- 当前活跃步骤在执行中自动展开，结束后自动收起
- thinking 与普通工具调用都比结果块更轻、更淡
- 不同工具类型能一眼看出差异
- subagent 仍然是任务卡，不是嵌套消息流
- 长消息不会因为历史过程过多而堆出多层重卡片