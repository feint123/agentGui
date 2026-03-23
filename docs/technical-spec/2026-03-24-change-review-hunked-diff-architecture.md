# 2026-03-24 agent 文件变更审核 Diff / Hunk 化技术设计

日期：2026-03-24

关联对象：`WorkspaceChangeCaptureService`、`ChangeReviewArtifactBuilder`、`ChangeReviewFileArtifact`、`ChangeProposalStore`、`ProposedFileChange`、`ConversationExecutionOrchestrator`、`DirectIntentBackend`、`GitDiffView`、`ChangeProposalReviewView`、`ProposalDockPresenter`、`WorkspaceChangeCaptureServiceTests`

## 0. 文档结论

当前 agentGui 的文件变更审核能力，已经具备“真实工作区快照 -> 变更提案 -> Diff 预览 -> 人工审核”的主链路，但 `WorkspaceChangeCaptureService` 内部生成的并不是接近 Git 的 diff，而是“整份旧文件全部删除 + 整份新文件全部新增”的单 hunk 伪 unified diff。

这会直接带来四个问题：

1. 审核可读性差。用户看到的是整文件重写，而不是局部变更。
2. hunk 边界错误。当前永远只生成一个覆盖全文件的 hunk，无法像 Git 一样把相距较远的修改拆分成多个区块。
3. 统计误导。`lineAdditions` / `lineDeletions` 目前等于新旧文件总行数，而不是真正的增删行数，导致停靠面板和摘要被放大。
4. 后续能力受限。未来若要支持“按 hunk 审核”“按 hunk 应用/丢弃”“移动代码高亮”“函数级上下文”，当前算法和数据产物都不够。

本次设计的核心结论是：

1. 变更审核层应引入“结构化文件 diff”内部模型，以 hunk 作为一等概念。
2. 算法层不应简单复刻某一个 Git 内部实现，而应借鉴 Git 的组合思路：
   1. 基础最短编辑脚本算法。
   2. 面向可读性的 hunk 划分与合并。
   3. 面向代码的边界优化启发式。
   4. 在特定输入上可切换或增强为 patience/histogram 风格匹配。
3. 推荐方案不是运行时直接依赖 `git diff --no-index`，而是在应用内实现一条可控的 diff pipeline：
   1. 预处理：公共前后缀裁剪、行标准化、快速等值/单侧新增删除判断。
   2. 核心匹配：默认 Myers SES，必要时引入 patience anchors。
   3. hunk 构建：按统一上下文行数切块，并支持近邻 hunk 融合。
   4. 边界优化：参考 Git indent heuristic 与语义边界滑移。
   5. 输出：生成统一 diff 文本，同时保留结构化 hunks 供 UI 和后续能力使用。
4. 迁移时应尽量不破坏现有存储与 UI 接口。第一阶段保留 `ProposedFileChange.unifiedDiff` 作为兼容输出，但 diff 生成逻辑改为基于结构化 hunk 序列化得到。

一句话概括：

> 变更审核需要从“整文件替换文本”升级为“基于最短编辑脚本的结构化 hunk diff”，并用 Git 式启发式把机器最优解修正为人可审的差异视图。

## 1. 现状与根因

### 1.1 当前实现实际不是 diff，而是全量替换描述

当前 `ChangeReviewArtifactBuilder.unifiedDiff(...)` 的逻辑是：

1. 把旧文本按行全部转成 `-` 行。
2. 把新文本按行全部转成 `+` 行。
3. 根据文件类型生成一个单独 hunk header。
4. 最终拼出一个“形式像 unified diff、语义却不是最短差异”的字符串。

这意味着对于任意文件内局部修改，例如只改一行文案，系统也会表现成：

1. 删除整份旧文件。
2. 新增整份新文件。

因此现在的问题不是 UI 没有把 hunk 画好，而是上游从一开始就没有产出真正的 hunk。

### 1.2 当前统计与展示都建立在错误 diff 上

