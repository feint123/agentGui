# M-04 Memory Freshness Annotator — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为超过 1 天的记忆添加陈旧性警告，在 RMSInsight bootstrap prompt 路径和 MemoryRecord topic file 路径都生效，防止 agent 把过期的代码状态断言为当前事实。

**Architecture:**
新建纯逻辑 `MemoryFreshnessAnnotator`（nonisolated struct），提供 `ageDays` / `ageText` / `freshnessText` / `freshnessNote` 四个方法。再将其注入两条渲染路径：①`RMSPromptComposer.formattedInsightSummary`（RMSInsight bootstrap 路径）；②`MemoryTopicFileComposer.compose`（MemoryRecord 话题文件路径）。两条路径都通过 `now: Date = .now` 参数保证可测试性。

**Tech Stack:** Swift 6.0+, XCTest, nonisolated struct（无 I/O）

**参考源码（Claude Code 对标实现）:**
- `/Users/feint/Downloads/claude-code-source-code-main/src/memdir/memoryAge.ts`

---

## 背景与现状

| 路径 | 文件 | 现状 |
|------|------|------|
| RMSInsight bootstrap | `Services/RMSPromptComposer.swift` | `formattedInsightSummary` 只附加 evidenceRefs，无时效性注解 |
| MemoryRecord topic 文件 | `Services/Memory/MemoryTopicFileComposer.swift` | frontmatter 含 `updated:` ISO8601，但 agent 依赖模型做日期计算，效果差 |
| MemoryIndexWriter | `Services/Memory/MemoryIndexWriter.swift` | 调用 `topicComposer.compose(record:)`，需传递 `now` |
| MemoryIndexFileSystem | `Services/Memory/MemoryIndexFileSystem.swift` | 调用 `writer.build(records:)`，需传递 `now` |

**关键约束（来自 Claude Code 注释）：**
> "Models are poor at date arithmetic — a raw ISO timestamp doesn't trigger staleness reasoning the way '47 days ago' does."

`memoryFreshnessText` 只在 > 1 天时输出警告，避免 today/yesterday 引入噪音。

---

## Task 1: MemoryFreshnessAnnotator — 核心逻辑

**Files:**
- Create: `agentGui/Utilities/MemoryFreshnessAnnotator.swift`
- Test: `agentGuiTests/MemoryFreshnessAnnotatorTests.swift`

---

**Step 1: 写出失败的测试**

创建 `agentGuiTests/MemoryFreshnessAnnotatorTests.swift`：

