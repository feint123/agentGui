# F-C4: VerificationEvidenceHook 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 bash/terminal 工具执行后自动检测是否为测试运行，提炼 pass/fail 摘要并附加到 ToolCall 时间线；同时在 agent 完成全部 todo 但缺少测试验证时注入 nudge 消息，避免跳过验证直接结束。

**Architecture:** 新增一个符合 `ToolExecutionHook` 协议的 `VerificationEvidenceHook` struct，注册到现有 `ToolExecutionHookPipeline`；用一个 `VerificationEvidenceStore` actor 在内存中维护每个 session 的测试证据记录；test command 检测完全基于正则，不调用 LLM。

**Tech Stack:** Swift 6, `ToolExecutionHook` 协议（已有），`ToolExecutionHookPipeline`（已有），`AgentLoopToolExecutionCoordinatorBuilder`（接入点），XCTest。

---

## 背景与上下文

### 依赖关系

| 组件 | 路径 | 说明 |
|---|---|---|
| `ToolExecutionHook` 协议 | `Services/ToolGovernance/ToolExecutionHookPipeline.swift` | 本 hook 须实现此协议的三个方法 |
| `ToolRunRecord` | 同上 | postExecute 的入参，含 `toolName`、`input`、`result.text` |
| `ToolCallPreview` | 同上 | preExecute / postFailure 的入参 |
| `ChangeReviewHook` | `Services/ToolGovernance/Hooks/ChangeReviewHook.swift` | 样板参考 |
| `AgentLoopToolExecutionCoordinatorBuilder` | `Services/AgentLoopToolExecutionCoordinatorBuilder.swift` | 注册点，已有注释 `// F-C4 VerificationEvidenceHook 将在此追加` |
| `AgentLoopToolExecutionCoordinator` | `Services/AgentLoopToolExecutionCoordinator.swift` | 当前 `ToolRunRecord.sessionID` 硬编码为 `""` —— 须在同一PR修复 |
| `TodoItem` / `TodoStatus` | `Models/TodoItem.swift` | nudge 条件：分析 `input["items"]` |
| `SessionTaskStateStore` | `Services/SessionTaskStateStore.swift` | 可选：用于跨 hook 读取当前 session 的 todo |

### 现有验证体系

`AgentLoopVerificationCoordinator` 和 `VerificationEvidenceSupport` 已处理"模型输出声称已验证"的 AI 判定逻辑，**本 F-C4 不触碰那套流程**。F-C4 只在**工具执行层**补充一条平行记录：「bash 层面确实跑了测试命令，输出有 pass/fail 数据」。

---

## 新增文件清单

```
agentGui/Services/ToolGovernance/
  VerificationEvidenceStore.swift          ← Task 1  (actor)
  TestCommandDetector.swift                ← Task 2  (struct / static funcs)
  Hooks/
    VerificationEvidenceHook.swift         ← Task 4  (hook impl)

agentGuiTests/
  VerificationEvidenceStoreTests.swift     ← Task 3
  TestCommandDetectorTests.swift           ← Task 2 (TDD: 先写测试)
  VerificationEvidenceHookTests.swift      ← Task 5
```

**修改文件清单：**

```
agentGui/Services/AgentLoopToolExecutionCoordinator.swift   ← Task 6 (传 sessionID)
agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift  ← Task 7 (注册 hook)
```

---

## Task 1 — 定义 `VerificationEvidenceSummary` 与 `VerificationEvidenceStore`

**Files:**
- Create: `agentGui/Services/ToolGovernance/VerificationEvidenceStore.swift`

**Step 1: 创建文件，写入结构体和 actor**

```swift
import Foundation

// MARK: - VerificationEvidenceSummary

/// Lightweight record of a test run detected in a bash tool result.
/// Stored per session in `VerificationEvidenceStore`.
struct VerificationEvidenceSummary: Sendable, Equatable {
    /// The exact test command string (or a truncation up to 200 chars).
    let command: String
    /// Number of passing tests parsed from output. `nil` if unable to extract.
    let passCount: Int?
    /// Number of failing tests parsed from output. `nil` if unable to extract.
    let failCount: Int?
    /// First failing test name / error excerpt, up to 120 chars.
    let failureSummary: String?
    /// Whether the process exited with code 0 (success).
    let exitedZero: Bool
    let capturedAt: Date
}

// MARK: - VerificationEvidenceStore

/// Per-session, in-memory store of test-run verification evidence.
/// Scoped to the process lifetime; not persisted to SwiftData.
///
/// Thread-safe via actor isolation.
actor VerificationEvidenceStore {
    private var evidenceBySession: [String: [VerificationEvidenceSummary]] = [:]

    /// Record one piece of test evidence for the given session.
    func record(_ summary: VerificationEvidenceSummary, sessionID: String) {
        evidenceBySession[sessionID, default: []].append(summary)
    }

    /// Whether the session has at least one recorded test run.
    func hasEvidence(for sessionID: String) -> Bool {
        !(evidenceBySession[sessionID]?.isEmpty ?? true)
    }

    /// All recorded evidence for a session (for UI / debugging).
    func evidence(for sessionID: String) -> [VerificationEvidenceSummary] {
        evidenceBySession[sessionID] ?? []
    }

    /// Clear evidence for a session (e.g. on session close / reset).
    func clearEvidence(for sessionID: String) {
        evidenceBySession.removeValue(forKey: sessionID)
    }
}
```

**Step 2: 构建验证 - 无编译错误**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

**Step 3: Commit**

```
git add agentGui/Services/ToolGovernance/VerificationEvidenceStore.swift
git commit -m "feat(F-C4): add VerificationEvidenceSummary + VerificationEvidenceStore actor"
```

---

## Task 2 — TDD：`TestCommandDetector` 测试先行

**Files:**
- Create test first: `agentGuiTests/TestCommandDetectorTests.swift`
- Create impl: `agentGui/Services/ToolGovernance/TestCommandDetector.swift`