`ProposalDockPresenter` 直接累计 `lineAdditions` / `lineDeletions`，而 `WorkspaceChangeCaptureService` 目前把它们计算成“新文件总行数”和“旧文件总行数”。

结果是：

1. 停靠摘要会严重夸大变更规模。
2. 单文件审查列表会误导用户，以为文件被大规模重写。
3. 后续若引入风险阈值、自动折叠、超大 patch 限流，这些判断都会失真。

### 1.3 现有 UI 已经天然适合真正 hunk 化 diff

`GitDiffView` 当前已经具备按 `@@ ... @@` 解析 section 的能力。也就是说：

1. UI 不需要推倒重来。
2. 当前最大的缺口是上游没有生成多个 hunk。
3. 只要算法层产出正确 unified diff，现有视图就能立即受益。

这也是本次设计优先从 `WorkspaceChangeCaptureService` 和其产物建模入手，而不是先改渲染层的原因。

## 2. 调研结论

### 2.1 论文与基础算法结论

本次调研参考了以下经典资料与工程综述：

1. J. Hunt / M. McIlroy, 1976, An Algorithm for Differential File Comparison。
2. Eugene W. Myers, 1986, An O(ND) Difference Algorithm and Its Variations。
3. Neil Fraser, 2006, Diff Strategies。

可归纳出三条稳定结论：

1. 文本 diff 的核心目标是求最短编辑脚本或近似最优编辑脚本，这决定了哪些行被视为“相同”，哪些行被视为“增删改”。
2. 只追求最少编辑次数并不足以得到“最好审”的结果。面向人类阅读时，还需要语义化边界处理、噪声消除、上下文控制。
3. 实战中优秀 diff 往往是“核心算法 + 预处理 + 后处理”组合，而不是单一公式。

Myers 的价值在于：

1. 能高效求解 shortest edit script。
2. 是 Git 默认 diff 的理论基础。
3. 对局部改动、常规文本改动具有稳定性。

但 Myers 也有一个工程缺点：

1. 当文本包含大量重复结构、空行、括号或样板代码时，可能把“无语义的重复行”错当成锚点。
2. 结果会出现“数学上短、视觉上乱”的 diff。

### 2.2 Patience / Histogram 的工程意义

Git 官方文档和 Git 相关实现分析表明，Git 并不把“默认 Myers”视作唯一正确方案，而是长期保留了：

1. `myers`
2. `minimal`
3. `patience`
4. `histogram`

Patience diff 的关键思想不是替代 Myers，而是：

1. 先寻找两边都只出现一次的唯一行作为锚点。
2. 用这些锚点把大问题切成更小的子区间。
3. 再在子区间内运行实际 diff 算法，例如 Myers。

这在代码场景里尤其有价值，因为：

1. 函数签名、独特语句、注释标题往往是高价值锚点。
2. 空行、`}`、重复 `return` 这类低语义行不应该主导匹配。
3. 对函数挪动、代码块重排、相似样板复制粘贴，patience 往往比裸 Myers 更可读。

Histogram 可以理解为对 patience 的增强：

1. 不只依赖严格“唯一行”。
2. 对“低频出现”的公共元素也给予权重。
3. 在重复文本较多时，通常比纯 patience 更稳。

### 2.3 Git 的真正启发不是算法名，而是 diff pipeline

Git 官方文档里真正对 review 体验影响最大的，不仅是 `--diff-algorithm`，还有：

1. `--indent-heuristic`：移动 hunk 边界，让 patch 更贴近代码结构。
2. `--inter-hunk-context`：把距离很近的 hunks 合并，减少碎片化。
3. `-W` / function context：按函数显示更多上下文。
4. `-B` / break rewrites：对接近全量重写的文件，用 rewrite 视角呈现。
5. `--color-moved`：把移动代码识别为“移动”，而不是完全新增/删除。
6. rename/copy detection：文件级别的语义识别。

因此，agentGui 如果想“参考 Git 的 diff”，最值得学习的不是“照抄 Git C 代码”，而是接受这个事实：