```swift
import XCTest
@testable import agentGui

final class MemoryFreshnessAnnotatorTests: XCTestCase {

    private let annotator = MemoryFreshnessAnnotator()

    // 固定 now，避免跨午夜边界的偶发失败
    private let now = Date(timeIntervalSince1970: 86_400 * 20_000)  // 2024-10-04T00:00:00Z

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    // MARK: - ageDays

    func test_ageDays_sameMoment_isZero() {
        XCTAssertEqual(annotator.ageDays(updatedAt: now, now: now), 0)
    }

    func test_ageDays_oneDay_isOne() {
        XCTAssertEqual(annotator.ageDays(updatedAt: daysAgo(1), now: now), 1)
    }

    func test_ageDays_futureMtime_clampsToZero() {
        let future = now.addingTimeInterval(86_400 * 5)
        XCTAssertEqual(annotator.ageDays(updatedAt: future, now: now), 0,
                       "未来时间戳应截断到 0（处理时钟偏差）")
    }

    func test_ageDays_thirtyDays_isThirty() {
        XCTAssertEqual(annotator.ageDays(updatedAt: daysAgo(30), now: now), 30)
    }

    func test_ageDays_sevenDays_isSeven() {
        XCTAssertEqual(annotator.ageDays(updatedAt: daysAgo(7), now: now), 7)
    }

    // MARK: - ageText

    func test_ageText_today_returnsToday() {
        XCTAssertEqual(annotator.ageText(updatedAt: now, now: now), "今天")
    }

    func test_ageText_yesterday_returnsYesterday() {
        XCTAssertEqual(annotator.ageText(updatedAt: daysAgo(1), now: now), "昨天")
    }

    func test_ageText_sevenDays_returnsDaysAgo() {
        XCTAssertEqual(annotator.ageText(updatedAt: daysAgo(7), now: now), "7 天前")
    }

    func test_ageText_thirtyDays_returnsThirtyDaysAgo() {
        XCTAssertEqual(annotator.ageText(updatedAt: daysAgo(30), now: now), "30 天前")
    }

    // MARK: - freshnessText

    func test_freshnessText_today_isEmpty() {
        XCTAssertTrue(annotator.freshnessText(updatedAt: now, now: now).isEmpty,
                      "今天的记忆不应有 freshness warning")
    }

    func test_freshnessText_yesterday_isEmpty() {
        XCTAssertTrue(annotator.freshnessText(updatedAt: daysAgo(1), now: now).isEmpty,
                      "昨天的记忆不应有 freshness warning（边界值）")
    }

    func test_freshnessText_twoDays_containsAgeAndVerifyHint() {
        let text = annotator.freshnessText(updatedAt: daysAgo(2), now: now)
        XCTAssertFalse(text.isEmpty, "2 天前的记忆应有 freshness warning")
        XCTAssertTrue(text.contains("2 days old"),
                      "应明确写出 '2 days old' — 模型不善做日期计算")
        XCTAssertTrue(text.contains("Verify"),
                      "应包含 Verify 提示，引导 agent 核实")
    }

    func test_freshnessText_sevenDays_containsCorrectAge() {
        let text = annotator.freshnessText(updatedAt: daysAgo(7), now: now)
        XCTAssertTrue(text.contains("7 days old"))
    }

    func test_freshnessText_thirtyDays_containsCorrectAge() {
        let text = annotator.freshnessText(updatedAt: daysAgo(30), now: now)
        XCTAssertTrue(text.contains("30 days old"))
    }

    // MARK: - freshnessNote

    func test_freshnessNote_yesterday_isEmpty() {
        let note = annotator.freshnessNote(updatedAt: daysAgo(1), now: now)
        XCTAssertTrue(note.isEmpty,
                      "≤1 天的记忆不应生成 <system-reminder> 节")
    }

    func test_freshnessNote_twoDays_wrapsInSystemReminder() {
        let note = annotator.freshnessNote(updatedAt: daysAgo(2), now: now)
        XCTAssertTrue(note.contains("<system-reminder>"),
                      "freshness note 应以 <system-reminder> 开头")
        XCTAssertTrue(note.contains("</system-reminder>"),
                      "freshness note 应以 </system-reminder> 结尾")
        XCTAssertTrue(note.contains("2 days old"))
    }

    func test_freshnessNote_today_isEmpty() {
        let note = annotator.freshnessNote(updatedAt: now, now: now)
        XCTAssertTrue(note.isEmpty)
    }
}
```

---

**Step 2: 运行测试，确认编译失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryFreshnessAnnotatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：编译失败 — `MemoryFreshnessAnnotator` 不存在

---

**Step 3: 实现最小代码**

创建 `agentGui/Utilities/MemoryFreshnessAnnotator.swift`：

```swift
import Foundation

/// 计算记忆条目年龄并生成陈旧性警告文本。
///
/// 对齐 Claude Code `memoryAge.ts` 的设计：
/// - 用人类可读的 "N days old" 替代原始 ISO 时间戳，
///   因为模型不善做日期计算，而 "47 days ago" 能直接触发陈旧性推理。
/// - 仅对 > 1 天的记忆输出警告，避免 today/yesterday 引入噪音。
///
/// nonisolated struct，无副作用，可在任意并发上下文调用。
struct MemoryFreshnessAnnotator: Sendable {

    /// 距 `updatedAt` 的整数天数（floor-rounded）。
    ///
    /// - 今天更新 → 0；昨天 → 1；N 天前 → N
    /// - 未来时间戳（时钟偏差）截断到 0
    func ageDays(updatedAt: Date, now: Date = .now) -> Int {
        max(0, Int((now.timeIntervalSince1970 - updatedAt.timeIntervalSince1970) / 86_400))
    }

    /// 人类可读的年龄字符串，供 UI 列表显示：今天 / 昨天 / N 天前。
    func ageText(updatedAt: Date, now: Date = .now) -> String {
        let d = ageDays(updatedAt: updatedAt, now: now)
        switch d {
        case 0:  return "今天"
        case 1:  return "昨天"
        default: return "\(d) 天前"
        }
    }

    /// 仅对 > 1 天的记忆返回纯文本陈旧性警告；否则返回空字符串。
    ///
    /// 用于 `RMSPromptComposer` 等已有 system-reminder 包裹的调用方。
    func freshnessText(updatedAt: Date, now: Date = .now) -> String {
        let d = ageDays(updatedAt: updatedAt, now: now)
        guard d > 1 else { return "" }
        return "This memory is \(d) days old. " +
               "Memories are point-in-time observations, not live state — " +
               "claims about code behavior or file:line citations may be outdated. " +
               "Verify against current code before asserting as fact."
    }

    /// 带 `<system-reminder>` 包裹的版本，用于 topic file 内嵌注入。
    ///
    /// > 1 天时返回完整 reminder 节（末尾带换行）；否则返回空字符串。
    func freshnessNote(updatedAt: Date, now: Date = .now) -> String {
        let text = freshnessText(updatedAt: updatedAt, now: now)
        guard !text.isEmpty else { return "" }
        return "<system-reminder>\(text)</system-reminder>\n"
    }
}
```

