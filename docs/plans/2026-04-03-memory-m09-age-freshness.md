# Memory M-09: Age / Freshness Normalization — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增 `MemoryAge.swift`，提供与 Claude Code `memoryAge.ts` 完全对齐的 `mtimeMs: Double` 参数的独立自由函数 API；同时简化 `RelevantMemoryRecallService.formatInjectionBlock()` 的调用点，消除手动 Date 转换。

**Architecture:**
`MemoryFreshnessAnnotator`（M-04 已完成，`Date`-based struct 方法）承担底层逻辑；`MemoryAge.swift` 在其上封装一层 `mtimeMs: Double` 参数的自由函数，与 Claude Code `memoryAge.ts` 的导出签名一一对应，使上层调用点无需 `Date(timeIntervalSince1970: mtimeMs / 1000)` 转换。不修改 `MemoryFreshnessAnnotator` 本身（保持现有测试通过）。

**Tech Stack:** Swift 6.0+, XCTest, 无 I/O 的纯函数

**参考源码（Claude Code 对标实现）:**
```
/Users/feint/Downloads/claude-code-source-code-main/src/memdir/memoryAge.ts
```

---

## 背景与现状

### 已完成（M-04 产出，不再重复）

| 文件 | 状态 |
|------|------|
| `agentGui/Utilities/MemoryFreshnessAnnotator.swift` | ✅ 存在，Date-based struct |
| `agentGuiTests/MemoryFreshnessAnnotatorTests.swift` | ✅ 存在，完整覆盖 |

### M-09 需要补充的内容

| 文件 | 状态 | 说明 |
|------|------|------|
| `agentGui/Utilities/MemoryAge.swift` | ❌ 缺失 | 新增：`mtimeMs`-based 自由函数 |
| `agentGuiTests/MemoryAgeTests.swift` | ❌ 缺失 | 新增：对应测试 |
| `RelevantMemoryRecallService.formatInjectionBlock()` | 🔧 需简化 | 消除内部 MemoryFreshnessAnnotator 实例化 |

### 与 Claude Code 的 API 对照

| Claude Code（`memoryAge.ts`） | agentGui M-09（`MemoryAge.swift`） |
|------|------|
| `memoryAgeDays(mtimeMs: number): number` | `func memoryAgeDays(_ mtimeMs: Double, now: Date = .now) -> Int` |
| `memoryAge(mtimeMs: number): string` // "today"/"yesterday"/"N days ago" | `func memoryAge(_ mtimeMs: Double, now: Date = .now) -> String` |
| `memoryFreshnessText(mtimeMs: number): string` | `func memoryFreshnessText(_ mtimeMs: Double, now: Date = .now) -> String` |
| `memoryFreshnessNote(mtimeMs: number): string` | `func memoryFreshnessNote(_ mtimeMs: Double, now: Date = .now) -> String` |

> **注意**：`memoryAge()` 使用英文（"today"/"yesterday"/"N days ago"），供模型可读的 prompt 注入。
> `MemoryFreshnessAnnotator.ageText()` 保留中文（"今天"/"昨天"/"N 天前"），用于 UI 展示，两者不冲突。

---

## Task 1: 新增 `MemoryAge.swift` — 自由函数 API

**Files:**
- Create: `agentGui/Utilities/MemoryAge.swift`
- Test: `agentGuiTests/MemoryAgeTests.swift`

---

### Step 1: 写出失败的测试

创建 `agentGuiTests/MemoryAgeTests.swift`：