> 一个适合代码审查的 diff 系统，必须同时考虑匹配算法、hunk 生成、边界启发式、rewrite 策略和展示语义。

## 3. 目标与非目标

## 3.1 目标

本次设计目标如下：

1. 为修改文件生成真正的 line-based unified diff。
2. 将变更内容切分成多个 hunks，而不是永远单 hunk。
3. 让 `lineAdditions` / `lineDeletions` 反映真实增删行数。
4. 让现有 `GitDiffView` 能直接展示更接近 Git 的 diff 结果。
5. 为未来的“按 hunk 审核”“移动代码识别”“函数级 context”保留内部扩展点。
6. 保持现有 `ChangeProposalStore`、`ChangeProposalReviewView` 和审核工作流基本兼容。

## 3.2 非目标

本次设计不把以下内容作为第一阶段交付范围：

1. 完整实现 Git 级 rename / copy detection。
2. 完整实现 `--color-moved` 等价的移动块识别 UI。
3. 按 hunk 应用/拒绝。
4. 多父 merge diff / combined diff。
5. 二进制 delta 压缩或 patch apply 引擎替换。

这些能力在设计里会预留接口，但不要求在第一阶段全部落地。

## 4. 方案比选

### 4.1 方案 A：继续使用当前整文件删加模型

优点：

1. 零实现成本。
2. 不涉及存储结构和算法复杂度。

缺点：

1. 审查体验无法接受。
2. 统计持续失真。
3. 无法支撑 hunk 级能力。
4. 与 Git diff 语义差距过大。

结论：不采纳。

### 4.2 方案 B：运行时直接调用 `git diff --no-index`

优点：

1. 结果接近 Git 原生输出。
2. 几乎天然具备 hunk、上下文和算法切换能力。
3. 可快速验证显示链路。

缺点：

1. 把核心审核能力绑定到外部可执行依赖，沙箱、路径、编码、版本兼容都要处理。
2. 非 Git 环境虽可使用 `--no-index`，但仍要求本机安装 Git。
3. 取消、超时、stderr、平台差异和路径 quoting 都要做一层包装。
4. 结果可显示，但内部无法直接得到结构化 hunk，后续要再反解析。

结论：可作为测试 oracle 或临时对照工具，不建议作为正式运行时依赖。

### 4.3 方案 C：应用内实现结构化 diff pipeline

优点：

1. 不依赖外部 Git，可控性强。
2. 能直接输出结构化 hunks，再序列化为 unified diff。
3. 可以分阶段接近 Git 的行为，而不是一次性追求完全等价。
4. 易于与现有 SwiftData、SwiftUI、取消机制和测试体系融合。

缺点：

1. 实现成本最高。
2. 要自行处理性能、边界条件和一致性验证。

结论：推荐采用。

## 5. 推荐方案

推荐方案是：

1. 在应用内实现一套结构化 diff engine。
2. 第一阶段以 Myers SES 为基础算法。
3. 加入 patience-style anchors 作为增强路径，而非一开始就做全量 histogram。
4. 在 hunk 构建后加入 Git 风格的边界优化与近邻 hunk 合并。
5. 输出保留两层：
   1. 结构化 hunks，供内部逻辑使用。
   2. unified diff 文本，供现有存储与 UI 兼容使用。

推荐理由：

1. 这条路径能最小化对现有审核工作流的破坏。
2. 能先解决最痛的审查可读性和统计失真问题。
3. 后面若要继续补 histogram、moved-block detection、按 hunk 操作，不需要重写数据流。

## 6. 目标架构

### 6.1 新的内部数据模型

建议在 `Services/ChangeReview` 下新增内部结构：

