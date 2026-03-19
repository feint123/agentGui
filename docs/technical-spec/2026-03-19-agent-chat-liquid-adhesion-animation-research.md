# Agent Chat 液滴粘连动画研究记录

日期：2026-03-19

## 1. 结论

将当前执行剧场里的脉冲光效替换为“油性液滴粘连”风格时，最合适的技术路线不是继续堆 `scaleEffect + opacity`，而是采用一条轻量的 2D implicit surface / metaball 近似管线：

1. 用多个可运动的圆形场作为基础液滴。
2. 先做局部模糊，让相邻液滴之间产生连续场。
3. 再做 alpha threshold，把模糊后的连续场重新切回清晰轮廓。
4. 最后叠一层低强度高光与外发光，让材质更接近“有表面张力的油滴”，而不是普通霓虹 pulse。

这条路线的优点是：

1. 视觉语言更高级，能稳定得到“粘连-分离-再粘连”的循环感。
2. 可以直接落在 SwiftUI `Canvas` 上，不需要引入外部渲染框架。
3. 对当前 `ExecutionTheaterView` 这种局部小面积、高频刷新、无交互子元素的场景非常合适。
4. 不会破坏现有消息投影、可访问性标识和 UI 测试锚点。

## 2. 研究依据

### 2.1 Metaball / Blobby Object

Metaball 的核心思想是：多个球形影响场叠加后，对某个阈值取等值面，可以得到在靠近时自然融合、远离时自动分离的连续形体。用于 UI 时，最有价值的不是严格物理模拟，而是它天然提供的“液态粘连”观感。

对当前聊天执行剧场来说，这比 pulse 更合适，因为用户感受到的是“当前动作正在持续流动”，而不是“有一个点在机械呼吸”。

### 2.2 Implicit Surface / Soft Object

相关资料反复强调两个工程点：

1. 平滑场叠加比离散几何变形更适合表达有机连接。
2. 有限影响半径和连续光滑函数适合实时近似，不必在 UI 层做完整三维求解。

这也解释了为什么本次实现选择 2D 近似，而不是引入真正的流体模拟。UI 要的是材质错觉和节奏，不是物理精度。

## 3. 映射到 SwiftUI 的实现方式

### 3.1 可用图形管线

Apple 的 `Canvas` 提供了即时绘制能力，适合这种不需要子元素命中的动态 2D 图形。`GraphicsContext.Filter.alphaThreshold(min:max:color:)` 正好可以把模糊后的场重新裁成干净液滴轮廓，因此能复现典型 gooey / metaball UI 效果。

本次实现采用如下渲染顺序：

1. `TimelineView(.animation)` 驱动时间轴。
2. 在 `Canvas` 中绘制三枚运动液滴。
3. 先 `blur`，再 `alphaThreshold`，形成粘连体。
4. 额外叠加一层小面积高光，增强“油性”而不是“光斑”质感。
5. 用较弱的 `shadow` 做外缘能量感，避免纯平。

### 3.2 为什么不做真正物理流体

不采用粒子流体或 Navier-Stokes 类方案，原因很明确：

1. 当前动效面积很小，复杂流体求解没有性价比。
2. 消息列表场景更重视稳定帧率和可控回归，而不是绝对真实。
3. `Canvas + blur + threshold` 已能提供足够明确的液滴粘连识别度。

### 3.3 为什么保留局部 flash 而去掉 pulse

旧实现依赖 `repeatForever` 的 `scaleEffect`，其优点是简单，但问题也很明显：

1. 节奏太机械。
2. 当前动作和当前卡片同时 pulse 时，视觉层级会显得廉价。
3. 更像“状态灯”，不像“正在流动的执行介质”。

因此这次只保留状态切换瞬间的 `actionChangeFlash`，用于表达“动作刚切换”的瞬时反馈；持续态则完全交给液滴粘连动画承担。

## 4. 在当前代码中的落地

本次改动集中在 `ExecutionTheaterView`：

1. 移除持续 `pulseCurrentCard` 状态。
2. 引入 `LiquidAdhesionIndicator`，作为可复用的局部液滴组件。
3. 将 current action 标签前的点状 pulse 替换为液滴粘连动画。
4. 将当前 live task card 前导指示器替换为液滴粘连动画。
5. 给当前卡片顶部增加一条低强度液滴高光，强化正在执行的材质感。
6. 保留 `chat.agentMessage.currentAction`、`chat.agentMessage.executionTheater`、`chat.agentMessage.liveTaskCard.*` 等现有可访问性标识。

这意味着：

1. 投影层、消息快照、UI 结构完全没变。
2. 回归风险主要局限在视图绘制本身。
3. 现有测试更可能继续稳定通过。

## 5. 后续可迭代方向

如果后续继续加强这个方向，推荐顺序如下：

1. 将当前卡片顶部的单条液滴高光升级为 phase-aware 的液态能量带。
2. 让 `ExecutionPhaseRibbonView` 的当前 phase 也改成同类液态 sweep，而不是普通高光扫过。
3. 为不同 phase 调整液滴节奏和粘度参数，例如 `running` 更饱满、`inspecting` 更轻快、`blocked` 更滞重。
4. 若后续要做全消息背景液态氛围，再单独评估更大面积 `Canvas` 的性能与测试策略。

## 6. 参考资料与论文

1. Jim Blinn. A Generalization of Algebraic Surface Drawing. ACM Transactions on Graphics, 1982.
2. Geoff Wyvill, Craig McPheeters, Brian Wyvill. Data Structure for Soft Objects. The Visual Computer, 1986.
3. Matthew Ward. An Overview of Metaballs/Blobby Objects. Worcester Polytechnic Institute course notes.
4. Paul Bourke. Implicit Surfaces. 1997.
5. Apple Developer Documentation. `Canvas`.
6. Apple Developer Documentation. `GraphicsContext.Filter.alphaThreshold(min:max:color:)`.

## 7. 一句话归纳

这次实现本质上是把“当前动作高亮”从 pulse 灯语义，升级为基于 2D metaball 近似的液态执行语义；它更贴近执行流动感，也更符合高级 UI 动效的视觉方向。