### Step 1: 写测试（先行）

```swift
import XCTest
@testable import agentGui

final class TestCommandDetectorTests: XCTestCase {

    // MARK: - isTestCommand

    func test_xcodebuild_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("xcodebuild test -scheme agentGui"))
    }

    func test_xcodebuild_build_isNotTest() {
        XCTAssertFalse(TestCommandDetector.isTestCommand("xcodebuild build -scheme agentGui"))
    }

    func test_swift_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("swift test"))
    }

    func test_npm_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("npm test"))
    }

    func test_yarn_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("yarn test"))
    }

    func test_jest_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("npx jest"))
        XCTAssertTrue(TestCommandDetector.isTestCommand("jest --watch"))
    }

    func test_pytest_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("pytest tests/"))
        XCTAssertTrue(TestCommandDetector.isTestCommand("python -m pytest"))
    }

    func test_go_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("go test ./..."))
    }

    func test_cargo_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("cargo test"))
    }

    func test_ls_isNotTest() {
        XCTAssertFalse(TestCommandDetector.isTestCommand("ls -la"))
    }

    func test_echo_test_isNotTest() {
        // "echo test" should NOT match — word-boundary checks matter
        XCTAssertFalse(TestCommandDetector.isTestCommand("echo test"))
    }

    // MARK: - parseXcodebuildOutput

    func test_parseXcodebuild_succeeded() {
        let output = """
        Test Suite 'All tests' started at 2026-04-01 12:00:00
        Test Case 'ChangeReviewHookTests.test_nonWriteTool_returnsPassthrough' passed (0.001 sec)
        Test Case 'ChangeReviewHookTests.test_writeTool_noSnapshot_returnsPassthrough' passed (0.002 sec)

        ** TEST SUCCEEDED **

        Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds
        """
        let result = TestCommandDetector.parseTestOutput(output, command: "xcodebuild test")
        XCTAssertEqual(result.passCount, 2)
        XCTAssertEqual(result.failCount, 0)
        XCTAssertTrue(result.exitedZero)
        XCTAssertNil(result.failureSummary)
    }

    func test_parseXcodebuild_failed() {
        let output = """
        Test Case 'FooTests.testBar' failed: (0.003 sec)
        /path/to/FooTests.swift:42: error: FooTests.testBar : XCTAssertEqual failed: ("1") is not equal to ("2")

        ** TEST FAILED **

        Executed 3 tests, with 1 failure (0 unexpected) in 0.050 (0.060) seconds
        """
        let result = TestCommandDetector.parseTestOutput(output, command: "xcodebuild test")
        XCTAssertEqual(result.passCount, 2)
        XCTAssertEqual(result.failCount, 1)
        XCTAssertFalse(result.exitedZero)
        XCTAssertNotNil(result.failureSummary)
    }

    // MARK: - parsePytestOutput

    func test_parsePytest_passed() {
        let output = "5 passed in 0.12s"
        let result = TestCommandDetector.parseTestOutput(output, command: "pytest tests/")
        XCTAssertEqual(result.passCount, 5)
        XCTAssertEqual(result.failCount, 0)
        XCTAssertTrue(result.exitedZero)
    }

    func test_parsePytest_failed() {
        let output = "3 passed, 2 failed in 1.5s"
        let result = TestCommandDetector.parseTestOutput(output, command: "pytest tests/")
        XCTAssertEqual(result.passCount, 3)
        XCTAssertEqual(result.failCount, 2)
        XCTAssertFalse(result.exitedZero)
    }

    // MARK: - parseGoTestOutput

    func test_parseGo_ok() {
        let output = "ok  github.com/example/project  0.003s"
        let result = TestCommandDetector.parseTestOutput(output, command: "go test ./...")
        XCTAssertTrue(result.exitedZero)
    }

    func test_parseGo_fail() {
        let output = "FAIL github.com/example/project  0.003s"
        let result = TestCommandDetector.parseTestOutput(output, command: "go test ./...")
        XCTAssertFalse(result.exitedZero)
    }

    // MARK: - formatSummaryLabel

    func test_summaryLabel_passed() {
        let summary = ParsedTestOutput(passCount: 5, failCount: 0, exitedZero: true, failureSummary: nil)
        let label = TestCommandDetector.formatSummaryLabel(summary, command: "swift test")
        XCTAssertTrue(label.contains("5"))
        XCTAssertTrue(label.lowercased().contains("passed") || label.lowercased().contains("通过"))
    }

    func test_summaryLabel_failed() {
        let summary = ParsedTestOutput(passCount: 3, failCount: 2, exitedZero: false, failureSummary: "XCTAssertEqual failed")
        let label = TestCommandDetector.formatSummaryLabel(summary, command: "xcodebuild test")
        XCTAssertTrue(label.lowercased().contains("fail") || label.lowercased().contains("失败"))
    }
}
```

### Step 2: 运行测试，确认 FAIL（类型不存在）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc4-derived \
  -only-testing:agentGuiTests/TestCommandDetectorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：编译失败 `error: cannot find type 'TestCommandDetector'`

### Step 3: 最小实现 `TestCommandDetector`

新建 `agentGui/Services/ToolGovernance/TestCommandDetector.swift`：