```swift
import XCTest
@testable import agentGui

/// 测试 `MemoryAge.swift` 中与 Claude Code `memoryAge.ts` 对齐的自由函数。
///
/// 固定 `now = 2024-10-04T00:00:00Z`（unix: 86_400 * 20_000）以避免跨午夜偶发失败。
final class MemoryAgeTests: XCTestCase {

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 86_400 * 20_000)

    /// 将 "N 天前" 转换为 mtimeMs（毫秒）
    private func mtimeMsDaysAgo(_ days: Int) -> Double {
        (now.timeIntervalSince1970 - Double(days) * 86_400) * 1000
    }

    // MARK: - memoryAgeDays

    func test_memoryAgeDays_sameInstant_isZero() {
        XCTAssertEqual(memoryAgeDays(now.timeIntervalSince1970 * 1000, now: now), 0)
    }

    func test_memoryAgeDays_oneDayAgo_isOne() {
        XCTAssertEqual(memoryAgeDays(mtimeMsDaysAgo(1), now: now), 1)
    }

    func test_memoryAgeDays_futureMtime_clampsToZero() {
        let futureMtimeMs = (now.timeIntervalSince1970 + 86_400 * 5) * 1000
        XCTAssertEqual(memoryAgeDays(futureMtimeMs, now: now), 0,
                       "未来时间戳应截断到 0（时钟偏差场景）")
    }

    func test_memoryAgeDays_thirtyDays_isThirty() {
        XCTAssertEqual(memoryAgeDays(mtimeMsDaysAgo(30), now: now), 30)
    }

    // MARK: - memoryAge

    func test_memoryAge_today_returnsEnglishToday() {
        XCTAssertEqual(memoryAge(now.timeIntervalSince1970 * 1000, now: now), "today")
    }

    func test_memoryAge_yesterday_returnsEnglishYesterday() {
        XCTAssertEqual(memoryAge(mtimeMsDaysAgo(1), now: now), "yesterday")
    }

    func test_memoryAge_sevenDays_returnsNDaysAgo() {
        XCTAssertEqual(memoryAge(mtimeMsDaysAgo(7), now: now), "7 days ago")
    }

    func test_memoryAge_thirtyDays_returnsNDaysAgo() {
        XCTAssertEqual(memoryAge(mtimeMsDaysAgo(30), now: now), "30 days ago")
    }

    // MARK: - memoryFreshnessText

    func test_memoryFreshnessText_today_isEmpty() {
        XCTAssertTrue(
            memoryFreshnessText(now.timeIntervalSince1970 * 1000, now: now).isEmpty,
            "今天的记忆不应有 freshness 警告"
        )
    }

    func test_memoryFreshnessText_yesterday_isEmpty() {
        XCTAssertTrue(
            memoryFreshnessText(mtimeMsDaysAgo(1), now: now).isEmpty,
            "昨天的记忆不应有 freshness 警告（边界值）"
        )
    }

    func test_memoryFreshnessText_twoDays_containsAgeAndVerifyHint() {
        let text = memoryFreshnessText(mtimeMsDaysAgo(2), now: now)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("2 days old"),
                      "应明确输出 '2 days old'，模型不善做日期计算")
        XCTAssertTrue(text.contains("Verify"),
                      "应包含 Verify 提示引导 agent 核实")
        XCTAssertTrue(text.contains("point-in-time observations"),
                      "措辞应与 Claude Code memoryFreshnessText 对齐")
    }

    func test_memoryFreshnessText_sevenDays_containsCorrectAge() {
        let text = memoryFreshnessText(mtimeMsDaysAgo(7), now: now)
        XCTAssertTrue(text.contains("7 days old"))
    }

    func test_memoryFreshnessText_thirtyDays_containsCorrectAge() {
        let text = memoryFreshnessText(mtimeMsDaysAgo(30), now: now)
        XCTAssertTrue(text.contains("30 days old"))
    }

    // MARK: - memoryFreshnessNote

    func test_memoryFreshnessNote_today_isEmpty() {
        XCTAssertTrue(
            memoryFreshnessNote(now.timeIntervalSince1970 * 1000, now: now).isEmpty
        )
    }

    func test_memoryFreshnessNote_yesterday_isEmpty() {
        XCTAssertTrue(
            memoryFreshnessNote(mtimeMsDaysAgo(1), now: now).isEmpty,
            "≤1 天不应生成 <system-reminder> 节"
        )
    }

    func test_memoryFreshnessNote_twoDays_wrapsInSystemReminder() {
        let note = memoryFreshnessNote(mtimeMsDaysAgo(2), now: now)
        XCTAssertTrue(note.contains("<system-reminder>"))
        XCTAssertTrue(note.contains("</system-reminder>"))
        XCTAssertTrue(note.contains("2 days old"))
    }

    func test_memoryFreshnessNote_endsWithNewline() {
        let note = memoryFreshnessNote(mtimeMsDaysAgo(3), now: now)
        XCTAssertTrue(note.hasSuffix("\n"),
                      "freshnessNote 末尾应带换行，与 Claude Code 对齐")
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-m09-derived \
  -only-testing:agentGuiTests/MemoryAgeTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|PASS|MemoryAgeTests"
```

**预期**：编译错误 `use of unresolved identifier 'memoryAgeDays'`（函数未定义）

---

### Step 3: 实现 `MemoryAge.swift`

创建 `agentGui/Utilities/MemoryAge.swift`：

