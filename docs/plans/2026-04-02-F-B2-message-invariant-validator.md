# F-B2 MessageInvariantValidator 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `MessageInvariantValidator`——在任何压缩操作前运行的不变量校验器，确保 `[MessageParameter.Message]` 数组在被截断时不破坏 `tool_use / tool_result` 配对关系，从而避免 Claude API 因孤立 `tool_result` 或 `tool_use` 返回 400 错误。

**Architecture:** 纯无副作用值类型（`struct`），不持有可变状态。包含两层 API：(1) `adjustedStartIndex(_:in:)` — 对应 Claude Code `adjustIndexToPreserveAPIInvariants()`，接受拟定截断起点、向前调整直到配对完整；(2) `validate(_:)` — 全量扫描，返回所有不变量违规。设计为 `CompactionCoordinator`（F-B3）的前置卫兵，同时可独立用于调试和单元测试。

**Tech Stack:** Swift 6, XCTest, SwiftAnthropic (`MessageParameter.Message`, `MessageParameter.Message.Content.ContentObject`)

**Claude Code 对应源码（参考，不复制）:**
- `src/services/compact/sessionMemoryCompact.ts` → `adjustIndexToPreserveAPIInvariants()`, `getToolResultIds()`, `hasToolUseWithIds()`

---

## 背景 & 数据结构速查

agentGui 代理循环中，每轮工具调用产生两条 API 消息：

```
assistant → role: .assistant, content: .list([
    .toolUse("id-A", "bash", input),
    .toolUse("id-B", "file_read", input),
])
user      → role: .user, content: .list([
    .toolResult("id-A", "output-A", isError: nil),
    .toolResult("id-B", "output-B", isError: nil),
])
```

**API 不变量：**
- `.toolResult(toolUseId, ...)` 中的 `toolUseId` 必须能在前面（更早的）某条 `.assistant` 消息的 `.toolUse(id, ...)` 中找到对应 `id`；
- 如果截断把 `.toolUse` 消息切走，但保留了对应的 `.toolResult`，Claude API 将返回 400。

**ContentObject 分支（SwiftAnthropic 2.2.1）：**
```swift
// 从 AgentLoopRoundExecutor.swift 中的使用方式推断：
.text(String)
.toolUse(String /*id*/, String /*name*/, MessageParameter.Message.Content.Input)
.toolResult(String /*toolUseId*/, String /*result*/, Bool? /*isError*/, ...)
```

---

## 新增文件目录

```
agentGui/Services/ContextGovernance/
  MessageInvariantValidator.swift        ← 本计划全部新增

agentGuiTests/
  MessageInvariantValidatorTests.swift   ← 本计划全部新增
```

---

## Task 1：核心类型定义

**Files:**
- Create: `agentGui/Services/ContextGovernance/MessageInvariantValidator.swift`（分多个 Task 逐步填充）
- Create: `agentGuiTests/MessageInvariantValidatorTests.swift`（分多个 Task 逐步填充）

### Step 1：新建源文件，定义 `InvariantViolation` 和 `ValidationResult`

在 `MessageInvariantValidator.swift` 中写入：

```swift
import SwiftAnthropic

// MARK: - InvariantViolation

/// 消息数组中发现的不变量违规。
enum InvariantViolation: Equatable, Sendable {
    /// 某条 user 消息中有 tool_result 块，但在该消息之前找不到对应的 tool_use。
    /// - Parameters:
    ///   - toolUseId: 孤立 tool_result 中的 toolUseId。
    ///   - messageIndex: 含有该 tool_result 的 user 消息在数组中的下标。
    case orphanToolResult(toolUseId: String, messageIndex: Int)

    /// 某条 assistant 消息中有 tool_use 块，但在整个数组中找不到对应的 tool_result。
    /// (警告级别：不一定导致 API 错误，但说明会话被异常截断。)
    /// - Parameters:
    ///   - toolCallId: 孤立 tool_use 的 id。
    ///   - messageIndex: 含有该 tool_use 的 assistant 消息在数组中的下标。
    case orphanToolUse(toolCallId: String, messageIndex: Int)
}

// MARK: - ValidationResult

/// `MessageInvariantValidator.validate(_:)` 的返回值。
struct ValidationResult: Equatable, Sendable {
    /// 数组中没有任何不变量违规。
    var isValid: Bool { violations.isEmpty }
    /// 所有发现的违规列表（空表示合法）。
    let violations: [InvariantViolation]

    static let valid = ValidationResult(violations: [])
}
```