```swift
import Foundation

// MARK: - ParsedTestOutput

/// Parsed result of running `TestCommandDetector.parseTestOutput(_:command:)`.
struct ParsedTestOutput: Sendable, Equatable {
    let passCount: Int?
    let failCount: Int?
    let exitedZero: Bool
    /// Truncated first failure string extracted from output. nil when all passed.
    let failureSummary: String?
}

// MARK: - TestCommandDetector

/// Stateless utility for detecting test-run commands and parsing their output.
enum TestCommandDetector {

    // MARK: - Test Command Detection

    /// Returns true if `command` looks like a test-run invocation.
    ///
    /// Detection rules:
    /// - `xcodebuild` with the word `test` as a sub-command (not just in a flag)
    /// - `swift test`
    /// - `npm test` / `yarn test` / `pnpm test`
    /// - `npx jest` / bare `jest` binary
    /// - `pytest` / `python -m pytest`
    /// - `go test`
    /// - `cargo test`
    /// - `mvn test` / `gradle test`
    static func isTestCommand(_ command: String) -> Bool {
        let lower = command.trimmingCharacters(in: .whitespaces).lowercased()
        return testPatterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                in: lower,
                range: NSRange(lower.startIndex..., in: lower)
            ) != nil
        }
    }

    // Word-boundary aware regex patterns for each known test runner.
    // Patterns are anchored to avoid matching "echo test" or "notestfoo".
    private static let testPatterns: [String] = [
        #"^xcodebuild\b.*\btest\b"#,                  // xcodebuild test ...
        #"^swift\s+test\b"#,                           // swift test
        #"^(npm|yarn|pnpm)\s+test\b"#,                // npm/yarn/pnpm test
        #"(^|\s)(npx\s+)?jest\b"#,                    // jest / npx jest
        #"(^|\s)pytest\b"#,                           // pytest
        #"python\s+(-m\s+)?pytest\b"#,                // python -m pytest
        #"^go\s+test\b"#,                             // go test
        #"^cargo\s+test\b"#,                          // cargo test
        #"^(mvn|gradle)\s+test\b"#,                   // mvn/gradle test
    ]

    // MARK: - Output Parsing

    /// Parse a test run's stdout/stderr output into a `ParsedTestOutput`.
    /// Works heuristically across multiple test runners.
    static func parseTestOutput(_ text: String, command: String) -> ParsedTestOutput {
        // Try runner-specific parsers in priority order
        if let result = parseXcodebuildOutput(text) { return result }
        if let result = parsePytestOutput(text) { return result }
        if let result = parseGoTestOutput(text) { return result }
        if let result = parseJestOutput(text) { return result }
        if let result = parseSwiftTestOutput(text) { return result }
        // Fallback: infer from exit keywords
        return fallbackParse(text)
    }

    // MARK: Private parsers

    /// xcodebuild: "Executed N tests, with M failures"  +  "** TEST SUCCEEDED/FAILED **"
    private static func parseXcodebuildOutput(_ text: String) -> ParsedTestOutput? {
        // Pattern: "Executed 5 tests, with 2 failures"
        let executedPattern = #"Executed (\d+) tests?, with (\d+) failures?"#
        guard let match = firstMatch(pattern: executedPattern, in: text) else { return nil }
        let total = intCapture(match, group: 1, in: text) ?? 0
        let fail  = intCapture(match, group: 2, in: text) ?? 0
        let pass  = total - fail
        let exitedZero = text.contains("** TEST SUCCEEDED **")
        let failureSummary = fail > 0 ? extractFirstFailureLine(text) : nil
        return ParsedTestOutput(passCount: pass, failCount: fail, exitedZero: exitedZero, failureSummary: failureSummary)
    }

    /// pytest: "5 passed" / "3 passed, 2 failed"
    private static func parsePytestOutput(_ text: String) -> ParsedTestOutput? {
        guard text.contains(" passed") || text.contains(" failed") else { return nil }
        let passPattern = #"(\d+) passed"#
        let failPattern = #"(\d+) failed"#
        guard let passMatch = firstMatch(pattern: passPattern, in: text) else { return nil }
        let pass = intCapture(passMatch, group: 1, in: text) ?? 0
        let failMatch = firstMatch(pattern: failPattern, in: text)
        let fail = failMatch.flatMap { intCapture($0, group: 1, in: text) } ?? 0
        let exitedZero = fail == 0
        let failureSummary = fail > 0 ? extractFirstFailureLine(text) : nil
        return ParsedTestOutput(passCount: pass, failCount: fail, exitedZero: exitedZero, failureSummary: failureSummary)
    }

    /// go test: "ok  pkg  0.003s" / "FAIL pkg  0.003s"
    private static func parseGoTestOutput(_ text: String) -> ParsedTestOutput? {
        let hasOk   = text.range(of: #"^ok\s+"#, options: [.regularExpression, .anchored]) != nil
                   || text.contains("\nok  ")
        let hasFail = text.range(of: #"^FAIL\s+"#, options: [.regularExpression, .anchored]) != nil
                   || text.contains("\nFAIL ")
        guard hasOk || hasFail else { return nil }
        let exitedZero = hasOk && !hasFail
        return ParsedTestOutput(passCount: nil, failCount: hasFail ? 1 : 0, exitedZero: exitedZero, failureSummary: nil)
    }

    /// jest: "Tests:  5 passed, 2 failed"
    private static func parseJestOutput(_ text: String) -> ParsedTestOutput? {
        guard text.contains("Tests:") else { return nil }
        let passPattern = #"(\d+) passed"#
        let failPattern = #"(\d+) failed"#
        guard let passMatch = firstMatch(pattern: passPattern, in: text) else { return nil }
        let pass = intCapture(passMatch, group: 1, in: text) ?? 0
        let failMatch = firstMatch(pattern: failPattern, in: text)
        let fail = failMatch.flatMap { intCapture($0, group: 1, in: text) } ?? 0
        return ParsedTestOutput(passCount: pass, failCount: fail, exitedZero: fail == 0, failureSummary: nil)
    }

    /// swift test: "Test run started." ... "Test run with N test(s) passed"
    private static func parseSwiftTestOutput(_ text: String) -> ParsedTestOutput? {
        guard text.contains("Test run") else { return nil }
        let passPattern = #"(\d+) test.* passed"#
        guard let match = firstMatch(pattern: passPattern, in: text) else { return nil }
        let pass = intCapture(match, group: 1, in: text) ?? 0
        let exitedZero = !text.lowercased().contains("failed") && !text.lowercased().contains("error")
        return ParsedTestOutput(passCount: pass, failCount: exitedZero ? 0 : nil, exitedZero: exitedZero, failureSummary: nil)
    }

    /// Last-resort: look for positive/negative Tier-1 keywords.
    private static func fallbackParse(_ text: String) -> ParsedTestOutput {
        let lower = text.lowercased()
        let exitedZero = lower.contains("all tests passed")
                      || lower.contains("tests passed")
                      || (lower.contains("success") && !lower.contains("failure"))
        return ParsedTestOutput(passCount: nil, failCount: nil, exitedZero: exitedZero, failureSummary: nil)
    }

    // MARK: - Summary Label

    /// Build a short human-readable label (~40 chars) for the timeline attachment.
    static func formatSummaryLabel(_ output: ParsedTestOutput, command: String) -> String {
        let runner = inferRunner(from: command)
        if output.exitedZero {
            if let pass = output.passCount {
                return "\(runner): \(pass) 个测试通过"
            }
            return "\(runner): 测试通过"
        } else {
            if let fail = output.failCount, let pass = output.passCount {
                return "\(runner): \(pass) 通过 / \(fail) 失败"
            }
            if let fail = output.failCount {
                return "\(runner): \(fail) 个测试失败"
            }
            return "\(runner): 测试失败"
        }
    }

    private static func inferRunner(from command: String) -> String {
        let lower = command.lowercased()
        if lower.contains("xcodebuild") { return "xcodebuild" }
        if lower.contains("swift test") { return "swift test" }
        if lower.contains("pytest")     { return "pytest" }
        if lower.contains("jest")       { return "jest" }
        if lower.contains("go test")    { return "go test" }
        if lower.contains("cargo")      { return "cargo test" }
        return "tests"
    }

    // MARK: - Regex helpers

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func intCapture(_ match: NSTextCheckingResult, group: Int, in text: String) -> Int? {
        let range = match.range(at: group)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text) else { return nil }
        return Int(text[swiftRange])
    }

    private static func extractFirstFailureLine(_ text: String) -> String? {
        // Look for lines containing "failed" or "error:" that are not summary lines
        let lines = text.components(separatedBy: "\n")
        let failLine = lines.first { line in
            let lower = line.lowercased()
            return (lower.contains("failed:") || lower.contains("error:")) &&
                   !lower.contains("** test") &&
                   !lower.contains("executed") &&
                   !lower.contains("failures")
        }
        guard let line = failLine else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }
}
```