---

**Step 4: 运行测试，确认全部通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryFreshnessAnnotatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`Test Suite 'MemoryFreshnessAnnotatorTests' passed`

---

**Step 5: Commit**

```bash
git add agentGui/Utilities/MemoryFreshnessAnnotator.swift \
        agentGuiTests/MemoryFreshnessAnnotatorTests.swift
git commit -m "feat(memory): add MemoryFreshnessAnnotator — M-04 core logic"
```

---

## Task 2: RMSPromptComposer — Insight Freshness 注入

**Files:**
- Modify: `agentGui/Services/RMSPromptComposer.swift`（`formattedInsightSummary` 方法）
- Test: `agentGuiTests/RMSPromptComposerFreshnessTests.swift`（新建）

---

**Step 1: 写出失败的测试**

创建 `agentGuiTests/RMSPromptComposerFreshnessTests.swift`：

```swift
import XCTest
@testable import agentGui

final class RMSPromptComposerFreshnessTests: XCTestCase {

    private let composer = RMSPromptComposer()

    private func makeState() -> RMSState {
        RMSState(taskID: "t1", sessionID: "s1", threadID: "th1", summary: "coding task")
    }

    private func makeConstraintInsight(updatedAt: Date?) -> RMSInsight {
        RMSInsight(
            id: "insight-constraint",
            kind: .constraint,
            summary: "Always run tests before merging",
            appliesWhen: "coding",
            changesDecision: "Run tests first",
            evidenceRefs: [],
            updatedAt: updatedAt
        )
    }

    private func makeTacticInsight(updatedAt: Date?) -> RMSInsight {
        RMSInsight(
            id: "insight-tactic",
            kind: .tactic,
            summary: "Use xcodebuild targeted runs",
            appliesWhen: "xcodebuild",
            changesDecision: "Use focused invocation",
            evidenceRefs: [],
            updatedAt: updatedAt
        )
    }

    // MARK: - 新鲜 insight（今天更新）— 不应有警告

    func test_freshInsight_noFreshnessWarning() {
        // updatedAt = 当前时间，ageDays = 0
        let insight = makeConstraintInsight(updatedAt: .now)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertFalse(output.contains("days old"),
                       "今天更新的 insight 不应附加 freshness warning")
    }

    // MARK: - 陈旧 insight（7 天前）— 应有警告

    func test_staleInsight_constraintKind_containsFreshnessWarning() {
        let sevenDaysAgo = Date.now.addingTimeInterval(-86_400 * 7)
        let insight = makeConstraintInsight(updatedAt: sevenDaysAgo)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertTrue(output.contains("7 days old"),
                      "7 天前的 constraint insight 应在 prompt 中包含 '7 days old' 警告")
    }

    func test_staleInsight_tacticKind_containsFreshnessWarning() {
        let tenDaysAgo = Date.now.addingTimeInterval(-86_400 * 10)
        let insight = makeTacticInsight(updatedAt: tenDaysAgo)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertTrue(output.contains("10 days old"),
                      "10 天前的 tactic insight 应在 prompt 中包含警告")
    }

    // MARK: - nil updatedAt — 不应有警告

    func test_nilUpdatedAt_noFreshnessWarning() {
        let insight = makeConstraintInsight(updatedAt: nil)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertFalse(output.contains("days old"),
                       "nil updatedAt 的 insight 不应附加 freshness warning")
    }

    // MARK: - 昨天更新 — 不应有警告（边界值）

    func test_yesterdayInsight_noFreshnessWarning() {
        let yesterday = Date.now.addingTimeInterval(-86_400)
        let insight = makeConstraintInsight(updatedAt: yesterday)
        let output = composer.compose(state: makeState(), activatedInsights: [insight])
        XCTAssertFalse(output.contains("days old"),
                       "昨天更新的 insight（ageDays=1）不应有警告")
    }

    // MARK: - evidenceRefs + freshness 共存

    func test_staleInsight_withEvidenceRefs_bothPresent() {
        let sevenDaysAgo = Date.now.addingTimeInterval(-86_400 * 7)
        var insight = makeConstraintInsight(updatedAt: sevenDaysAgo)
        // 重建带 evidenceRefs 的版本
        let insightWithEvidence = RMSInsight(
            id: "e-insight",
            kind: .constraint,
            summary: "Always run tests",
            appliesWhen: "coding",
            changesDecision: "Run tests first",
            evidenceRefs: ["round-42"],
            updatedAt: sevenDaysAgo
        )
        let output = composer.compose(state: makeState(), activatedInsights: [insightWithEvidence])
        XCTAssertTrue(output.contains("round-42"),
                      "evidenceRefs 应保留")
        XCTAssertTrue(output.contains("7 days old"),
                      "freshness warning 应与 evidenceRefs 共存")
    }
}
```