```swift
struct StructuredFileDiff: Sendable, Equatable {
    let relativePath: String
    let absolutePath: String
    let kind: ProposedFileChangeKind
    let summary: DiffSummary
    let hunks: [DiffHunk]
    let renderPolicy: DiffRenderPolicy
}

struct DiffSummary: Sendable, Equatable {
    let additions: Int
    let deletions: Int
    let unchangedPrefixLines: Int
    let unchangedSuffixLines: Int
}

struct DiffHunk: Sendable, Equatable, Identifiable {
    let id: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffHunkLine]
}

enum DiffHunkLine: Sendable, Equatable {
    case context(oldLine: Int, newLine: Int, text: String)
    case deletion(oldLine: Int, text: String)
    case addition(newLine: Int, text: String)
    case noNewlineMarker
}

enum DiffRenderPolicy: Sendable, Equatable {
    case unified
    case rewrite
    case binary
    case tooLargeCollapsed
}
```

说明：

1. `StructuredFileDiff` 是内部一等产物。
2. `unifiedDiff` 不再手写拼字符串，而是由 `StructuredFileDiff` 序列化得到。
3. `DiffRenderPolicy` 为之后的 rewrite / binary / collapsed 提供分支。

### 6.2 与现有持久化模型的关系

第一阶段不要求修改 `ProposedFileChange` 的持久化 schema。流程如下：

1. `WorkspaceChangeCaptureService` 比较 base/staged 文本。
2. 新 diff engine 生成 `StructuredFileDiff`。
3. 由 serializer 输出 `unifiedDiff` 字符串。
4. `lineAdditions` / `lineDeletions` 来自 `DiffSummary`。
5. 继续把 `unifiedDiff`、快照和统计写入 `ProposedFileChange`。

这样做的好处是：

1. `ChangeProposalStore` 基本不用动 schema。
2. `ChangeProposalReviewView` 和 `GitDiffView` 可立即复用。
3. 如果以后要持久化 hunk，可单独做迁移，而不阻塞第一阶段。

## 7. 算法设计

### 7.1 输入预处理

对每个文本文件先做以下预处理：

1. 快速等值判断。
2. 提取公共前缀行和公共后缀行。
3. 把中间剩余区间送入核心 diff 算法。
4. 保留“是否以换行结尾”的信息，用于 `\ No newline at end of file` 标记。

原因：

1. 这能显著缩小核心 diff 的问题规模。
2. 对大多数局部编辑，公共前后缀裁剪非常有效。
3. 这也是 Fraser 总结的常用预处理优化。

### 7.2 核心匹配策略

建议采用“两级策略”：

1. 默认路径：Myers SES。
2. 增强路径：先做 patience anchors，再对子区间运行 Myers。

具体规则：

1. 若文件为新增或删除，直接生成单个 add/delete hunk，不运行 Myers。
2. 若文件修改且中间区间很小，直接 Myers。
3. 若检测到以下特征之一，启用 patience anchors：
   1. 重复行比例高。
   2. 编辑跨度大但唯一行也较多。
   3. 出现明显的代码块移动或函数重排迹象。
4. patience anchors 未找到有效锚点时，回退 Myers。

为什么不第一阶段就完整实现 histogram：

1. histogram 的价值在“低频公共元素”选择上。
2. 但对当前 agentGui 的主要痛点，Myers + patience anchors 已能解决大部分“整文件像重写”的问题。
3. 先把架构和 hunk 化打通，再补 histogram 更稳妥。

### 7.3 编辑脚本到 hunk 的构建

从 edit script 转 hunk 时采用 Git 风格的 unified diff 规则：

1. 默认上下文行为 3 行。
2. 修改块之间若间隔不超过 `interHunkContext`，则合并为一个 hunk。
3. hunk header 使用标准格式：`@@ -oldStart,oldCount +newStart,newCount @@`。
4. 文件头统一输出：
   1. `--- a/<path>` / `+++ b/<path>`，尽量贴近 Git。
   2. 新增/删除文件可使用 `/dev/null` 语义或保持现有路径兼容，但建议逐步靠拢 Git 头部格式。

建议默认参数：

1. `contextLines = 3`
2. `interHunkContext = 1`

这比当前的“永远单 hunk”更接近用户对 Git diff 的预期，同时避免两个相邻改动被切得过碎。

### 7.4 hunk 边界优化