### Step 4: 运行测试，确认全部通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc4-derived \
  -only-testing:agentGuiTests/TestCommandDetectorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：`** TEST SUCCEEDED **`

### Step 5: Commit

```
git add agentGui/Services/ToolGovernance/TestCommandDetector.swift \
        agentGuiTests/TestCommandDetectorTests.swift
git commit -m "feat(F-C4): add TestCommandDetector with TDD coverage"
```

---

## Task 3 — TDD：`VerificationEvidenceStore` 测试

**Files:**
- Create: `agentGuiTests/VerificationEvidenceStoreTests.swift`

### Step 1: 写测试

```swift
import XCTest
@testable import agentGui

final class VerificationEvidenceStoreTests: XCTestCase {

    func test_noEvidence_initially() async {
        let store = VerificationEvidenceStore()
        let has = await store.hasEvidence(for: "session-1")
        XCTAssertFalse(has)
    }

    func test_recordedEvidence_isDetected() async {
        let store = VerificationEvidenceStore()
        let summary = VerificationEvidenceSummary(
            command: "swift test",
            passCount: 5,
            failCount: 0,
            failureSummary: nil,
            exitedZero: true,
            capturedAt: Date()
        )
        await store.record(summary, sessionID: "session-1")
        let has = await store.hasEvidence(for: "session-1")
        XCTAssertTrue(has)
    }

    func test_evidence_isolation_betweenSessions() async {
        let store = VerificationEvidenceStore()
        let summary = makeSummary()
        await store.record(summary, sessionID: "session-A")
        let hasA = await store.hasEvidence(for: "session-A")
        let hasB = await store.hasEvidence(for: "session-B")
        XCTAssertTrue(hasA)
        XCTAssertFalse(hasB)
    }

    func test_clearEvidence_removesAllForSession() async {
        let store = VerificationEvidenceStore()
        await store.record(makeSummary(), sessionID: "session-1")
        await store.clearEvidence(for: "session-1")
        let has = await store.hasEvidence(for: "session-1")
        XCTAssertFalse(has)
    }

    func test_multipleRecords_allRetrieved() async {
        let store = VerificationEvidenceStore()
        await store.record(makeSummary(pass: 3), sessionID: "session-1")
        await store.record(makeSummary(pass: 7), sessionID: "session-1")
        let records = await store.evidence(for: "session-1")
        XCTAssertEqual(records.count, 2)
    }

    // MARK: - Helpers

    private func makeSummary(pass: Int = 1) -> VerificationEvidenceSummary {
        VerificationEvidenceSummary(
            command: "swift test",
            passCount: pass,
            failCount: 0,
            failureSummary: nil,
            exitedZero: true,
            capturedAt: Date()
        )
    }
}
```

### Step 2: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc4-derived \
  -only-testing:agentGuiTests/VerificationEvidenceStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 3: Commit

```
git add agentGuiTests/VerificationEvidenceStoreTests.swift
git commit -m "test(F-C4): add VerificationEvidenceStore unit tests"
```

---

## Task 4 — 实现 `VerificationEvidenceHook`

**Files:**
- Create: `agentGui/Services/ToolGovernance/Hooks/VerificationEvidenceHook.swift`

### Step 1: 写 hook 实现

`VerificationEvidenceHook` 有两条逻辑分支：