---

**Step 2: 运行测试，确认 `test_staleInsight_*` 失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/RMSPromptComposerFreshnessTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

预期：`test_staleInsight_constraintKind_containsFreshnessWarning` 等 FAIL

---

**Step 3: 修改 `RMSPromptComposer.formattedInsightSummary`**

定位 `agentGui/Services/RMSPromptComposer.swift` 末尾的 `formattedInsightSummary` 方法：

```swift
// 修改前
private func formattedInsightSummary(_ insight: RMSInsight) -> String {
    guard !insight.evidenceRefs.isEmpty else {
        return insight.summary
    }
    return "\(insight.summary) [evidence: \(insight.evidenceRefs.joined(separator: ", "))]"
}
```

替换为：

```swift
// 修改后
private func formattedInsightSummary(_ insight: RMSInsight) -> String {
    var base = insight.summary
    if !insight.evidenceRefs.isEmpty {
        base += " [evidence: \(insight.evidenceRefs.joined(separator: ", "))]"
    }
    if let updatedAt = insight.updatedAt {
        let note = MemoryFreshnessAnnotator().freshnessText(updatedAt: updatedAt)
        if !note.isEmpty {
            base += " — ⚠️ \(note)"
        }
    }
    return base
}
```

---

**Step 4: 运行测试，确认全部通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/RMSPromptComposerFreshnessTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`Test Suite 'RMSPromptComposerFreshnessTests' passed`

---

**Step 5: Commit**

```bash
git add agentGui/Services/RMSPromptComposer.swift \
        agentGuiTests/RMSPromptComposerFreshnessTests.swift
git commit -m "feat(memory): wire MemoryFreshnessAnnotator into RMSPromptComposer — M-04"
```

---

## Task 3: MemoryTopicFileComposer — Topic File Freshness 注入

**Files:**
- Modify: `agentGui/Services/Memory/MemoryTopicFileComposer.swift`
- Modify: `agentGui/Services/Memory/MemoryIndexWriter.swift`（透传 `now`）
- Modify: `agentGui/Services/Memory/MemoryIndexFileSystem.swift`（透传 `now`）
- Test: `agentGuiTests/MemoryTopicFileComposerTests.swift`（追加测试）

**设计说明：**
`MemoryIndexFileSystem.rebuild(with:)` 每次写入都重建所有话题文件。在 rebuild 时传入 `now`，使每次重建后 topic 文件携带当前准确的陈旧天数。当 agent 通过文件工具读取话题文件时，看到的是上次 rebuild 时的陈旧性注解，这比让模型自己解析 ISO 日期再算年龄准确得多。

---

**Step 1: 在 `MemoryTopicFileComposerTests.swift` 追加失败测试**

打开 `agentGuiTests/MemoryTopicFileComposerTests.swift`，在 `// MARK: - YAML value quoting` 节后追加：

