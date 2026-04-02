# Memory M-08: Frontmatter Type Validation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 引入 `MemoryTopicType` 类型安全枚举，使所有通过 `memory_write` 工具和 extraction subagent 写入的 `.md` 文件 frontmatter 中的 `type:` 字段都经过合法性校验，对齐 Claude Code `memoryTypes.ts` 的 `parseMemoryType`。

**Architecture:** 新增 `Models/MemoryTopicType.swift`（枚举 + 解析函数），将 `MemoryTopicHeader.memoryType` 从 `String?` 改为 `MemoryTopicType?`，同步更新 `MemoryManifestFormatter`（type tag 格式化）和 `ClaudeService+ToolDispatch`（写入前 validate + fallback），最后补全被此类型变更影响的测试。

**Tech Stack:** Swift 6.0+, XCTest, agentGui.xcodeproj (macOS)

---

## 背景参考

### Claude Code 对齐点（`src/memdir/memoryTypes.ts`）

```typescript
export const MEMORY_TYPES = ['user', 'feedback', 'project', 'reference'] as const
export type MemoryType = (typeof MEMORY_TYPES)[number]

export function parseMemoryType(raw: unknown): MemoryType | undefined {
  if (typeof raw !== 'string') return undefined
  return MEMORY_TYPES.find(t => t === raw)
}
```

关键行为：
- 四个合法值：`user` / `feedback` / `project` / `reference`
- 未知或缺失值 → `undefined`（**不报错，静默降级**）
- 类型标签格式：`[user]` / `[feedback]` / `[project]` / `[reference]`，未知类型 **省略**标签

`memoryScan.ts` 中：
```typescript
type: parseMemoryType(frontmatter.type),
```

`formatMemoryManifest` 中：
```typescript
const tag = m.type ? `[${m.type}] ` : ''
```

### 现状分析

#### 文件 1：`MemoryTopicScanner.swift:11`
```swift
var memoryType: String?     // frontmatter `type:` 字段
```
**问题**：`String?` 允许任意字符串，无类型安全。需改为 `MemoryTopicType?`。

#### 文件 2：`MemoryManifestFormatter.swift:27`
```swift
let typeTag = header.memoryType.map { "[\($0)] " } ?? ""
```
**当前行为**：`memoryType` 若为任意字符串，会被直接插入 `[xxx]`。  
**目标行为**：只有合法 `MemoryTopicType` 才生成标签（类型安全枚举后 `.map` 逻辑不变）。

#### 文件 3：`ClaudeService+ToolDispatch.swift:542`
```swift
let type = input["type"]?.stringValue ?? "project"
```
**问题**：用户传入任意字符串（如 `"bogus"`）会直接写入 frontmatter。  
**目标**：用 `MemoryTopicType.parse()` 校验，非法值 fallback 为 `.project`。

#### 受影响测试（需同步更新）

| 文件 | 变更原因 |
|------|---------|
| `MemoryTopicScannerTests.swift` | `memoryType` 从 `String?` 改为 `MemoryTopicType?` |
| `MemoryManifestFormatterTests.swift` | `MemoryTopicHeader(memoryType:)` 参数类型变更 |

---

## 执行命令

所有 task 统一使用以下命令运行测试：

```bash
xcodebuild test \
  -quiet \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-derived \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:agentGuiTests/MemoryTopicTypeTests \
  -only-testing:agentGuiTests/MemoryTopicScannerTests \
  -only-testing:agentGuiTests/MemoryManifestFormatterTests \
  -only-testing:agentGuiTests/MemoryWriteToFileTests
```

---

## Task 1：新增 `MemoryTopicType` 枚举（新文件）

**Files:**
- Create: `agentGui/Models/MemoryTopicType.swift`
- Test: `agentGuiTests/MemoryTopicTypeTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryTopicTypeTests.swift
import XCTest
@testable import agentGui

final class MemoryTopicTypeTests: XCTestCase {

    // MARK: - allCases

    func test_allCases_containsExactlyFourTypes() {
        let cases = MemoryTopicType.allCases
        XCTAssertEqual(cases.count, 4)
        XCTAssertTrue(cases.contains(.user))
        XCTAssertTrue(cases.contains(.feedback))
        XCTAssertTrue(cases.contains(.project))
        XCTAssertTrue(cases.contains(.reference))
    }

    // MARK: - rawValue

    func test_rawValues_matchClaudeCodeConstants() {
        XCTAssertEqual(MemoryTopicType.user.rawValue,      "user")
        XCTAssertEqual(MemoryTopicType.feedback.rawValue,  "feedback")
        XCTAssertEqual(MemoryTopicType.project.rawValue,   "project")
        XCTAssertEqual(MemoryTopicType.reference.rawValue, "reference")
    }

    // MARK: - parse

    func test_parse_validLowercaseValues_returnsCorrectCase() {
        XCTAssertEqual(MemoryTopicType.parse("user"),      .user)
        XCTAssertEqual(MemoryTopicType.parse("feedback"),  .feedback)
        XCTAssertEqual(MemoryTopicType.parse("project"),   .project)
        XCTAssertEqual(MemoryTopicType.parse("reference"), .reference)
    }

    func test_parse_unknownString_returnsNil() {
        XCTAssertNil(MemoryTopicType.parse("bogus"))
        XCTAssertNil(MemoryTopicType.parse("User"))   // 大小写敏感
        XCTAssertNil(MemoryTopicType.parse(""))
    }

    func test_parse_nil_returnsNil() {
        XCTAssertNil(MemoryTopicType.parse(nil))
    }
}
```

