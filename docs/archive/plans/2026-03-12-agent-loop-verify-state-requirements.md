# Main Agent Loop Verify State 需求说明

**日期：** 2026-03-12

**目标：** 将当前主 agent loop 中偏工具化、可选化的 verify 能力升级为必经状态，引入一个供主 agent loop 调用的专职 verifier subagent 负责验证结论，并在 verify 未通过时统一进入 reflection 状态进行反思与重试决策。同时，更新 explorer 的 description，使其改为更完整、专业、英文化的描述。

---

## 1. 背景与现状

当前主 agent loop 已具备以下能力：

- 主 agent 可调用 `run_subagent` 启动专职子代理。
- 已存在 `explorer`、`planner`、`coder`、`reviewer`、`executor` 等子代理能力。
- 存在 `reflection` 阶段，但当前更偏向由 failure trigger 或 hook 驱动，不是 verify 失败后的统一收敛路径。
- 当前存在 `verify_completion` 一类验证能力与执行证据守卫，但它更接近 finalization 阶段的辅助判定，不是主 loop 中强约束、显式可见的必要状态。

现状存在三个问题：

1. verify 不是主 agent 给出最终完成结论前的必要状态，导致“看起来完成”与“被验证完成”之间缺少稳定边界。
2. verify 失败后没有统一转入 reflection 的强约束，失败恢复路径分散在 guard、retry prompt、tool failure 等不同机制中。
3. explorer 的 description 过短，且为中文简述，不利于模型稳定理解其职责边界、输入输出契约与只读约束。

---

## 2. 目标

本次需求聚焦以下三项变更：

1. 将 verify 升级为主 agent loop 的必要状态，而不是可选工具或收尾补充动作。
2. 新增专职 `verifier` subagent，由主 agent 在合适时机通过 `run_subagent` 调用，负责消费执行证据、审查结论和完成标准，输出结构化验证结果。
3. 当 verify 未通过时，主 agent loop 必须转入 reflection 状态，由 reflection 负责总结失败原因、生成修正方向，并决定是否重试。
4. 将 `explorer` 的 description 更新为英文且更详细的版本，强化其“只读探索者”角色认知。

---

## 3. 非目标

- 本次需求不要求删除现有 `executor` 或 `reviewer` 子代理。
- 本次需求不要求引入新的 workflow 层或独立调度 runtime。
- 本次需求不要求变更 `run_subagent` 的对外工具协议。
- 本次需求不要求新增 UI 设计稿，但要求运行轨迹与状态记录可支撑后续 UI 呈现。

---

## 4. 核心设计结论

### 4.1 Verify 必须成为主 loop 的显式状态

主 agent loop 需要从“执行完成后直接 finalizing / done”升级为“执行候选完成后进入 verify，再决定 done 或 reflection”。

推荐的高层状态顺序为：

```text
executing -> verifying -> done
        |
        v
      reflecting -> executing / done
```

关键要求：

- 任何声称“已完成”的代码任务，在主 agent 给出最终答复前必须经过 verifying。
- verifying 不是可跳过状态，除非任务类型被明确声明为无需验证；默认的代码修改任务必须验证。
- verifying 的输入必须包含至少以下信息：任务目标、成功标准、代码变更摘要、review 结果、执行证据、未完成风险。

### 4.2 新增专职 verifier subagent

新增一个由主 agent loop 使用 `run_subagent` 调用的专职子代理：`verifier`。

职责边界：

- 不负责直接修改代码。
- 不负责大范围重新探索代码库。
- 负责判断当前产出是否满足“可交付”标准。
- 负责检查完成声明是否与执行证据、review 反馈、任务目标一致。
- 负责输出结构化验证结果，供主 agent loop 做状态转移。

`verifier` 与现有子代理的关系：

- `executor` 负责“跑”。
- `reviewer` 负责“审”。
- `verifier` 负责“判定是否真的完成”。

三者不应混用，否则模型容易把“跑过命令”“给过 review”“真正通过验证”混成一件事。

### 4.3 Verify 失败必须进入主 loop 的 reflection