```swift
// MARK: - Freshness note (M-04)

func test_compose_freshRecord_noFreshnessNote() {
    let now = Date(timeIntervalSince1970: 86_400 * 20_000)
    let record = makeRecord(updatedAt: now)
    let output = composer.compose(record: record, now: now)
    XCTAssertFalse(output.contains("days old"),
                   "今天更新的 topic 文件不应包含 freshness note")
    XCTAssertFalse(output.contains("<system-reminder>"),
                   "今天更新的 topic 文件不应有 <system-reminder> 节")
}

func test_compose_staleRecord_containsFreshnessNote() {
    let now = Date(timeIntervalSince1970: 86_400 * 20_000)
    let staleDate = now.addingTimeInterval(-86_400 * 5)  // 5 天前
    let record = makeRecord(updatedAt: staleDate)
    let output = composer.compose(record: record, now: now)
    XCTAssertTrue(output.contains("5 days old"),
                  "5 天前更新的话题文件应包含 '5 days old' 警告")
    XCTAssertTrue(output.contains("<system-reminder>"),
                  "freshness note 应用 <system-reminder> 包裹")
    XCTAssertTrue(output.contains("</system-reminder>"),
                  "freshness note 应包含闭合标签")
}

func test_compose_freshnessNoteAppearsBeforeBody() {
    let now = Date(timeIntervalSince1970: 86_400 * 20_000)
    let staleDate = now.addingTimeInterval(-86_400 * 3)
    let record = makeRecord(updatedAt: staleDate, payloadText: "BODYMARKER")
    let output = composer.compose(record: record, now: now)
    guard let reminderRange = output.range(of: "<system-reminder>"),
          let bodyRange = output.range(of: "BODYMARKER") else {
        XCTFail("output 应同时包含 <system-reminder> 和 BODYMARKER")
        return
    }
    XCTAssertLessThan(reminderRange.lowerBound, bodyRange.lowerBound,
                      "<system-reminder> 应出现在正文之前")
}

func test_compose_freshnessBoundary_oneDay_noNote() {
    let now = Date(timeIntervalSince1970: 86_400 * 20_000)
    let yesterday = now.addingTimeInterval(-86_400)
    let record = makeRecord(updatedAt: yesterday)
    let output = composer.compose(record: record, now: now)
    XCTAssertFalse(output.contains("days old"),
                   "昨天更新（ageDays=1）不应触发 freshness note")
}
```

注意：`makeRecord` 需要支持 `updatedAt` 参数。检查现有 `makeRecord` 私有方法，若不含 `updatedAt` 参数则追加。`MemoryRecord.fixture` 已有 `updatedAt` 参数，调用方式参考 `MemoryTopicFileComposerTests` 已有 helper。

---

**Step 2: 运行测试，确认编译或测试失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryTopicFileComposerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

预期：`test_compose_staleRecord_containsFreshnessNote` 等编译失败（`compose` 不接受 `now:` 参数）

---

**Step 3: 修改 `MemoryTopicFileComposer.compose`**

定位 `agentGui/Services/Memory/MemoryTopicFileComposer.swift` 中的 `compose(record:)` 方法：

```swift
// 修改前
func compose(record: MemoryRecord) -> String {
    let created = Self.dateFormatter.string(from: record.createdAt)
    let updated = Self.dateFormatter.string(from: record.updatedAt)
    let body = bodyText(from: record)

    return """
    ---
    name: \(yamlQuote(record.title))
    description: \(yamlQuote(record.summary))
    type: \(record.kind.rawValue)
    id: \(record.id)
    scope: \(record.scope.namespace)
    created: \(created)
    updated: \(updated)
    ---

    \(body)
    """
}
```

替换为：

```swift
// 修改后
func compose(record: MemoryRecord, now: Date = .now) -> String {
    let created = Self.dateFormatter.string(from: record.createdAt)
    let updated = Self.dateFormatter.string(from: record.updatedAt)
    let body = bodyText(from: record)
    let freshnessPrefix = MemoryFreshnessAnnotator().freshnessNote(updatedAt: record.updatedAt, now: now)

    return """
    ---
    name: \(yamlQuote(record.title))
    description: \(yamlQuote(record.summary))
    type: \(record.kind.rawValue)
    id: \(record.id)
    scope: \(record.scope.namespace)
    created: \(created)
    updated: \(updated)
    ---

    \(freshnessPrefix)\(body)
    """
}
```

---

**Step 4: 修改 `MemoryIndexWriter.build` 透传 `now`**

定位 `agentGui/Services/Memory/MemoryIndexWriter.swift` 中 `build(records:)` 方法签名：

```swift
// 修改前
func build(records: [MemoryRecord]) -> Output {
```

替换为：

```swift
// 修改后
func build(records: [MemoryRecord], now: Date = .now) -> Output {
```

同文件中，找到调用 `topicComposer.compose(record: record)` 的行（在 `for record in sorted` 循环内）：

```swift
// 修改前
topicFiles.append((filename, topicComposer.compose(record: record)))
```

替换为：

```swift
// 修改后
topicFiles.append((filename, topicComposer.compose(record: record, now: now)))
```

---