**分支 A — bash postExecute（检测测试运行）**
- `record.toolName == "bash"`
- `record.result.isError == false`（成功执行）
- `TestCommandDetector.isTestCommand(command)` 返回 `true`
- → 解析 output，记录到 `evidenceStore`
- → 返回 `.appendAttachment(label)`

**分支 B — update_todo postExecute（nudge 检测）**
- `record.toolName == "update_todo"`
- `result.isError == false`
- 解析 `input["items"]` → 所有 item.status == `.done`（数量 >= 3）
- 没有任何 item 的 title 包含 `/test|verif|check|assert/i`
- `evidenceStore.hasEvidence(for: sessionID)` 返回 `false`
- → 返回 `.appendAttachment(nudgeMessage)`

```swift
import Foundation
import SwiftAnthropic

/// Post-execution hook that:
/// 1. Detects test-run bash commands and appends a pass/fail summary to the ToolCall timeline.
/// 2. Detects "all todos done, no tests ran" and injects a verification nudge.
///
/// Registered in `AgentLoopToolExecutionCoordinatorBuilder.buildHookPipeline()`.
struct VerificationEvidenceHook: ToolExecutionHook {

    let hookID = "verification-evidence"

    /// Session this hook instance is scoped to (captured from builder).
    private let sessionID: String

    /// Shared in-memory store; typically a singleton held by the builder/service.
    private let evidenceStore: VerificationEvidenceStore

    init(sessionID: String, evidenceStore: VerificationEvidenceStore) {
        self.sessionID = sessionID
        self.evidenceStore = evidenceStore
    }

    // MARK: - ToolExecutionHook

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        .allow  // This hook does not block any tool
    }

    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        switch record.toolName {
        case "bash":
            return await handleBashPostExecute(record: record)
        case "update_todo":
            return await handleTodoPostExecute(record: record)
        default:
            return .passthrough
        }
    }

    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        .propagate  // This hook does not recover from failures
    }

    // MARK: - Branch A: bash test detection

    private func handleBashPostExecute(record: ToolRunRecord) async -> PostExecuteAction {
        guard !record.result.isError else { return .passthrough }

        // Extract the command string from bash input
        guard let commandValue = record.input["command"],
              let command = commandValue.stringValue,
              TestCommandDetector.isTestCommand(command) else {
            return .passthrough
        }

        // Parse the output text
        let output = record.result.text
        let parsed = TestCommandDetector.parseTestOutput(output, command: command)

        // Record to store
        let summary = VerificationEvidenceSummary(
            command: String(command.prefix(200)),
            passCount: parsed.passCount,
            failCount: parsed.failCount,
            failureSummary: parsed.failureSummary,
            exitedZero: parsed.exitedZero,
            capturedAt: Date()
        )
        await evidenceStore.record(summary, sessionID: sessionID)

        // Build attachment label
        let label = TestCommandDetector.formatSummaryLabel(parsed, command: command)
        return .appendAttachment("✔ 验证证据已记录 — \(label)")
    }

    // MARK: - Branch B: todo nudge

    private func handleTodoPostExecute(record: ToolRunRecord) async -> PostExecuteAction {
        guard !record.result.isError else { return .passthrough }

        // Parse todos from input
        let todos = parseTodos(from: record.input)
        guard todos.count >= 3 else { return .passthrough }

        // Check: all done
        let allDone = todos.allSatisfy { $0.status == .done }
        guard allDone else { return .passthrough }

        // Check: no todo title suggests a verification step
        let hasVerificationTodo = todos.contains { item in
            let lower = item.title.lowercased()
            return lower.range(of: #"\b(test|verif|check|assert|validate|run)\b"#,
                               options: .regularExpression) != nil
        }
        guard !hasVerificationTodo else { return .passthrough }

        // Check: no test evidence recorded for this session
        let hasEvidence = await evidenceStore.hasEvidence(for: sessionID)
        guard !hasEvidence else { return .passthrough }

        let nudge = """
        ⚠️ 注意：你已完成 \(todos.count) 个任务，但本次会话没有任何测试运行记录。\
        建议在结束前运行一次测试（如 `xcodebuild test` 或 `swift test`）确认改动无误。
        """
        return .appendAttachment(nudge)
    }

    // MARK: - Helpers

    private func parseTodos(from input: MessageResponse.Content.Input) -> [TodoItem] {
        guard let itemsValue = input["items"] else { return [] }
        // Decode through JSON round-trip (mirrors ClaudeService+TodoTool approach)
        let anyValue = dynamicContentToAny(itemsValue)
        guard
            let array = anyValue as? [[String: Any]],
            let data = try? JSONSerialization.data(withJSONObject: array),
            let items = try? JSONDecoder().decode([TodoItem].self, from: data)
        else { return [] }
        return items
    }
}
```

> **注意：** `dynamicContentToAny` 是 `ClaudeService` 的私有方法。Task 4 的 Step 2 需要把它提升为 internal 或抽取到一个 internal 顶层工具函数，供 hook 调用（见下面 Step 2）。

### Step 2: 提升 `dynamicContentToAny` 的可见性

找到该函数：

```
agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift  (或同目录其他文件)
```

将 `private func dynamicContentToAny(...)` 改为 `func dynamicContentToAny(...)` 或提取为顶层 `internal func`，并确保 hook 文件可以调用它。

> 如果提升可见性会引起其他问题，另一种方案是在 `VerificationEvidenceHook` 中内联一个简化版 JSON 解码路径，不复用 `dynamicContentToAny`。

### Step 3: 构建验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 4: Commit

```
git add agentGui/Services/ToolGovernance/Hooks/VerificationEvidenceHook.swift
git commit -m "feat(F-C4): implement VerificationEvidenceHook (bash detection + todo nudge)"
```

---

## Task 5 — TDD：`VerificationEvidenceHookTests`

**Files:**
- Create: `agentGuiTests/VerificationEvidenceHookTests.swift`