```swift
import Foundation

// MARK: - Memory Age Utilities
//
// 与 Claude Code `memoryAge.ts` 签名对齐的自由函数。
// `mtimeMs` 为 Unix 毫秒时间戳（来自 MemoryTopicHeader.mtimeMs）。
// 内部委托给 MemoryFreshnessAnnotator 避免逻辑重复。
//
// 与 MemoryFreshnessAnnotator 的分工：
//   - MemoryFreshnessAnnotator：Date 参数，供 UI 等已有 Date 对象的调用方使用
//   - MemoryAge（本文件）：mtimeMs: Double 参数，供 prompt 构建等直接处理扫描结果的调用方使用

private let _annotator = MemoryFreshnessAnnotator()

/// 距 `mtimeMs`（Unix 毫秒）的整数天数（floor-rounded）。
/// 未来时间戳截断到 0（应对时钟偏差）。
///
/// 对齐 Claude Code `memoryAgeDays(mtimeMs: number): number`
func memoryAgeDays(_ mtimeMs: Double, now: Date = .now) -> Int {
    let updatedAt = Date(timeIntervalSince1970: mtimeMs / 1000)
    return _annotator.ageDays(updatedAt: updatedAt, now: now)
}

/// `mtimeMs` 对应的人类可读年龄字符串（英文，供模型 prompt 使用）：
/// - 0 天 → "today"
/// - 1 天 → "yesterday"
/// - N 天 → "N days ago"
///
/// 对齐 Claude Code `memoryAge(mtimeMs: number): string`
///
/// > 注：UI 层需要中文时，请使用 `MemoryFreshnessAnnotator.ageText()`。
func memoryAge(_ mtimeMs: Double, now: Date = .now) -> String {
    let d = memoryAgeDays(mtimeMs, now: now)
    switch d {
    case 0:  return "today"
    case 1:  return "yesterday"
    default: return "\(d) days ago"
    }
}

/// 仅对 > 1 天的记忆返回纯文本陈旧性警告；否则返回空字符串。
///
/// 对齐 Claude Code `memoryFreshnessText(mtimeMs: number): string`
func memoryFreshnessText(_ mtimeMs: Double, now: Date = .now) -> String {
    let updatedAt = Date(timeIntervalSince1970: mtimeMs / 1000)
    return _annotator.freshnessText(updatedAt: updatedAt, now: now)
}

/// 带 `<system-reminder>` 包裹的陈旧性警告（末尾含换行）。
/// > 1 天时返回完整节；否则返回空字符串。
///
/// 对齐 Claude Code `memoryFreshnessNote(mtimeMs: number): string`
func memoryFreshnessNote(_ mtimeMs: Double, now: Date = .now) -> String {
    let updatedAt = Date(timeIntervalSince1970: mtimeMs / 1000)
    return _annotator.freshnessNote(updatedAt: updatedAt, now: now)
}
```

> **实现注意**：
> - 使用模块级私有 `_annotator` 常量（而非每次调用创建实例），避免不必要的结构体构造
> - `now: Date = .now` 默认参数确保可测试性（测试可注入固定时间）
> - 四个函数均为自由函数（global scope），与 Claude Code 的模块导出风格对齐

### Step 4: 运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-m09-derived \
  -only-testing:agentGuiTests/MemoryAgeTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed|MemoryAgeTests"
```

**预期**：`Test Suite 'MemoryAgeTests' passed`，全部 N 个 test 通过，0 个失败

### Step 5: 确认原有 `MemoryFreshnessAnnotatorTests` 也全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-m09-derived \
  -only-testing:agentGuiTests/MemoryFreshnessAnnotatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

**预期**：全部通过（`MemoryFreshnessAnnotator` 未被修改）

### Step 6: 提交

```bash
git add agentGui/Utilities/MemoryAge.swift agentGuiTests/MemoryAgeTests.swift
git commit -m "feat(memory): add MemoryAge.swift — mtimeMs-based free functions aligned to Claude Code memoryAge.ts"
```

---

## Task 2: 简化 `RelevantMemoryRecallService.formatInjectionBlock()`

**Files:**
- Modify: `agentGui/Services/Memory/RelevantMemoryRecallService.swift` (lines 99–112)
- Test: `agentGuiTests/RelevantMemoryRecallServiceTests.swift`（现有测试不应修改）

---

### Step 1: 读取当前实现，确认修改范围

现有代码（`RelevantMemoryRecallService.swift`，约 99–112 行）：

```swift
/// 格式化单个文件内容为 `<system-reminder>` 注入块，附加陈旧性警告。
static func formatInjectionBlock(
    filename: String,
    content: String,
    mtimeMs: Double,
    now: Date = .now
) -> String {
    let annotator = MemoryFreshnessAnnotator()       // ← 每次调用创建实例
    let updatedAt = Date(timeIntervalSince1970: mtimeMs / 1000)  // ← Date 转换
    let freshnessNote = annotator.freshnessNote(updatedAt: updatedAt, now: now)
    let header = "## Relevant Memory: \(filename)\n"
    return "<system-reminder>\n\(header)\(freshnessNote)\(content)\n</system-reminder>"
}
```

### Step 2: 验证现有测试仍覆盖关键行为

运行 `RelevantMemoryRecallServiceTests`，确认三个 `formatInjectionBlock` 测试通过：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-m09-derived \
  -only-testing:agentGuiTests/RelevantMemoryRecallServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAILED|passed|error:"
```