当 `verifier` 返回未通过结果时，主 agent loop 必须进入 reflection，而不是直接结束、直接给最终答案、或仅附加一句 retry prompt。

这样做的目的：

- 让失败恢复有统一入口。
- 让 reflection 读取完整 verify 失败原因，而不是只读取零散错误文本。
- 让后续重试建立在结构化失败摘要之上，而不是让 coder 自行猜测为什么失败。

---

## 5. 用户故事

1. 作为用户，我希望 agent 在声称任务完成前一定经过验证，而不是只凭模型主观判断结束。
2. 作为用户，我希望验证失败时系统先反思失败原因，再进行下一轮修复，而不是盲目重复尝试。
3. 作为开发者，我希望 verifier 的结果是结构化的，方便主 loop、测试和 UI 读取。
4. 作为开发者，我希望 explorer 的职责说明更清晰，从而减少它误改文件、过度输出或越权执行的概率。

---

## 6. 功能需求

### 6.1 主 Agent Loop 状态机要求

- 新增或显式启用 `verifying` 状态。
- 所有代码改动型主 loop 任务在进入完成判定前，必须先进入 `verifying`。
- `verifying` 的直接上游应为 `executing` 或当前 finalization 前的候选完成阶段，但不能被跳过。
- `verifying` 结束后只允许两类主结果：
  - 通过：进入 `done` 或最终回答阶段。
  - 不通过：进入 `reflecting`。

### 6.2 Verifier Subagent 要求

新增一个可通过 `run_subagent(agent_name: "verifier")` 调用的 verifier 定义，至少包含以下约束：

- 名称：`verifier`
- 类型：只读子代理
- 允许读取：当前任务描述、相关消息历史、代码变更摘要、review 结果、执行结果摘要、verify_completion 输入或等价完成声明
- 默认不允许写文件、不允许直接编辑代码
- 可以复用现有只读工具与必要的证据读取能力
- 输出主结果：结构化 `verificationReport`，并作为主 agent loop 的 verify 决策输入

`verificationReport` 建议至少包含以下字段：

```json
{
  "passed": false,
  "summary": "why verification passed or failed",
  "verified_items": ["item 1"],
  "failed_items": ["item 2"],
  "missing_evidence": ["item 3"],
  "risk_areas": ["risk 1"],
  "recommended_next_action": "reflect",
  "confidence": 0.82
}
```

强约束：

- 当证据不足时，`passed` 不得为 `true`。
- 当 review 存在 blocking rejection 且未被消化时，`passed` 不得为 `true`。
- 当任务成功标准未被逐项覆盖时，`verifier` 必须显式列出缺口。

### 6.3 Verify 到 Reflection 的转移规则

当出现以下任一条件时，verify 视为未通过并进入 reflection：

- `verificationReport.passed == false`
- 存在 `failed_items`
- 存在关键 `missing_evidence`
- 存在阻塞级 review/rejection 尚未关闭
- 结论声称完成，但执行证据与结论不一致

进入 reflection 时，主 agent loop 必须将以下内容作为结构化输入传入：

- 最近一次 `verificationReport`
- 最近一次 `reviewReport`
- 最近一次执行结果摘要或 `testReport`
- 当前轮代码摘要 `codePatchSummary` 或等价变更摘要
- 本轮任务目标与成功标准

reflection 必须输出：

- 是否值得重试
- 下一轮优先修复项
- 需要补充的证据或测试
- 是否需要重新探索上下文

### 6.4 Reflection 后的回流规则

reflection 完成后，主 agent loop 根据结果回流：

- 需要补代码：回到 `executing`
- 需要补执行证据：回到 `executing`
- 需要补上下文：由主 agent 再次调用 `explorer` 等现有 subagent
- 明确不可完成或超预算：结束并返回失败结论

要求：

- reflection 不能只生成自由文本，必须提供结构化修复方向。
- 主 agent 在后续重新调用 coder / executor / explorer 等 subagent 时，必须把 verify 失败的结构化原因带入，而不只是简短摘要。

### 6.5 Explorer Description 更新要求