**Step 5: 修改 `MemoryIndexFileSystem.rebuild` 透传 `now`**

定位 `agentGui/Services/Memory/MemoryIndexFileSystem.swift` 中的 `rebuild(with:)` 方法：

```swift
// 修改前
func rebuild(with records: [MemoryRecord]) throws {
    let output = writer.build(records: records)
```

替换为：

```swift
// 修改后
func rebuild(with records: [MemoryRecord], now: Date = .now) throws {
    let output = writer.build(records: records, now: now)
```

---

**Step 6: 运行三个文件的测试，确认全部通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryTopicFileComposerTests \
  -only-testing:agentGuiTests/MemoryIndexWriterTests \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

预期：所有测试通过。

> **注意：** `MemoryIndexWriterTests.makeRecord` 使用 `createdAt: Date(timeIntervalSince1970: 0)`，未指定 `updatedAt`，因此 fixture 的 `updatedAt` 也是 epoch（1970）。默认 `now = .now` 会使这些记录触发 freshness note。已有测试只检查 `topicFiles[0].content.hasPrefix("---")`，**不会**因 freshness prefix 而失败。若存在检查 body 精确内容的测试，需要给 `now` 传入固定值（与测试的 `updatedAt` 相同）以禁用 freshness note。

---

**Step 7: Commit**

```bash
git add agentGui/Services/Memory/MemoryTopicFileComposer.swift \
        agentGui/Services/Memory/MemoryIndexWriter.swift \
        agentGui/Services/Memory/MemoryIndexFileSystem.swift \
        agentGuiTests/MemoryTopicFileComposerTests.swift
git commit -m "feat(memory): add freshness note to MemoryTopicFileComposer/IndexWriter — M-04"
```

---

## Task 4: 完整冒烟测试 + 最终 Commit

**Step 1: 运行所有 M-04 相关测试组**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m04-derived \
  -only-testing:agentGuiTests/MemoryFreshnessAnnotatorTests \
  -only-testing:agentGuiTests/RMSPromptComposerFreshnessTests \
  -only-testing:agentGuiTests/MemoryTopicFileComposerTests \
  -only-testing:agentGuiTests/MemoryIndexWriterTests \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  -only-testing:agentGuiTests/MemorySystemPromptInjectionTests \
  -only-testing:agentGuiTests/MemoryIndexReaderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`** TEST EXECUTE SUCCEEDED **`，所有 Test Suite pass。

---

**Step 2: 空 Tag commit**

```bash
git commit --allow-empty -m "feat(memory): M-04 Memory Freshness Annotator — implementation complete"
```

---

## 测试覆盖摘要

| 测试文件 | 覆盖内容 |
|----------|----------|
| `MemoryFreshnessAnnotatorTests` | ageDays 0/1/7/30/future；ageText；freshnessText 边界（0/1/2/7/30天）；freshnessNote 包裹格式 |
| `RMSPromptComposerFreshnessTests` | fresh/stale/nil/yesterday constraint+tactic；evidenceRefs 共存 |
| `MemoryTopicFileComposerTests`（追加）| fresh/stale/boundary-1day/注入顺序（freshnessNote before body）|
| `MemoryIndexWriterTests`（回归） | 确保 `build(records:now:)` 默认参数不破坏已有测试 |
| `MemoryIndexFileSystemTests`（回归） | 确保 `rebuild(with:now:)` 默认参数不破坏已有测试 |

---

## UI 备注（非本 Sprint 工作）

`MemoryFreshnessAnnotator.ageText(updatedAt:now:)` 已为 M-10 Memory Health UI 提供 "X 天前" 的格式化方法，无需额外改动。当 M-10 实现记忆列表视图时，直接调用此方法，传入 `MemoryRecord.updatedAt` 即可。

---

## 关键设计决策

1. **不在写入时硬编码绝对日期**：freshness note 在每次 `rebuild` 时按 `now` 计算，所以只要文件被定期 rebuild（每次新记忆持久化时），陈旧天数就会保持准确。
2. **`now: Date = .now` 参数注入**：所有涉及时间比较的方法都暴露 `now` 参数，确保测试可用固定时间戳，彻底消除时区/夜间边界的偶发失败。
3. **> 1 天阈值**：today (0) 和 yesterday (1) 不产生噪音；从 2 天起才触发警告，与 Claude Code 做法一致。
4. **`MemoryRecord.updatedAt` 非可选**：直接使用，无需 guard；`RMSInsight.updatedAt` 是 `Date?`，需 guard let 后才能传给 annotator。