**预期**：全部通过（测试本身不变）

### Step 3: 替换实现

将 `formatInjectionBlock()` 改为直接调用 `memoryFreshnessNote(_:now:)` 自由函数：

```swift
/// 格式化单个文件内容为 `<system-reminder>` 注入块，附加陈旧性警告。
///
/// 使用 `memoryFreshnessNote(_:now:)` 自由函数（对齐 Claude Code `memoryAge.ts`），
/// 无需手动 Date 转换或实例化 MemoryFreshnessAnnotator。
static func formatInjectionBlock(
    filename: String,
    content: String,
    mtimeMs: Double,
    now: Date = .now
) -> String {
    let freshnessNote = memoryFreshnessNote(mtimeMs, now: now)
    let header = "## Relevant Memory: \(filename)\n"
    return "<system-reminder>\n\(header)\(freshnessNote)\(content)\n</system-reminder>"
}
```

> **修改范围**：只改函数体前两行（删除 `let annotator`、`let updatedAt`；更新 `freshnessNote` 赋值），其余不变。

### Step 4: 运行测试，确认现有测试仍通过（行为不变）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-m09-derived \
  -only-testing:agentGuiTests/RelevantMemoryRecallServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAILED|passed|error:"
```

**预期**：全部通过，行为与修改前完全一致

### Step 5: 提交

```bash
git add agentGui/Services/Memory/RelevantMemoryRecallService.swift
git commit -m "refactor(memory): simplify formatInjectionBlock — use memoryFreshnessNote() free function"
```

---

## Task 3: 全量回归

### Step 1: 运行 M-09 相关所有测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m09-final-derived \
  -only-testing:agentGuiTests/MemoryAgeTests \
  -only-testing:agentGuiTests/MemoryFreshnessAnnotatorTests \
  -only-testing:agentGuiTests/RelevantMemoryRecallServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAILED|passed|error:"
```

**预期**：三个 suite 全部通过

### Step 2: 确认编译无警告

```bash
xcodebuild build \
  -quiet \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-m09-final-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "warning:|error:|BUILD"
```

**预期**：`BUILD SUCCEEDED`，无与 `MemoryFreshnessAnnotator` 或 `MemoryAge` 相关的 warning

### Step 3: 最终提交（如 Task 1/2 已分开提交，则可跳过）

---

## 完成标志（Acceptance Criteria）

- [x] `agentGui/Utilities/MemoryAge.swift` 存在，含四个与 Claude Code `memoryAge.ts` 对齐的自由函数
- [x] `agentGuiTests/MemoryAgeTests.swift` 存在，覆盖：`ageDays=0/1/future/30`、`age=today/yesterday/N days ago`、`freshnessText` 空/非空边界、`freshnessNote` wrapping + newline
- [x] `RelevantMemoryRecallService.formatInjectionBlock()` 不再包含 `MemoryFreshnessAnnotator()` 实例化或 `Date(timeIntervalSince1970: mtimeMs / 1000)` 转换
- [x] 超过 1 天的 recalled 记忆注入块含 freshness 警告；今天/昨天的不含
- [x] `MemoryFreshnessAnnotatorTests` 全部通过（现有行为未被破坏）
- [x] 全量编译零 warning

---

## 参考：Claude Code `memoryAge.ts` 完整实现

```typescript
// src/memdir/memoryAge.ts

export function memoryAgeDays(mtimeMs: number): number {
  return Math.max(0, Math.floor((Date.now() - mtimeMs) / 86_400_000))
}

export function memoryAge(mtimeMs: number): string {
  const d = memoryAgeDays(mtimeMs)
  if (d === 0) return 'today'
  if (d === 1) return 'yesterday'
  return `${d} days ago`
}

export function memoryFreshnessText(mtimeMs: number): string {
  const d = memoryAgeDays(mtimeMs)
  if (d <= 1) return ''
  return (
    `This memory is ${d} days old. ` +
    `Memories are point-in-time observations, not live state — ` +
    `claims about code behavior or file:line citations may be outdated. ` +
    `Verify against current code before asserting as fact.`
  )
}

export function memoryFreshnessNote(mtimeMs: number): string {
  const text = memoryFreshnessText(mtimeMs)
  if (!text) return ''
  return `<system-reminder>${text}</system-reminder>\n`
}
```