### Step 2：定义 `MessageInvariantValidator` 空壳

紧接上方代码追加：

```swift
// MARK: - MessageInvariantValidator

/// 纯无副作用的消息不变量校验器。
///
/// 在压缩操作截断 `[MessageParameter.Message]` 前调用，确保
/// `tool_use / tool_result` 配对完整，避免 Claude API 返回 400。
///
/// 不持有可变状态，任意线程可并发调用。
struct MessageInvariantValidator: Sendable {
    // 实现在后续 Task 中逐步添加
}
```

### Step 3：对应测试文件骨架

```swift
import XCTest
import SwiftAnthropic
@testable import agentGui

final class MessageInvariantValidatorTests: XCTestCase {

    private let validator = MessageInvariantValidator()

    // MARK: - 辅助工厂方法

    /// 构造一条带 tool_use 对象的 assistant 消息。
    private func assistantMsg(toolUseIds: [String]) -> MessageParameter.Message {
        let objects: [MessageParameter.Message.Content.ContentObject] = toolUseIds.map {
            .toolUse($0, "bash", .init(from: [:]))
        }
        return .init(role: .assistant, content: .list(objects))
    }

    /// 构造一条带 tool_result 对象的 user 消息。
    private func userMsg(toolUseIds: [String]) -> MessageParameter.Message {
        let objects: [MessageParameter.Message.Content.ContentObject] = toolUseIds.map {
            .toolResult($0, "output", isError: nil)
        }
        return .init(role: .user, content: .list(objects))
    }

    /// 构造普通文本消息。
    private func textMsg(role: MessageParameter.Message.Role, text: String = "hello") -> MessageParameter.Message {
        .init(role: role, content: .text(text))
    }
}
```

> ⚠️ **注意：** `MessageParameter.Message.Content.Input` 用 SwiftAnthropic 公开的 `init(from:)` / 字典初始化；若编译报错可替换为现有代码库中已有的构造方式（搜索 `assistantObjects.append(.toolUse(`）。

### Step 4：运行测试（应通过，因为骨架无逻辑）

```
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fb2-task1 \
  -only-testing:agentGuiTests/MessageInvariantValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望输出：`Test Suite 'MessageInvariantValidatorTests' passed` 或 `0 tests ran`（骨架无测试方法时正常）。

### Step 5：Commit

```bash
git add agentGui/Services/ContextGovernance/MessageInvariantValidator.swift \
        agentGuiTests/MessageInvariantValidatorTests.swift
git commit -m "feat(F-B2): add MessageInvariantValidator skeleton and types"
```

---

## Task 2：工具 ID 扫描工具方法

### Step 1：在 `MessageInvariantValidator` 中添加私有扫描方法

在 `MessageInvariantValidator` 的 `body` 中追加（仍在 `struct MessageInvariantValidator` 内）：

```swift
    // MARK: - Internal Scanning Utilities

    /// 从单条 user 消息中收集所有 tool_result 的 toolUseId。
    func toolResultIds(in message: MessageParameter.Message) -> [String] {
        guard message.role == "user" else { return [] }
        guard case .list(let objects) = message.content else { return [] }
        return objects.compactMap { obj -> String? in
            if case .toolResult(let id, _, _, _) = obj { return id }
            // SwiftAnthropic 可能仅有 3 个参数的重载（无 content 参数）
            if case .toolResult(let id, _, _) = obj { return id }
            return nil
        }
    }

    /// 从单条 assistant 消息中收集所有 tool_use 的 id。
    func toolUseIds(in message: MessageParameter.Message) -> [String] {
        guard message.role == "assistant" else { return [] }
        guard case .list(let objects) = message.content else { return [] }
        return objects.compactMap { obj -> String? in
            if case .toolUse(let id, _, _) = obj { return id }
            return nil
        }
    }