### Step 2: 运行测试确认失败

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-derived \
  CODE_SIGNING_ALLOWED=NO -only-testing:agentGuiTests/MemoryTopicTypeTests
```

期望：编译失败（`MemoryTopicType` 未定义）。

### Step 3: 创建实现文件

```swift
// agentGui/Models/MemoryTopicType.swift
import Foundation

/// 四类记忆类型，对齐 Claude Code `memoryTypes.ts` 中的 `MEMORY_TYPES`。
///
/// - `user`: 用户角色/偏好/背景信息
/// - `feedback`: 用户给出的工作方式指导
/// - `project`: 项目工作状态/目标/决策
/// - `reference`: 外部系统信息指针
///
/// `parse(_:)` 对未知值静默返回 `nil`（对齐 Claude Code `parseMemoryType`，
/// 保证 legacy 文件降级兼容性）。
enum MemoryTopicType: String, CaseIterable, Sendable {
    case user
    case feedback
    case project
    case reference

    /// 从 frontmatter raw 字符串解析类型。
    /// - Parameter raw: `nil`、空字符串或未知字符串均返回 `nil`。
    static func parse(_ raw: String?) -> MemoryTopicType? {
        guard let raw, !raw.isEmpty else { return nil }
        return MemoryTopicType(rawValue: raw)
    }
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-derived \
  CODE_SIGNING_ALLOWED=NO -only-testing:agentGuiTests/MemoryTopicTypeTests
```

期望：全部通过（0 failures）。

### Step 5: Commit

```bash
git add agentGui/Models/MemoryTopicType.swift agentGuiTests/MemoryTopicTypeTests.swift
git commit -m "feat(memory/m08): add MemoryTopicType enum with parse() fallback"
```

---

## Task 2：更新 `MemoryTopicHeader.memoryType` 类型

**Files:**
- Modify: `agentGui/Services/Memory/MemoryTopicScanner.swift:11` — 字段类型改为 `MemoryTopicType?`
- Modify: `agentGui/Services/Memory/MemoryTopicScanner.swift:88` — 构造时调用 `MemoryTopicType.parse()`
- Test: `agentGuiTests/MemoryTopicScannerTests.swift`

### Step 1: 更新 MemoryTopicScanner.swift

**修改 `MemoryTopicHeader` 字段声明（第 11 行）：**

```swift
// 原代码：
var memoryType: String?     // frontmatter `type:` 字段

// 改为：
var memoryType: MemoryTopicType?   // frontmatter `type:` 字段（类型安全枚举）
```

**修改 `readHeader(from:)` 中构造语句（第 88 行附近）：**

```swift
// 原代码：
return MemoryTopicHeader(
    filename: url.lastPathComponent,
    filePath: url,
    mtimeMs: mtimeMs,
    title: fm2["name"],
    description: fm2["description"],
    memoryType: fm2["type"]
)

// 改为：
return MemoryTopicHeader(
    filename: url.lastPathComponent,
    filePath: url,
    mtimeMs: mtimeMs,
    title: fm2["name"],
    description: fm2["description"],
    memoryType: MemoryTopicType.parse(fm2["type"])
)
```

### Step 2: 更新 MemoryTopicScannerTests.swift

将断言从 `String?` 比较改为 `MemoryTopicType?` 比较：

```swift
// 原代码（第 48 行）：
XCTAssertEqual(headers[0].memoryType, "feedback")

// 改为：
XCTAssertEqual(headers[0].memoryType, .feedback)
```

同时为未知类型新增一个测试用例：

```swift
func test_scan_unknownType_returnsNilType() async throws {
    let content = """
    ---
    name: "Unknown Type Memory"
    type: "bogus_type"
    ---
    Body.
    """
    let file = tempDir.appendingPathComponent("unknown_type_abc12345.md")
    try content.write(to: file, atomically: true, encoding: .utf8)

    let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
    XCTAssertEqual(headers.count, 1)
    XCTAssertNil(headers[0].memoryType,
                 "未知 type 值应静默降级为 nil，不报错")
}
```

### Step 3: 运行测试

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-derived \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:agentGuiTests/MemoryTopicTypeTests \
  -only-testing:agentGuiTests/MemoryTopicScannerTests
```

期望：全部通过。若有编译错误，表示其他引用 `memoryType: String?` 的地方需要同步更新（先修复编译再跑测试）。

### Step 4: Commit

```bash
git add agentGui/Services/Memory/MemoryTopicScanner.swift \
        agentGuiTests/MemoryTopicScannerTests.swift
git commit -m "feat(memory/m08): MemoryTopicHeader.memoryType typed as MemoryTopicType?"
```

---

## Task 3：更新 `MemoryManifestFormatter` 测试（同步类型变更）

**Files:**
- Modify: `agentGuiTests/MemoryManifestFormatterTests.swift`

**说明**：`MemoryManifestFormatter.swift` 本体代码不用改动 — `.map { "[\($0)] " }` 在
`MemoryTopicType?` 上仍然有效，因为 `MemoryTopicType.rawValue` 和原来的 `String` 值完全一致。

只需更新测试文件中直接构造 `MemoryTopicHeader` 的两处 `memoryType:` 参数。

### Step 1: 运行当前测试，确认哪些因类型变更而失败

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-derived \
  CODE_SIGNING_ALLOWED=NO -only-testing:agentGuiTests/MemoryManifestFormatterTests
```

期望：编译失败，提示 `cannot convert value of type 'String' to expected argument type 'MemoryTopicType?'`。

### Step 2: 更新测试中的 MemoryTopicHeader 构造调用

在 `MemoryManifestFormatterTests.swift` 中有三处构造：

**处 1（第 17 行）— `memoryType: "feedback"` 改为 `memoryType: .feedback`**：

```swift
// 原代码：
let header = MemoryTopicHeader(
    filename: "test_topic_abc12345.md",
    filePath: URL(fileURLWithPath: "/tmp/test_topic_abc12345.md"),
    mtimeMs: 1_700_000_000_000,
    title: "Test Topic",
    description: "A brief description",
    memoryType: "feedback"
)

// 改为：
let header = MemoryTopicHeader(
    filename: "test_topic_abc12345.md",
    filePath: URL(fileURLWithPath: "/tmp/test_topic_abc12345.md"),
    mtimeMs: 1_700_000_000_000,
    title: "Test Topic",
    description: "A brief description",
    memoryType: .feedback
)
```

**处 2（第 33 行）和处 3（第 49 行）** — `memoryType: nil` 无需改动，`nil` 对两种类型均兼容。

同时，更新关于 type tag 的断言注释（确保语义清晰）：

```swift
// 仅确认旧断言的含义不变：
XCTAssertTrue(output.contains("[feedback]"), "应含 [type] 标签")
```

### Step 3: 运行测试

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-derived \
  CODE_SIGNING_ALLOWED=NO -only-testing:agentGuiTests/MemoryManifestFormatterTests
```

期望：全部通过。

### Step 4: 同时运行全部 M-08 相关测试

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-derived \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:agentGuiTests/MemoryTopicTypeTests \
  -only-testing:agentGuiTests/MemoryTopicScannerTests \
  -only-testing:agentGuiTests/MemoryManifestFormatterTests
```

### Step 5: Commit

```bash
git add agentGuiTests/MemoryManifestFormatterTests.swift
git commit -m "test(memory/m08): update MemoryManifestFormatterTests for MemoryTopicType"
```

---

## Task 4：在 `executeFileMemoryWrite` 中添加 type 校验 + fallback

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift:542`
- Test: `agentGuiTests/MemoryWriteToFileTests.swift`

### Step 1: 写失败测试（无效 type 应 fallback 为 project）

在 `MemoryWriteToFileTests.swift` 末尾添加：

```swift
func test_execute_invalidType_fallbacksToProject() async throws {
    let service = ClaudeService()
    _ = await service.executeFileMemoryWriteForTests(
        input: buildInput(content: "Some content.", title: "Some Title", type: "bogus_invalid"),
        memoryDir: tempMemoryDir
    )
    let files = try FileManager.default.contentsOfDirectory(
        at: tempMemoryDir,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
    XCTAssertEqual(files.count, 1, "应创建话题文件")
    let content = try String(contentsOf: files[0], encoding: .utf8)
    XCTAssertTrue(content.contains("type: project"),
                  "无效 type 应 fallback 为 project，实际内容：\(content)")
    XCTAssertFalse(content.contains("type: bogus_invalid"),
                   "无效 type 不应写入 frontmatter")
}
```

### Step 2: 运行测试确认失败

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-derived \
  CODE_SIGNING_ALLOWED=NO -only-testing:agentGuiTests/MemoryWriteToFileTests
```

期望：`test_execute_invalidType_fallbacksToProject` 失败（当前 `"bogus_invalid"` 会被原样写入）。

### Step 3: 修改 `executeFileMemoryWrite` 实现

找到 `ClaudeService+ToolDispatch.swift` 中第 542 行：

```swift
// 原代码：
let type = input["type"]?.stringValue ?? "project"

// 改为：
let type = MemoryTopicType.parse(input["type"]?.stringValue) ?? .project
```

然后修改 `fileContent` 中 `type:` 的写出（第 570 行附近），将 `.rawValue` 写入：

```swift
// 找到：
        let fileContent = """
        ---
        name: "\(yamlEscape(title))"
        description: "\(yamlEscape(hookLine))"
        type: \(type)
        created: \(createdAt)
        ---

        \(content)
        """

// 改为（type 现在是 MemoryTopicType，需要 .rawValue）：
        let fileContent = """
        ---
        name: "\(yamlEscape(title))"
        description: "\(yamlEscape(hookLine))"
        type: \(type.rawValue)
        created: \(createdAt)
        ---

        \(content)
        """
```

### Step 4: 运行全部 M-08 测试

```bash
xcodebuild test -quiet -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-derived \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:agentGuiTests/MemoryTopicTypeTests \
  -only-testing:agentGuiTests/MemoryTopicScannerTests \
  -only-testing:agentGuiTests/MemoryManifestFormatterTests \
  -only-testing:agentGuiTests/MemoryWriteToFileTests
```

期望：全部通过。

### Step 5: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift \
        agentGuiTests/MemoryWriteToFileTests.swift
git commit -m "feat(memory/m08): validate memory type in executeFileMemoryWrite, fallback to project"
```

---

## Task 5：全量回归验证

**目标**：确认 M-08 改动没有破坏其他 Memory 相关测试。

### Step 1: 运行完整 Memory 测试套件

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m08-final \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:agentGuiTests/MemoryTopicTypeTests \
  -only-testing:agentGuiTests/MemoryTopicScannerTests \
  -only-testing:agentGuiTests/MemoryManifestFormatterTests \
  -only-testing:agentGuiTests/MemoryWriteToFileTests \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  -only-testing:agentGuiTests/MemoryBootstrapSystemPromptInjectionTests \
  -only-testing:agentGuiTests/MemoryExtractionPromptBuilderTests \
  -only-testing:agentGuiTests/RelevantMemoryRecallServiceTests \
  -only-testing:agentGuiTests/MemoryTypeGuidanceComposerTests
```

期望：全部通过。

### Step 2: 如有失败，分析原因

常见失败点：
- `RelevantMemorySideQueryTests`：其 fixture 手写了 `MemoryTopicHeader`，若构造参数类型不匹配需同步更新
- `MemoryRecallHookTests`：若 mock 了 `MemoryTopicHeader`，需同步更新 `memoryType:` 参数

修复方式：将所有测试中 `memoryType: "feedback"` 形式的字符串字面量改为 `memoryType: .feedback`，nil 保持不变。

### Step 3: Final commit

```bash
git add -A
git commit -m "feat(memory/m08): frontmatter type validation complete — MemoryTopicType enum"
```

---

## 完成标志检查清单

- [ ] `MemoryTopicType` 枚举存在于 `agentGui/Models/MemoryTopicType.swift`
- [ ] `MemoryTopicType.allCases.count == 4`
- [ ] `MemoryTopicType.parse("bogus") == nil`（静默降级）
- [ ] `MemoryTopicHeader.memoryType` 声明为 `MemoryTopicType?`（不是 `String?`）
- [ ] `MemoryTopicScanner` 在构造 `MemoryTopicHeader` 时调用 `MemoryTopicType.parse()`
- [ ] `MemoryManifestFormatter` 的 `[type]` 标签来自 `MemoryTopicType.rawValue`（枚举保证合法）
- [ ] `executeFileMemoryWrite` 中 `type` 变量为 `MemoryTopicType`，非法输入 fallback `.project`
- [ ] `MemoryTopicTypeTests` 全绿
- [ ] `MemoryTopicScannerTests` 全绿
- [ ] `MemoryManifestFormatterTests` 全绿
- [ ] `MemoryWriteToFileTests` 全绿（含 `test_execute_invalidType_fallbacksToProject`）

---

## 不在本 Feature 范围内

以下内容故意不包含：

- `MemoryTopicFrontmatter` 结构体 — 设计文档中提到但无实际调用方，属过度抽象，YAGNI
- `MemoryTopicFileComposer` 增加 `compose(title:type:...)` 方法 — M-04 的职责，M-08 仅处理类型校验
- `MemoryScope.swift` 改动 — 与类型校验无关
- Extraction subagent 的 type 校验 — M-06 职责（subagent 通过 `memory_write` 工具写入，M-08 的工具校验已覆盖）