### Step 1: 写测试

```swift
import XCTest
@testable import agentGui

@MainActor
final class VerificationEvidenceHookTests: XCTestCase {

    private let sessionID = "test-session-hook"

    // MARK: - Helpers

    private func makeHook(store: VerificationEvidenceStore = VerificationEvidenceStore()) -> VerificationEvidenceHook {
        VerificationEvidenceHook(sessionID: sessionID, evidenceStore: store)
    }

    private func makeBashRecord(
        command: String,
        output: String,
        isError: Bool = false
    ) -> ToolRunRecord {
        ToolRunRecord(
            toolCallId: "tc-bash",
            toolName: "bash",
            input: ["command": .string(command)],
            result: ToolExecutionResult(output, status: isError ? .failure : .success),
            sessionID: sessionID,
            executionContext: .mainAgent
        )
    }

    private func makeTodoRecord(todos: [[String: String]]) -> ToolRunRecord {
        let inputAny = todos.map { $0 as [String: Any] }
        let data = try! JSONSerialization.data(withJSONObject: inputAny)
        let encoded = String(data: data, encoding: .utf8)!
        // Build input as if the model sent a JSON array
        return ToolRunRecord(
            toolCallId: "tc-todo",
            toolName: "update_todo",
            input: ["items": .string(encoded)],  // simplified — will be decoded
            result: ToolExecutionResult("Todo list updated with \(todos.count) items.", status: .success),
            sessionID: sessionID,
            executionContext: .mainAgent
        )
    }

    // MARK: - preExecute always allows

    func test_preExecute_alwaysAllows() async {
        let hook = makeHook()
        let preview = ToolCallPreview(
            toolCallId: "id", toolName: "bash",
            input: [:], sessionID: sessionID, executionContext: .mainAgent
        )
        let decision = await hook.preExecute(toolCall: preview)
        if case .allow = decision { return }
        XCTFail("Expected .allow, got \(decision)")
    }

    // MARK: - bash: non-test command → passthrough

    func test_bash_nonTestCommand_passthrough() async {
        let hook = makeHook()
        let record = makeBashRecord(command: "ls -la", output: "total 0")
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough for non-test command, got \(action)")
    }

    // MARK: - bash: test command → appendAttachment + store recorded

    func test_bash_xcodebuildTest_appendsAttachment() async {
        let store = VerificationEvidenceStore()
        let hook = makeHook(store: store)
        let output = """
        ** TEST SUCCEEDED **
        Executed 4 tests, with 0 failures (0 unexpected) in 0.001 (0.003) seconds
        """
        let record = makeBashRecord(command: "xcodebuild test -scheme agentGui", output: output)
        let action = await hook.postExecute(record: record)
        switch action {
        case .appendAttachment(let text):
            XCTAssertTrue(text.contains("4"), "Expected pass count in label: \(text)")
        default:
            XCTFail("Expected .appendAttachment, got \(action)")
        }
        // Evidence must be recorded
        let hasEvidence = await store.hasEvidence(for: sessionID)
        XCTAssertTrue(hasEvidence)
    }

    func test_bash_testFailed_attachmentMentionsFail() async {
        let hook = makeHook()
        let output = """
        ** TEST FAILED **
        Executed 3 tests, with 2 failures (0 unexpected) in 0.050 (0.060) seconds
        """
        let record = makeBashRecord(command: "xcodebuild test -scheme agentGui", output: output)
        let action = await hook.postExecute(record: record)
        switch action {
        case .appendAttachment(let text):
            XCTAssertTrue(
                text.lowercased().contains("fail") || text.lowercased().contains("失败"),
                "Expected failure indication in: \(text)"
            )
        default:
            XCTFail("Expected .appendAttachment, got \(action)")
        }
    }

    // MARK: - bash: isError → passthrough (even if test command)

    func test_bash_errorResult_passthrough() async {
        let hook = makeHook()
        let record = makeBashRecord(
            command: "xcodebuild test -scheme agentGui",
            output: "Error: build failed",
            isError: true
        )
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough for error result, got \(action)")
    }

    // MARK: - todo nudge: < 3 items → passthrough

    func test_todo_lessThan3Items_passthrough() async {
        let hook = makeHook()
        let todos = [
            ["id": "1", "title": "Fix bug", "status": "done"],
            ["id": "2", "title": "Review PR", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough for < 3 todos, got \(action)")
    }

    // MARK: - todo nudge: not all done → passthrough

    func test_todo_notAllDone_passthrough() async {
        let hook = makeHook()
        let todos = [
            ["id": "1", "title": "Fix A", "status": "done"],
            ["id": "2", "title": "Fix B", "status": "pending"],
            ["id": "3", "title": "Fix C", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough when not all done, got \(action)")
    }

    // MARK: - todo nudge: all done, no evidence → appendAttachment

    func test_todo_allDone3Plus_noEvidence_appendsNudge() async {
        let store = VerificationEvidenceStore()
        let hook = VerificationEvidenceHook(sessionID: sessionID, evidenceStore: store)
        let todos = [
            ["id": "1", "title": "Fix A", "status": "done"],
            ["id": "2", "title": "Fix B", "status": "done"],
            ["id": "3", "title": "Fix C", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        switch action {
        case .appendAttachment(let text):
            XCTAssertTrue(text.contains("测试") || text.lowercased().contains("test"),
                          "Nudge should mention testing: \(text)")
        default:
            XCTFail("Expected .appendAttachment nudge, got \(action)")
        }
    }

    // MARK: - todo nudge: all done, HAS evidence → passthrough (no nudge)

    func test_todo_allDone_withEvidence_passthrough() async {
        let store = VerificationEvidenceStore()
        // Pre-populate evidence
        let summary = VerificationEvidenceSummary(
            command: "swift test", passCount: 5, failCount: 0,
            failureSummary: nil, exitedZero: true, capturedAt: Date()
        )
        await store.record(summary, sessionID: sessionID)

        let hook = VerificationEvidenceHook(sessionID: sessionID, evidenceStore: store)
        let todos = [
            ["id": "1", "title": "Fix A", "status": "done"],
            ["id": "2", "title": "Fix B", "status": "done"],
            ["id": "3", "title": "Fix C", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough when evidence exists, got \(action)")
    }

    // MARK: - todo nudge: all done but has 'test' todo → passthrough

    func test_todo_allDone_verificationTodoPresent_passthrough() async {
        let hook = makeHook()
        let todos = [
            ["id": "1", "title": "Fix A", "status": "done"],
            ["id": "2", "title": "Fix B", "status": "done"],
            ["id": "3", "title": "Run tests to verify", "status": "done"]
        ]
        let record = makeTodoRecord(todos: todos)
        let action = await hook.postExecute(record: record)
        if case .passthrough = action { return }
        XCTFail("Expected .passthrough when verification todo exists, got \(action)")
    }

    // MARK: - postFailure always propagates

    func test_postFailure_propagates() async {
        let hook = makeHook()
        let preview = ToolCallPreview(
            toolCallId: "id", toolName: "bash",
            input: [:], sessionID: sessionID, executionContext: .mainAgent
        )
        let action = await hook.postFailure(
            toolCall: preview,
            error: ToolExecutionHookError(message: "cmd not found")
        )
        if case .propagate = action { return }
        XCTFail("Expected .propagate, got \(action)")
    }
}
```