```

> **关于 `.toolResult` 的参数数量：** SwiftAnthropic 2.2.1 实际 case 签名需从编译器报错中确认。已有用法见 `AgentLoopRoundExecutor.swift:957`（3 参数）和 `ClaudeService+ContextCompression.swift:245`（4 参数模式匹配）。若遇编译错误，以当前代码库实际使用的 pattern 为准。

### Step 2：对应单元测试

```swift
// MARK: - Scanning Utilities

func test_toolResultIds_returnsEmpty_forAssistantMessage() {
    let msg = assistantMsg(toolUseIds: ["id-1"])
    XCTAssertTrue(validator.toolResultIds(in: msg).isEmpty)
}

func test_toolResultIds_returnsIds_forUserMessage() {
    let msg = userMsg(toolUseIds: ["r-1", "r-2"])
    let ids = validator.toolResultIds(in: msg)
    XCTAssertEqual(Set(ids), Set(["r-1", "r-2"]))
}

func test_toolUseIds_returnsEmpty_forUserMessage() {
    let msg = userMsg(toolUseIds: ["id-1"])
    XCTAssertTrue(validator.toolUseIds(in: msg).isEmpty)
}

func test_toolUseIds_returnsIds_forAssistantMessage() {
    let msg = assistantMsg(toolUseIds: ["u-1", "u-2"])
    let ids = validator.toolUseIds(in: msg)
    XCTAssertEqual(Set(ids), Set(["u-1", "u-2"]))
}

func test_toolResultIds_returnsEmpty_forTextOnlyMessage() {
    let msg = textMsg(role: .user, text: "hello")
    XCTAssertTrue(validator.toolResultIds(in: msg).isEmpty)
}
```

### Step 3：运行测试，确认全部通过

```
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fb2-task2 \
  -only-testing:agentGuiTests/MessageInvariantValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Test Suite"
```

期望：`5 tests, 0 failures`。

### Step 4：Commit

```bash
git add agentGui/Services/ContextGovernance/MessageInvariantValidator.swift \
        agentGuiTests/MessageInvariantValidatorTests.swift
git commit -m "feat(F-B2): add toolResultIds/toolUseIds scanning utilities"
```

---

## Task 3：`adjustedStartIndex(_:in:)` 压缩边界调整

这是 F-B2 的核心方法，直接对应 Claude Code `adjustIndexToPreserveAPIInvariants()`。

### Step 1：先写失败测试（TDD）

```swift
// MARK: - adjustedStartIndex

func test_adjustedStartIndex_noToolCalls_returnsProposedIndex() {
    // [text-user, text-assistant, text-user, text-assistant]
    let messages: [MessageParameter.Message] = [
        textMsg(role: .user),
        textMsg(role: .assistant),
        textMsg(role: .user),
        textMsg(role: .assistant),
    ]
    let result = validator.adjustedStartIndex(2, in: messages)
    XCTAssertEqual(result, 2)
}

func test_adjustedStartIndex_toolPairFullyInKeptRange_returnsProposedIndex() {
    // 0: text-user
    // 1: assistant (tool_use A, B)
    // 2: user (tool_result A, B)
    // 3: text-assistant
    // 提案 startIndex = 1；pair 在 [1,2]，均在 kept range [1...] 内 → 不调整
    let messages: [MessageParameter.Message] = [
        textMsg(role: .user),
        assistantMsg(toolUseIds: ["A", "B"]),
        userMsg(toolUseIds: ["A", "B"]),
        textMsg(role: .assistant),
    ]
    let result = validator.adjustedStartIndex(1, in: messages)
    XCTAssertEqual(result, 1)
}