将 `explorer` 的 `description` 由当前简短中文描述升级为更详细的英文描述。

推荐文案如下：

```text
Investigates the codebase, local documentation, and approved web sources to gather the minimum high-value context needed for downstream agents. Operates in a strictly read-only mode, identifies relevant files and symbols, summarizes findings, highlights unknowns and risk areas, and returns structured exploration output without making code or file changes.
```

更新目标：

- 明确 explorer 的信息来源范围：codebase、local docs、approved web sources
- 明确 explorer 的工作目标：gather the minimum high-value context needed for downstream agents
- 明确 explorer 的只读边界：strictly read-only mode
- 明确 explorer 的标准输出：relevant files、symbols、findings、unknowns、risk areas、structured output
- 明确 explorer 不做什么：without making code or file changes

### 6.6 主 Loop 消息与结果契约要求

为支撑 verifier，需要在主 loop 内引入或扩展 `verificationReport` 这一结构化结果对象。

要求：

- verifier 的主输出必须可持久化，或至少可稳定挂接到当前 agent round / tool call 记录。
- 主 loop 必须能基于 `verificationReport` 做状态转移，而不是只读自然语言文本。
- UI 后续应能展示 verify pass/fail、失败原因、缺失证据和反思建议。

---

## 7. 状态转移要求

推荐的关键转移规则如下：

```text
executing -> verifying -> done
        |
        v
      verifying(fail)
        |
        v
    reflecting
      /    |    \
     v     v     v
   execute  ask   fail
     subagent
```

补充要求：

- `reviewing`、`executor`、`explorer` 等都是主 agent 在 verify 前可选择调用的支持能力，但 `verifying` 必须发生在最终完成判定之前。
- 若缺少任一必需输入，`verifying` 不应返回通过，而应返回“证据不足”。
- verify 失败计入 loop 的失败预算与 reflection 预算。

---

## 8. 验收标准

### 8.1 功能验收

- 代码任务在主 agent loop 中无法绕过 `verifying` 直接完成。
- 新增 `verifier` subagent 后，系统可以对代码任务生成结构化 `verificationReport`。
- 当 verify 未通过时，loop 会进入 `reflecting`，而不是直接结束或直接回 coder。
- reflection 输入中包含 verify 失败原因的结构化数据。
- explorer 的 description 已更新为英文详细文案。

### 8.2 测试验收

- 存在状态机测试覆盖“通过 verify 才能完成”。
- 存在状态机测试覆盖“verify fail -> reflecting”。
- 存在 verifier 结果解析测试，覆盖 pass / fail / missing evidence。
- 存在主 agent 调用 `verifier` subagent 的测试，覆盖输入拼装与结果消费。
- 存在 explorer description 快照或精确字符串测试，避免后续被意外回退。

### 8.3 可观测性验收

- agent round / tool call / result 记录中可看到 verify 阶段开始与结束。
- verify 失败原因在日志或持久化状态中可被追踪。
- reflection 可关联到触发它的 verificationReport。

---

## 9. 风险与约束

1. 如果 verifier 与 reviewer 职责不清，模型可能重复输出相似结论，造成 token 浪费。
2. 如果 verifier 没有读取结构化执行证据，只看自然语言总结，仍然会出现“假完成”。
3. 如果 verify 失败不强制进入 reflection，状态机会再次退化成分散重试逻辑。
4. 如果 explorer description 只改 description 不改 system prompt，效果提升会有限；但本次至少要先统一 description 基线。

---

## 10. 结论

本次需求的核心不是“再加一个 verify 工具”，而是把 verify 提升为主 agent loop 的显式治理节点。

推荐的系统分工应收敛为：

- `explorer` 负责找信息
- 主 agent 负责统筹、调用工具与子代理、推进状态机
- `reviewer` 负责审质量
- `executor` 负责跑验证命令
- `verifier` 负责判定是否真正完成
- `reflection` 负责在 verify 失败后组织下一轮修复策略

只有这样，主 agent loop 才能从“能跑一轮”升级为“能可靠收敛到已验证完成”。