> **测试文件注意：** `makeTodoRecord` 使用简化的 JSON 字符串作为 `input["items"]` 的值。若 `VerificationEvidenceHook.parseTodos` 内部通过 `dynamicContentToAny` 路径处理 `.array(...)` 类型，则测试辅助函数需调整为使用 `MessageResponse.Content.Input` 的 `.array` case 而非字符串。根据实际实现调整，目标是让测试能运行。

### Step 2: 运行测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc4-derived \
  -only-testing:agentGuiTests/VerificationEvidenceHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：`** TEST SUCCEEDED **`

### Step 3: Commit

```
git add agentGuiTests/VerificationEvidenceHookTests.swift
git commit -m "test(F-C4): add VerificationEvidenceHook unit tests"
```

---

## Task 6 — 修复 `sessionID` 传递

**Files:**
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

### 问题

`AgentLoopToolExecutionCoordinator.execute()` 中，构造 `ToolCallPreview` 和 `ToolRunRecord` 时 `sessionID` 硬编码为 `""`：

```swift
let preview = ToolCallPreview(
    toolCallId: record.toolCallId,
    toolName: pendingTool.name,
    input: effectiveInput,
    sessionID: "",          // ← 错误
    executionContext: .mainAgent
)
```

### Step 1: 在 `Dependencies` 中添加 `sessionID`

```swift
// 修改 Dependencies，添加 sessionID 字段
struct Dependencies {
    let sessionID: String                          // ← 新增
    let runSubagent: ...
    ...
}
```

### Step 2: 更新 coordinator 内所有 `sessionID: ""` 为 `sessionID: dependencies.sessionID`

在 `execute()` 方法中，所有构造 `ToolCallPreview` 和 `ToolRunRecord` 的地方替换：

```swift
// before
sessionID: ""

// after
sessionID: dependencies.sessionID
```

共有两个 `ToolCallPreview` 构造和一个 `ToolRunRecord` 构造（共 3 处）。

### Step 3: 更新 builder 传 `sessionID` 给 `Dependencies`

在 `AgentLoopToolExecutionCoordinatorBuilder` 的 `build()` 方法中：

```swift
return AgentLoopToolExecutionCoordinator(
    dependencies: AgentLoopToolExecutionCoordinator.Dependencies(
        sessionID: sessionId,    // ← 新增
        runSubagent: ...,
        ...
    )
)
```

### Step 4: 构建验证 + 测试

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 5: Commit

```
git add agentGui/Services/AgentLoopToolExecutionCoordinator.swift \
        agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
git commit -m "fix(F-C4): propagate sessionID through AgentLoopToolExecutionCoordinator.Dependencies"
```

---

## Task 7 — 注册 Hook 到 Pipeline

**Files:**
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

### Step 1: 在 builder 中添加 `evidenceStore` 属性

`VerificationEvidenceStore` 应该是 session 级别的，由 builder 的调用方或 `ClaudeService` 管理生命周期。最简方案：

**Option A（推荐）**：在 `AgentLoopToolExecutionCoordinatorBuilder` 的 `init` 中接受一个 `VerificationEvidenceStore` 参数，并在创建 builder 的地方（`ClaudeService` 或 `AgentLoopHookDependencyFactory`）传入。

**Option B（简单但不精确）**：在 builder 内每次调用 `buildHookPipeline()` 时创建新实例（只适用于单次执行，不能跨 round 累积证据）。

**建议选 Option A**，在 `ClaudeService` 中持有一个 `[String: VerificationEvidenceStore]` 字典（key = sessionID），在启动 agent 时懒初始化。

### Step 2: 在 `buildHookPipeline()` 中注册 hook

```swift
private func buildHookPipeline() -> ToolExecutionHookPipeline {
    var hooks: [any ToolExecutionHook] = []

    if let projectionStore = claudeService.changeReviewProjectionStore {
        hooks.append(ChangeReviewHook(projectionStore: projectionStore))
    }

    // F-C4: VerificationEvidenceHook
    let evidenceStore = claudeService.verificationEvidenceStore(for: sessionId)
    hooks.append(VerificationEvidenceHook(sessionID: sessionId, evidenceStore: evidenceStore))

    // F-C5 PayloadBudgetHook 将在此追加

    return ToolExecutionHookPipeline(hooks: hooks)
}
```