func test_adjustedStartIndex_toolUseBeforeStart_pullsBackIndex() {
    // 0: text-user
    // 1: assistant (tool_use A)          ← 被截断（不在 kept range）
    // 2: user (tool_result A)            ← 在 kept range，但 tool_use 缺失
    // 提案 startIndex = 2 → 应调整为 1（包含 tool_use）
    let messages: [MessageParameter.Message] = [
        textMsg(role: .user),
        assistantMsg(toolUseIds: ["A"]),
        userMsg(toolUseIds: ["A"]),
    ]
    let result = validator.adjustedStartIndex(2, in: messages)
    XCTAssertEqual(result, 1)
}

func test_adjustedStartIndex_multipleToolsPartialKept_pullsBackToEarliestRequired() {
    // 0: assistant (tool_use X)
    // 1: user (tool_result X)
    // 2: assistant (tool_use Y)
    // 3: user (tool_result Y)
    // 提案 startIndex = 3 → tool_result Y 需要 tool_use Y (at 2) → adjustedIndex = 2
    let messages: [MessageParameter.Message] = [
        assistantMsg(toolUseIds: ["X"]),
        userMsg(toolUseIds: ["X"]),
        assistantMsg(toolUseIds: ["Y"]),
        userMsg(toolUseIds: ["Y"]),
    ]
    let result = validator.adjustedStartIndex(3, in: messages)
    XCTAssertEqual(result, 2)
}

func test_adjustedStartIndex_startIndexZero_returnsZero() {
    let messages: [MessageParameter.Message] = [
        assistantMsg(toolUseIds: ["A"]),
        userMsg(toolUseIds: ["A"]),
    ]
    let result = validator.adjustedStartIndex(0, in: messages)
    XCTAssertEqual(result, 0)
}

func test_adjustedStartIndex_startIndexBeyondEnd_returnsProposedIndex() {
    let messages: [MessageParameter.Message] = [textMsg(role: .user)]
    let result = validator.adjustedStartIndex(5, in: messages)
    XCTAssertEqual(result, 5)
}

func test_adjustedStartIndex_emptyMessages_returnsProposedIndex() {
    let result = validator.adjustedStartIndex(0, in: [])
    XCTAssertEqual(result, 0)
}

func test_adjustedStartIndex_multipleToolUsesInOneAssistantMsg_pullsBackCorrectly() {
    // 0: assistant (tool_use A, tool_use B)
    // 1: user (tool_result A, tool_result B)
    // 2: assistant (text only)
    // 提案 startIndex = 1 → 需要 tool_use A+B（均在 index 0）→ adjustedIndex = 0
    let messages: [MessageParameter.Message] = [
        assistantMsg(toolUseIds: ["A", "B"]),
        userMsg(toolUseIds: ["A", "B"]),
        textMsg(role: .assistant),
    ]
    let result = validator.adjustedStartIndex(1, in: messages)
    XCTAssertEqual(result, 0)
}
```

### Step 2：运行测试，确认全部失败（因为方法尚未实现）

```
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fb2-task3a \
  -only-testing:agentGuiTests/MessageInvariantValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

期望：编译失败（方法未定义）。

### Step 3：实现 `adjustedStartIndex(_:in:)`

在 `MessageInvariantValidator` 中追加：