仅有 SES 还不够，需要增加一层“可读性后处理”：

1. 优先把边界落在空行、缩进层级变化、块起止附近。
2. 避免把单独的 `}`、空白行、重复分隔符当作最佳锚点。
3. 尝试滑移编辑边界，使 hunk 更贴近语义块。

可采用的评分启发式：

1. 边界临近空白行：高分。
2. 边界临近缩进变化：高分。
3. 边界落在行首非字母数字或注释头：中高分。
4. 边界把一段很短的公共文本孤立出来：降分。

这部分并不需要完全复制 Git 的实现细节，只需要达到相同目标：

> 在多个同样最短的 diff 中，优先选择更贴近代码结构的那一个。

### 7.5 rewrite 判定

参考 Git 的 `-B` / break rewrites 思路，建议加入 rewrite 判定：

1. 如果修改文件的保留锚点极少。
2. 且新增 + 删除占总行数比例非常高。
3. 则可将 `renderPolicy` 标记为 `.rewrite`。

第一阶段可以只做判定，不改变最终 unified diff 格式；第二阶段再决定是否把 rewrite 以更清晰的方式展示。

这样做的好处是：

1. 对真正重写的文件，不必强行追求碎片化匹配。
2. 可为 UI 提供“此文件近似重写”的提醒。

## 8. 与现有代码的整合点

### 8.1 `WorkspaceChangeCaptureService`

这里是最核心改造点。

建议把当前 `ChangeReviewArtifactBuilder` 拆为三层：

1. `TextDiffTokenizer`
2. `StructuredDiffEngine`
3. `UnifiedDiffSerializer`

`WorkspaceChangeCaptureService.collectArtifacts(...)` 仍负责：

1. 枚举文本文件。
2. 过滤路径和二进制文件。
3. 比较快照。

但不再自行拼接伪 diff 文本，而是调用结构化 diff engine。

### 8.2 `ChangeReviewFileArtifact`

第一阶段可保持现有字段不变，只修正来源：

1. `unifiedDiff` 来自 serializer。
2. `lineAdditions` / `lineDeletions` 来自真实 hunk 统计。

如果后续要支持 hunk 级动作，可以新增非持久化字段或并行内部对象，不必一开始就改数据库。

### 8.3 `GitDiffView`

`GitDiffView` 当前已经会按 `@@` 解析多个 section，因此第一阶段只需保证上游生成标准 hunk。

第二阶段可再增强：

1. 展示 hunk 序号。
2. 展示函数/语义标题。
3. 对 rewrite / moved-code / collapsed diff 给出更清晰的空状态或标记。

### 8.4 `ProposalDockPresenter`

这里无需结构改动，但受益会立刻体现：

1. 总增删行数变真实。
2. 单文件变更规模更可信。
3. 用户对“这个提案大不大”的判断会更准确。

## 9. 测试设计

### 9.1 单元测试

围绕 `StructuredDiffEngine` 建立纯算法测试：

1. 单行替换应生成一个小 hunk，而不是整文件删加。
2. 两个相距较远的修改应生成两个 hunk。
3. 两个相距 1 行上下文内的修改应合并成一个 hunk。
4. 新增文件与删除文件应生成正确 header 和单 hunk。
5. 文件末尾无换行时应输出 no-newline marker。
6. 重复空行和重复括号不应导致明显错误锚定。
7. 函数重排样例上，patience 增强路径应优于纯 Myers。
8. 中文路径和 UTF-8 内容应正常工作。

### 9.2 回归测试

扩展现有 `WorkspaceChangeCaptureServiceTests`：

1. 断言 `file.txt` 轻微修改时，`unifiedDiff` 包含上下文行和准确 hunk header。
2. 断言 `lineAdditions` / `lineDeletions` 等于真实改动行数。
3. 断言多个独立修改会产生多个 `@@` section。

### 9.3 Git 对照测试

建议在测试中引入“Git 作为 oracle”的非阻塞对照测试：