### Step 3: 在 `ClaudeService` 中添加 store 管理

在 `ClaudeService.swift`（或其分类文件）中：

```swift
// In ClaudeService
private var verificationEvidenceStores: [String: VerificationEvidenceStore] = [:]

func verificationEvidenceStore(for sessionID: String) -> VerificationEvidenceStore {
    if let existing = verificationEvidenceStores[sessionID] {
        return existing
    }
    let store = VerificationEvidenceStore()
    verificationEvidenceStores[sessionID] = store
    return store
}
```

### Step 4: 构建验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 5: 全量 hook 测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc4-final-derived \
  -only-testing:agentGuiTests/TestCommandDetectorTests \
  -only-testing:agentGuiTests/VerificationEvidenceStoreTests \
  -only-testing:agentGuiTests/VerificationEvidenceHookTests \
  -only-testing:agentGuiTests/ChangeReviewHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：`** TEST SUCCEEDED **`

### Step 6: Commit

```
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift \
        agentGui/Services/ClaudeService/ClaudeService.swift   # (or the category file)
git commit -m "feat(F-C4): register VerificationEvidenceHook in hook pipeline"
```

---

## Task 8 — 回归与最终验证

### Step 1: 运行相关测试集

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fc4-regression \
  -only-testing:agentGuiTests/TestCommandDetectorTests \
  -only-testing:agentGuiTests/VerificationEvidenceStoreTests \
  -only-testing:agentGuiTests/VerificationEvidenceHookTests \
  -only-testing:agentGuiTests/ChangeReviewHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|SUCCEEDED|FAILED|error:"
```

### Step 2: 手动 smoke test（可选，需 API Key）

1. 打开 agentGui，新建 session。
2. 让 agent 执行 `xcodebuild test -scheme agentGui -destination 'platform=macOS'`。
3. 验证：执行时间线中出现「✔ 验证证据已记录 — xcodebuild: N 个测试通过」标签。
4. 新建另一个 session，让 agent 完成 3 个任务并标记 done，但不运行测试。
5. 验证：todo 更新时出现 nudge 消息（⚠️ 注意：...建议运行测试）。

### Step 3: Final commit

```
git add .
git commit -m "feat(F-C4): VerificationEvidenceHook — complete implementation with tests

- TestCommandDetector: regex-based test command detection for xcodebuild,
  swift test, pytest, jest, go test, cargo test, npm/yarn test
- ParsedTestOutput: pass/fail count extraction for xcodebuild, pytest, jest
- VerificationEvidenceStore: actor-based per-session evidence registry
- VerificationEvidenceHook: bash post-hook appends test summary;
  update_todo post-hook injects nudge when no test evidence found
- Fixed sessionID propagation in AgentLoopToolExecutionCoordinator.Dependencies
- Registered hook in AgentLoopToolExecutionCoordinatorBuilder"
```

---

## 验收标准对照表

| 验收条件 | 覆盖 Task | 测试用例 |
|---|---|---|
| `xcodebuild test` 后，时间线出现 pass/fail 摘要 | T2, T4, T5 | `test_bash_xcodebuildTest_appendsAttachment` |
| `swift test`、`pytest`、`go test`、`npm test` 均可识别 | T2 | `TestCommandDetectorTests` 各测试 |
| `ls`、`echo test` 不误判为测试命令 | T2 | `test_ls_isNotTest`、`test_echo_test_isNotTest` |
| 测试失败时 label 包含失败信息 | T2, T5 | `test_bash_testFailed_attachmentMentionsFail` |
| bash 工具报 error 时不触发钩子 | T5 | `test_bash_errorResult_passthrough` |
| 证据记录在正确的 session 下，不跨污染 | T3 | `test_evidence_isolation_betweenSessions` |
| < 3 个 todo 不触发 nudge | T5 | `test_todo_lessThan3Items_passthrough` |
| 未全部完成时不触发 nudge | T5 | `test_todo_notAllDone_passthrough` |
| 全部完成 + 无证据 → nudge | T5 | `test_todo_allDone3Plus_noEvidence_appendsNudge` |
| 全部完成 + 有证据 → 不 nudge | T5 | `test_todo_allDone_withEvidence_passthrough` |
| 有 "test/verif/check" 标题的 todo → 不 nudge | T5 | `test_todo_allDone_verificationTodoPresent_passthrough` |
| `ChangeReviewHook` 不受影响（回归） | T7 | `ChangeReviewHookTests` |

---

## 潜在风险与注意事项

1. **`dynamicContentToAny` 可见性**：该函数目前可能是私有的。`VerificationEvidenceHook.parseTodos` 需要访问它，或者在 hook 中内联一个简化实现（直接 JSON decode，不走 `MessageResponse.Content.Input` 路径）。根据实际情况选择最小改动方案。

2. **`ToolRunRecord.sessionID` 当前为 `""`**：Task 6 修复了这个问题，但 `VerificationEvidenceHook` **不依赖** `record.sessionID`，而是依赖构造时传入的 `sessionID` 参数（来自 builder）。即使 Task 6 未完成，F-C4 的 branch A 和 B 仍能正确工作。Task 6 是独立的质量修复，可以分开 PR。

3. **store 生命周期**：`VerificationEvidenceStore` 是内存态，不跨进程重启保留。这是有意为之：验证证据只在当前运行的 agent loop 中有意义。如未来需要跨会话恢复，可以持久化到 `SessionTaskStateStore`。

4. **性能**：`isTestCommand` 中每次调用都编译正则表达式。在生产中应用 lazy `static let` 缓存已编译的 `NSRegularExpression` 对象。在 Task 2 实现时注意这一点，或作为后续优化。

5. **并发**：`VerificationEvidenceStore` 是 actor，hook 方法为 `async`，与 `ToolExecutionHookPipeline` 的调用方式（`await pipeline.runPostExecute(record:)`）完全兼容，无需额外并发保护。