```swift
    // MARK: - Public API

    /// 调整拟定截断起点，确保 kept range `messages[adjustedIndex...]` 中
    /// 所有 tool_result 都能在 kept range 内找到对应的 tool_use。
    ///
    /// - Parameters:
    ///   - proposedStart: 拟定的截断起点（压缩方希望保留 `messages[proposedStart...]`）。
    ///   - messages: 完整消息数组（包含截断前的所有消息）。
    /// - Returns: 安全的截断起点（≤ proposedStart），保证配对完整。
    ///
    /// 对应 Claude Code `adjustIndexToPreserveAPIInvariants()`。
    func adjustedStartIndex(_ proposedStart: Int, in messages: [MessageParameter.Message]) -> Int {
        guard proposedStart > 0, proposedStart <= messages.count else {
            return proposedStart
        }

        var adjustedIndex = proposedStart

        // Step 1: 收集 kept range 中所有 tool_result 需要的 toolUseId
        var neededToolUseIds: Set<String> = []
        for i in adjustedIndex..<messages.count {
            neededToolUseIds.formUnion(toolResultIds(in: messages[i]))
        }

        guard !neededToolUseIds.isEmpty else { return adjustedIndex }

        // Step 2: 剔除 kept range 内已经存在的 tool_use id（它们不需要向前查找）
        for i in adjustedIndex..<messages.count {
            let presentIds = toolUseIds(in: messages[i])
            neededToolUseIds.subtract(presentIds)
        }

        // Step 3: 向前扫描，找到缺失的 tool_use
        var i = adjustedIndex - 1
        while i >= 0, !neededToolUseIds.isEmpty {
            let foundIds = toolUseIds(in: messages[i])
            let intersect = neededToolUseIds.intersection(foundIds)
            if !intersect.isEmpty {
                adjustedIndex = i
                neededToolUseIds.subtract(intersect)
            }
            i -= 1
        }

        return adjustedIndex
    }
```

### Step 4：运行测试，确认全部通过

```
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fb2-task3b \
  -only-testing:agentGuiTests/MessageInvariantValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|passed|failed"
```

期望：`Test Suite 'MessageInvariantValidatorTests' passed`，Task 1+2+3 的所有测试均绿。

### Step 5：Commit

```bash
git add agentGui/Services/ContextGovernance/MessageInvariantValidator.swift \
        agentGuiTests/MessageInvariantValidatorTests.swift
git commit -m "feat(F-B2): implement adjustedStartIndex for compaction boundary safety"
```

---

## Task 4：`validate(_:)` 全量不变量校验

### Step 1：先写失败测试

```swift
// MARK: - validate

func test_validate_emptyMessages_isValid() {
    let result = validator.validate([])
    XCTAssertTrue(result.isValid)
    XCTAssertTrue(result.violations.isEmpty)
}

func test_validate_textOnlyMessages_isValid() {
    let messages: [MessageParameter.Message] = [
        textMsg(role: .user),
        textMsg(role: .assistant),
    ]
    let result = validator.validate(messages)
    XCTAssertTrue(result.isValid)
}

func test_validate_pairedToolCallsInOrder_isValid() {
    let messages: [MessageParameter.Message] = [
        textMsg(role: .user),
        assistantMsg(toolUseIds: ["A"]),
        userMsg(toolUseIds: ["A"]),
    ]
    let result = validator.validate(messages)
    XCTAssertTrue(result.isValid)
}

func test_validate_orphanToolResult_returnsViolation() {
    // user 消息中有 tool_result "A"，但前面没有 assistant 含 tool_use "A"
    let messages: [MessageParameter.Message] = [
        textMsg(role: .user),
        userMsg(toolUseIds: ["A"]),
    ]
    let result = validator.validate(messages)
    XCTAssertFalse(result.isValid)
    XCTAssertEqual(result.violations.count, 1)
    if case .orphanToolResult(let id, let idx) = result.violations[0] {
        XCTAssertEqual(id, "A")
        XCTAssertEqual(idx, 1)
    } else {
        XCTFail("Expected orphanToolResult violation")
    }
}

func test_validate_orphanToolUse_returnsViolation() {
    // assistant 消息中有 tool_use "B"，但后面没有 user 含 tool_result "B"
    let messages: [MessageParameter.Message] = [
        assistantMsg(toolUseIds: ["B"]),
        textMsg(role: .user),
    ]
    let result = validator.validate(messages)
    XCTAssertFalse(result.isValid)
    let orphanUse = result.violations.first {
        if case .orphanToolUse(let id, _) = $0 { return id == "B" }
        return false
    }
    XCTAssertNotNil(orphanUse)
}

func test_validate_multiplePairsAllMatchedInOrder_isValid() {
    // 两对 tool_use / tool_result，按顺序
    let messages: [MessageParameter.Message] = [
        assistantMsg(toolUseIds: ["X", "Y"]),
        userMsg(toolUseIds: ["X", "Y"]),
        assistantMsg(toolUseIds: ["Z"]),
        userMsg(toolUseIds: ["Z"]),
    ]
    let result = validator.validate(messages)
    XCTAssertTrue(result.isValid)
}

func test_validate_toolResultBeforeToolUse_isOrphan() {
    // tool_result 出现在 tool_use 之前（非法顺序）
    let messages: [MessageParameter.Message] = [
        userMsg(toolUseIds: ["C"]),       // tool_result C 在前
        assistantMsg(toolUseIds: ["C"]),  // tool_use C 在后
    ]
    let result = validator.validate(messages)
    XCTAssertFalse(result.isValid)
}
```