1. 使用 `git diff --no-index --unified=3 --no-color` 生成参考输出。
2. 对比本地 engine 生成的 hunk 数量、header 范围、增删统计。
3. 不要求字节级完全一致，但要求在关键结构上接近：
   1. hunk 数量相同或更少但不更差。
   2. 增删统计一致。
   3. 不出现整文件误判为全量替换。

这种对照测试非常重要，因为它能让我们“参考 Git”而不在运行时依赖 Git。

### 9.4 性能测试

针对以下样本做基准：

1. 200 行、2 处局部改动。
2. 2,000 行、10 处局部改动。
3. 10,000 行、大量重复样板。
4. 接近全量重写。

目标不是绝对追平 Git，而是保证：

1. 仍在 detached utility task 中运行。
2. 可取消。
3. 不在大型文件上出现明显 UI 卡顿。

## 10. 分阶段落地建议

### 10.1 第一阶段

目标：替换当前伪 diff，实现真正 hunk 化。

交付内容：

1. `StructuredDiffEngine`。
2. `UnifiedDiffSerializer`。
3. Myers + 预处理 + hunk 构建。
4. 正确的增删行统计。
5. 针对现有审核链路的回归测试。

### 10.2 第二阶段

目标：让 diff 更接近 Git review 体验。

交付内容：

1. patience anchors。
2. 边界滑移 / indent heuristic。
3. inter-hunk-context 参数化。
4. rewrite 判定。

### 10.3 第三阶段

目标：基于结构化 hunk 做高级审查能力。

交付内容：

1. hunk 导航。
2. hunk 级 apply / discard。
3. moved code 识别与可视提示。
4. 可选函数级 header / context。

## 11. 风险与应对

### 11.1 算法正确性风险

风险：自研 diff engine 容易在重复文本、无换行结尾、极端重排上出错。

应对：

1. 先做结构化单测。
2. 再做 Git 对照测试。
3. 对高风险样本建立 golden fixtures。

### 11.2 性能风险

风险：Myers 在超大文件和高重复文本上可能退化。

应对：

1. 做公共前后缀裁剪。
2. 对大文件引入 patience anchors 或 rewrite 提前判定。
3. 维持 detached + cancellation。
4. 设定超大文件降级策略。

### 11.3 结果与 Git 不完全一致的预期风险

风险：用户说“参考 Git”，但内部实现不可能逐字节完全复制 Git。

应对：

1. 在设计上追求 Git 式行为而非 Git bit-for-bit 一致。
2. 以 hunk 结构、统计、可读性作为一致性指标。
3. 在测试中把 Git 作为对照基准，而不是唯一真理。

## 12. 最终建议

建议直接启动“方案 C，分两阶段落地”：

1. 第一阶段先把当前 `WorkspaceChangeCaptureService` 的伪 diff 替换为真正的 Myers-based hunk diff。
2. 同时修正 `lineAdditions` / `lineDeletions` 的统计来源。
3. 第二阶段补 patience anchors 和边界优化，让结果更接近 Git review 体验。

原因很明确：

1. 当前问题的根因在算法层，而不在 UI 层。
2. 现有 UI 已具备消费 hunk 的能力。
3. 第一阶段的改造收益立竿见影，风险可控。
4. 结构化 diff 一旦引入，后续 hunk 级审查能力就有了扎实基础。

## 13. 参考资料

1. Myers diff 讲解与原论文链接：
   1. https://blog.jcoglan.com/2017/02/12/the-myers-diff-algorithm-part-1/
   2. 原论文镜像链接在文中引用为 http://www.xmailserver.org/diff2.pdf
2. Patience diff 工程解释：
   1. https://blog.jcoglan.com/2017/09/19/the-patience-diff-algorithm/
3. Git 官方 diff 文档：
   1. https://git-scm.com/docs/git-diff
   2. https://git-scm.com/docs/diff-options
4. Diff 实践综述：
   1. https://neil.fraser.name/writing/diff/
5. Git 内部算法与 diff 历史分析：
   1. https://fabiensanglard.net/git_code_review/diff.php