### Step 2：运行测试，确认失败（方法未定义）

```
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fb2-task4a \
  -only-testing:agentGuiTests/MessageInvariantValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL"
```

期望：编译失败（`validate` 未定义）。

### Step 3：实现 `validate(_:)`

```swift
    /// 全量扫描 `messages`，检测所有 tool_use/tool_result 配对违规。
    /// 使用场景：压缩前断言、调试、测试。
    ///
    /// 校验规则：
    /// 1. 每个 tool_result 的 toolUseId 必须能在**前面**（较小下标）的 assistant 消息中找到对应 tool_use。
    /// 2. 每个 tool_use 的 id 必须能在**后面**（较大下标）的 user 消息中找到对应 tool_result。
    ///
    /// - Returns: `ValidationResult`，包含所有违规（空 = 合法）。
    func validate(_ messages: [MessageParameter.Message]) -> ValidationResult {
        // 建立 toolUseId → messageIndex 的映射（仅 assistant 消息）
        var toolUseIndexByID: [String: Int] = [:]
        // 追踪每个 tool_use 是否被 tool_result 响应
        var pendingToolUseIds: Set<String> = []

        var violations: [InvariantViolation] = []

        for (idx, message) in messages.enumerated() {
            if message.role == "assistant" {
                let ids = toolUseIds(in: message)
                for id in ids {
                    toolUseIndexByID[id] = idx
                    pendingToolUseIds.insert(id)
                }
            } else if message.role == "user" {
                let ids = toolResultIds(in: message)
                for id in ids {
                    if toolUseIndexByID[id] == nil {
                        // 没有前置 tool_use：孤立 tool_result
                        violations.append(.orphanToolResult(toolUseId: id, messageIndex: idx))
                    } else {
                        pendingToolUseIds.remove(id)
                    }
                }
            }
        }

        // 剩余未被响应的 tool_use
        for id in pendingToolUseIds {
            if let idx = toolUseIndexByID[id] {
                violations.append(.orphanToolUse(toolCallId: id, messageIndex: idx))
            }
        }

        return ValidationResult(violations: violations)
    }
```

### Step 4：运行测试，确认全部通过

```
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fb2-task4b \
  -only-testing:agentGuiTests/MessageInvariantValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

期望：所有测试绿，0 failures。

### Step 5：Commit

```bash
git add agentGui/Services/ContextGovernance/MessageInvariantValidator.swift \
        agentGuiTests/MessageInvariantValidatorTests.swift
git commit -m "feat(F-B2): implement validate() for full invariant scan"
```

---

## Task 5：边界情况强化测试

确保各种边界情况不会崩溃，且行为符合预期。

### Step 1：追加边界测试

```swift
// MARK: - 边界情况

func test_adjustedStartIndex_startIndexEqualToMessagesCount_returnsProposedIndex() {
    let messages: [MessageParameter.Message] = [textMsg(role: .user)]
    // proposedStart == messages.count（表示不保留任何消息）
    let result = validator.adjustedStartIndex(1, in: messages)
    XCTAssertEqual(result, 1)
}

func test_adjustedStartIndex_chainedToolRounds_pullsBackToEarliestRequired() {
    // round-1: assistant(tool_use X) + user(tool_result X)
    // round-2: assistant(tool_use Y) + user(tool_result Y)
    // round-3: assistant(text only)
    // 提案 startIndex = 3 (仅保留 round-3)
    // tool_result Y 需要 tool_use Y (index 2) → adjustedIndex = 2
    // tool_result X 不在 kept range → 不影响（只需保证 kept range 自洽）
    let messages: [MessageParameter.Message] = [
        assistantMsg(toolUseIds: ["X"]),  // 0
        userMsg(toolUseIds: ["X"]),       // 1
        assistantMsg(toolUseIds: ["Y"]),  // 2
        userMsg(toolUseIds: ["Y"]),       // 3
        textMsg(role: .assistant),        // 4
    ]
    let result = validator.adjustedStartIndex(3, in: messages)
    XCTAssertEqual(result, 2)
}

func test_adjustedStartIndex_orphanToolResultNotInKeptRange_doesNotPullBack() {
    // [0: assistant(tool_use A), 1: user(tool_result A), 2: text-user, 3: text-assistant]
    // proposedStart = 2 → kept range [2,3] 中没有 tool_result → 不需要调整
    let messages: [MessageParameter.Message] = [
        assistantMsg(toolUseIds: ["A"]),
        userMsg(toolUseIds: ["A"]),
        textMsg(role: .user),
        textMsg(role: .assistant),
    ]
    let result = validator.adjustedStartIndex(2, in: messages)
    XCTAssertEqual(result, 2)
}

func test_validate_singleTextMessage_isValid() {
    let result = validator.validate([textMsg(role: .user)])
    XCTAssertTrue(result.isValid)
}

func test_validate_multipleOrphans_reportsAll() {
    // 两个孤立 tool_result，一个孤立 tool_use
    let messages: [MessageParameter.Message] = [
        assistantMsg(toolUseIds: ["orphan-use"]),  // 0: orphan tool_use
        userMsg(toolUseIds: ["r1", "r2"]),         // 1: orphan tool_results
    ]
    let result = validator.validate(messages)
    XCTAssertFalse(result.isValid)
    XCTAssertEqual(result.violations.count, 3)  // 2 orphanToolResult + 1 orphanToolUse
}
```

### Step 2：运行测试，确认全部通过

```
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fb2-task5 \
  -only-testing:agentGuiTests/MessageInvariantValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|tests,"
```

期望：全部通过，0 failures。

### Step 3：Commit

```bash
git add agentGuiTests/MessageInvariantValidatorTests.swift
git commit -m "test(F-B2): add edge case coverage for MessageInvariantValidator"
```

---

## Task 6：将 Xcode 项目文件更新并验证编译

由于 Swift Package 之外的源文件需要在 `project.pbxproj` 中登记，在 Xcode 中执行：

1. File → Add Files to "agentGui"：
   - 选择 `agentGui/Services/ContextGovernance/MessageInvariantValidator.swift`
   - 选择 `agentGuiTests/MessageInvariantValidatorTests.swift`（加入 agentGuiTests target）
2. Build（⌘B），确认 0 errors。
3. 运行对应测试 target（⌘U 或命令行），确认全绿。

若文件已在 Task 1 通过 Xcode 创建，跳过步骤 1。

### 最终完整测试命令

```
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-fb2-final \
  -only-testing:agentGuiTests/MessageInvariantValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

期望：
```
Test Suite 'MessageInvariantValidatorTests' passed
Executed N tests, with 0 failures
```

### Commit

```bash
git add agentGui.xcodeproj/project.pbxproj
git commit -m "chore(F-B2): register MessageInvariantValidator files in Xcode project"
```

---

## 完整文件快照（实现完成后）

### `agentGui/Services/ContextGovernance/MessageInvariantValidator.swift`

```swift
import SwiftAnthropic

// MARK: - InvariantViolation

enum InvariantViolation: Equatable, Sendable {
    case orphanToolResult(toolUseId: String, messageIndex: Int)
    case orphanToolUse(toolCallId: String, messageIndex: Int)
}

// MARK: - ValidationResult

struct ValidationResult: Equatable, Sendable {
    var isValid: Bool { violations.isEmpty }
    let violations: [InvariantViolation]
    static let valid = ValidationResult(violations: [])
}

// MARK: - MessageInvariantValidator

struct MessageInvariantValidator: Sendable {

    // MARK: Internal Scanning

    func toolResultIds(in message: MessageParameter.Message) -> [String] {
        guard message.role == "user", case .list(let objects) = message.content else { return [] }
        return objects.compactMap { obj -> String? in
            if case .toolResult(let id, _, _, _) = obj { return id }
            if case .toolResult(let id, _, _) = obj { return id }
            return nil
        }
    }

    func toolUseIds(in message: MessageParameter.Message) -> [String] {
        guard message.role == "assistant", case .list(let objects) = message.content else { return [] }
        return objects.compactMap { obj -> String? in
            if case .toolUse(let id, _, _) = obj { return id }
            return nil
        }
    }

    // MARK: Public API

    func adjustedStartIndex(_ proposedStart: Int, in messages: [MessageParameter.Message]) -> Int {
        guard proposedStart > 0, proposedStart <= messages.count else { return proposedStart }

        var adjustedIndex = proposedStart

        var neededToolUseIds: Set<String> = []
        for i in adjustedIndex..<messages.count {
            neededToolUseIds.formUnion(toolResultIds(in: messages[i]))
        }
        guard !neededToolUseIds.isEmpty else { return adjustedIndex }

        for i in adjustedIndex..<messages.count {
            neededToolUseIds.subtract(toolUseIds(in: messages[i]))
        }

        var i = adjustedIndex - 1
        while i >= 0, !neededToolUseIds.isEmpty {
            let found = neededToolUseIds.intersection(toolUseIds(in: messages[i]))
            if !found.isEmpty {
                adjustedIndex = i
                neededToolUseIds.subtract(found)
            }
            i -= 1
        }

        return adjustedIndex
    }

    func validate(_ messages: [MessageParameter.Message]) -> ValidationResult {
        var toolUseIndexByID: [String: Int] = [:]
        var pendingToolUseIds: Set<String> = []
        var violations: [InvariantViolation] = []

        for (idx, message) in messages.enumerated() {
            if message.role == "assistant" {
                for id in toolUseIds(in: message) {
                    toolUseIndexByID[id] = idx
                    pendingToolUseIds.insert(id)
                }
            } else if message.role == "user" {
                for id in toolResultIds(in: message) {
                    if toolUseIndexByID[id] == nil {
                        violations.append(.orphanToolResult(toolUseId: id, messageIndex: idx))
                    } else {
                        pendingToolUseIds.remove(id)
                    }
                }
            }
        }

        for id in pendingToolUseIds {
            if let idx = toolUseIndexByID[id] {
                violations.append(.orphanToolUse(toolCallId: id, messageIndex: idx))
            }
        }

        return ValidationResult(violations: violations)
    }
}
```

---

## 与 F-B3 CompactionCoordinator 的接口约定

F-B3 在决定压缩边界时调用：

```swift
let validator = MessageInvariantValidator()
let safeStart = validator.adjustedStartIndex(proposedStart, in: messages)
// 同时可校验压缩后数组
let check = validator.validate(Array(messages[safeStart...]))
assert(check.isValid, "Compaction produced invalid message slice: \(check.violations)")
```

F-B3 不修改本文件，仅消费上述两个 public API。

---

## 验收标准（来自设计文档）

| 验收条件 | 覆盖测试 |
|---------|---------|
| 校验函数返回所有无法被截断的消息 ID 集合 | `test_validate_orphanToolResult_returnsViolation` |
| `CompactionCoordinator` 在确定压缩边界时尊重不变量 | F-B3 集成（非本计划范围）|
| 校验覆盖各类引用完整性场景 | Task 3–5 共 14 个测试 |
| tool_use 在截断边界前，对应 tool_result 在截断边界后 → 自动拉回 | `test_adjustedStartIndex_toolUseBeforeStart_pullsBackIndex` |
| 普通文本消息不触发调整 | `test_adjustedStartIndex_noToolCalls_returnsProposedIndex` |
