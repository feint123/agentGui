# Memory M-07: Memory Index 从文件系统构建 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 完成 M-07 收尾：移除 no-op `rebuild()` 遗留桩方法、修复无描述文件的行格式边界案例、为 `rebuildFromDirectory()` 补充行为验证测试，确保 MEMORY.md 索引 100% 由文件系统驱动，无 `MemoryRecord` 中间层。

**Architecture:** `rebuildFromDirectory()` 核心路径已在 M-04 实现：`MemoryTopicScanner.scan()` → 按 mtime 降序排列 → 格式化索引行 → `MemoryIndexWriter.truncate()` 200行/25KB → 写入 `MEMORY.md`。本计划聚焦清理和测试覆盖补全。

**Tech Stack:** Swift 6, Foundation FileManager, XCTest

**依赖 Feature：** M-01（删除 RMS，已完成）、M-02（删除 MemoryRecord，已完成）、M-04（实现 rebuildFromDirectory，已完成）

---

## 现状速查（实施前必看）

| 组件 | 文件 | 状态 |
|------|------|------|
| `rebuildFromDirectory()` | `agentGui/Services/Memory/MemoryIndexFileSystem.swift` | ✅ 已实现 |
| `MemoryIndexWriter.build(records:)` 删除 | `agentGui/Services/Memory/MemoryIndexWriter.swift` | ✅ M-02 已删 |
| `MemoryIndexWriter.truncate(lines:)` | `agentGui/Services/Memory/MemoryIndexWriter.swift` | ✅ 保留 |
| 基础 4 个测试 | `agentGuiTests/MemoryIndexFileSystemTests.swift` | ✅ 已有 |
| `rebuild()` no-op 桩 | `agentGui/Services/Memory/MemoryIndexFileSystem.swift:17-20` | ⚠️ 需删除 |
| `MemoryIndexWriter.swift` TODO 注释 | `agentGui/Services/Memory/MemoryIndexWriter.swift:3-6` | ⚠️ 需更新 |
| 无描述文件的行格式 (`— ` 尾迹) | `agentGui/Services/Memory/MemoryIndexFileSystem.swift:42-49` | ⚠️ 需修复 |
| 行为验证测试（格式/排序/截断） | `agentGuiTests/MemoryIndexFileSystemTests.swift` | ⚠️ 缺少 |

**`ClaudeService+ToolDispatch.swift`** 已调用 `rebuildFromDirectory()`（line 592），无需改动。

---

## Task 1：清理遗留桩方法 + 更新 MemoryIndexWriter 注释

**Files:**
- Modify: `agentGui/Services/Memory/MemoryIndexFileSystem.swift`
- Modify: `agentGui/Services/Memory/MemoryIndexWriter.swift`

无调用者，直接删除/更新。

### Step 1: 删除 `MemoryIndexFileSystem.swift` 中的 no-op `rebuild()` 方法

当前文件 line 17-20：
```swift
/// M-07 占位实现（保留向后兼容）。
func rebuild() throws {
    // no-op: replaced by rebuildFromDirectory()
}
```

**删除整段**（含文档注释）。完成后文件从 `init(...)` 直接跳到 `rebuildFromDirectory()`。

### Step 2: 更新 `MemoryIndexWriter.swift` 顶部注释

将：
```swift
/// MEMORY.md 索引写入器。
/// `build(records:)` 已在 M-02 移除；M-07 将在 MemoryIndexFileSystem 中新增
/// 从文件系统扫描驱动的 rebuild 路径。
struct MemoryIndexWriter: Sendable {
```
改为：
```swift
/// MEMORY.md 索引截断工具。
///
/// `build(records:)` 已在 M-02 移除。`MemoryIndexFileSystem.rebuildFromDirectory()`
/// 从文件系统扫描驱动重建，内部通过此类的 `truncate(lines:)` 方法截断。
struct MemoryIndexWriter: Sendable {
```

### Step 3: 验证编译通过

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`（无任何 `error:`）

### Step 4: Commit

```bash
git add agentGui/Services/Memory/MemoryIndexFileSystem.swift \
        agentGui/Services/Memory/MemoryIndexWriter.swift
git commit -m "refactor(memory): remove no-op rebuild() stub and update MemoryIndexWriter doc"
```

---

## Task 2：修复无描述文件的行格式（去除尾迹 `— `）

**Files:**
- Modify: `agentGui/Services/Memory/MemoryIndexFileSystem.swift`
- Test: `agentGuiTests/MemoryIndexFileSystemTests.swift`

**问题**：当 topic 文件 frontmatter 没有 `description:` 字段时，当前代码生成：
```
- [My Title](my_title_abc.md) — 
```
末尾多余的 ` — ` 是噪音。期望输出应为：
```
- [My Title](my_title_abc.md)
```
这与 Claude Code 的 MEMORY.md 惯例一致（只有有描述时才加 ` — hook`）。

### Step 1: 在 `MemoryIndexFileSystemTests.swift` 追加 2 个失败测试

在文件末尾（最后一个 `}` 之前）追加：

```swift
// MARK: - 行格式：无描述文件

func test_indexLine_withDescription_includesSeparatorAndDesc() async throws {
    let topicContent = """
    ---
    name: "Auth Flow"
    description: "OAuth 2.0 PKCE login flow"
    type: project
    created: 2025-01-01T00:00:00Z
    ---

    Details.
    """
    try topicContent.write(
        to: tempDir.appendingPathComponent("auth_flow_12345678.md"),
        atomically: true, encoding: .utf8)

    try await sut.rebuildFromDirectory()

    let content = try String(
        contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
    XCTAssertTrue(
        content.contains("- [Auth Flow](auth_flow_12345678.md) — OAuth 2.0 PKCE login flow"),
        "有描述时应包含 ' — description'，实际：\(content)")
}

func test_indexLine_withoutDescription_noTrailingSeparator() async throws {
    let topicContent = """
    ---
    name: "Bare Title"
    type: project
    created: 2025-01-01T00:00:00Z
    ---

    No description in frontmatter.
    """
    try topicContent.write(
        to: tempDir.appendingPathComponent("bare_title_12345678.md"),
        atomically: true, encoding: .utf8)

    try await sut.rebuildFromDirectory()

    let content = try String(
        contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
    // 不应有尾迹 "— "
    XCTAssertFalse(
        content.contains("— \n") || content.hasSuffix("— "),
        "无描述时行末不应有 '— '，实际：\(content)")
    XCTAssertTrue(
        content.contains("- [Bare Title](bare_title_12345678.md)"),
        "无描述文件应有简洁行，实际：\(content)")
}
```

### Step 2: 运行测试，确认 `test_indexLine_withoutDescription_noTrailingSeparator` 失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m07-derived \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests/test_indexLine_withoutDescription_noTrailingSeparator \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`FAIL - XCTAssertFalse failed`（因为当前有尾迹 `— `）

### Step 3: 修复 `MemoryIndexFileSystem.rebuildFromDirectory()` 中的行格式生成

定位 `agentGui/Services/Memory/MemoryIndexFileSystem.swift` 中的 `indexLines` 构建逻辑：

**修改前：**
```swift
let indexLines: [String] = headers.map { header in
    let title = header.title ?? header.filename
    let rawDesc = header.description ?? ""
    let truncatedDesc: String
    if rawDesc.count <= 150 {
        truncatedDesc = rawDesc
    } else {
        truncatedDesc = String(rawDesc.prefix(149)) + "…"
    }
    return "- [\(title)](\(header.filename)) — \(truncatedDesc)"
}
```

**修改后：**
```swift
let indexLines: [String] = headers.map { header in
    let title = header.title ?? header.filename
    let baseLine = "- [\(title)](\(header.filename))"
    guard let rawDesc = header.description, !rawDesc.isEmpty else {
        return baseLine
    }
    let hook = rawDesc.count <= 150
        ? rawDesc
        : String(rawDesc.prefix(149)) + "…"
    return "\(baseLine) — \(hook)"
}
```

### Step 4: 运行所有 MemoryIndexFileSystem 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m07-derived \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

预期：所有 6 个测试 PASS（4 原有 + 2 新增）

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryIndexFileSystem.swift \
        agentGuiTests/MemoryIndexFileSystemTests.swift
git commit -m "fix(memory): omit ' — ' separator when topic file has no description"
```

---

## Task 3：补充行为验证测试（排序、截断、标题回退）

**Files:**
- Modify: `agentGuiTests/MemoryIndexFileSystemTests.swift`

这些测试验证 `rebuildFromDirectory()` 的核心行为契约，当前 4 个测试未覆盖。

### Step 1: 追加 4 个测试到 `MemoryIndexFileSystemTests.swift`

在文件末尾（最后一个 `}` 之前）追加：

```swift
// MARK: - mtime 排序

func test_mtimeSorting_newerFileAppearsFirst() async throws {
    // 写两个话题文件，间隔 1 秒以确保 mtime 差异
    let olderContent = """
    ---
    name: "Older Topic"
    description: "Written first"
    type: project
    created: 2025-01-01T00:00:00Z
    ---
    Body
    """
    let olderURL = tempDir.appendingPathComponent("older_abcd1234.md")
    try olderContent.write(to: olderURL, atomically: true, encoding: .utf8)

    // 人为设置旧 mtime（30 秒前）
    let oldDate = Date(timeIntervalSinceNow: -30)
    try FileManager.default.setAttributes(
        [.modificationDate: oldDate], ofItemAtPath: olderURL.path)

    let newerContent = """
    ---
    name: "Newer Topic"
    description: "Written second"
    type: project
    created: 2025-01-01T00:00:00Z
    ---
    Body
    """
    let newerURL = tempDir.appendingPathComponent("newer_efgh5678.md")
    try newerContent.write(to: newerURL, atomically: true, encoding: .utf8)
    // newerURL 的 mtime 是当前时间，比 oldDate 更新

    try await sut.rebuildFromDirectory()

    let content = try String(
        contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
    let newerRange = content.range(of: "Newer Topic")
    let olderRange = content.range(of: "Older Topic")
    XCTAssertNotNil(newerRange, "MEMORY.md 应包含 Newer Topic")
    XCTAssertNotNil(olderRange, "MEMORY.md 应包含 Older Topic")
    XCTAssertLessThan(
        newerRange!.lowerBound, olderRange!.lowerBound,
        "较新文件应排在较旧文件前面")
}

// MARK: - 描述超长截断

func test_descriptionTruncation_over150Chars_appendsEllipsis() async throws {
    let longDesc = String(repeating: "a", count: 200)  // 200 chars，远超 150
    let topicContent = """
    ---
    name: "Long Desc"
    description: "\(longDesc)"
    type: project
    created: 2025-01-01T00:00:00Z
    ---
    Body
    """
    try topicContent.write(
        to: tempDir.appendingPathComponent("long_desc_12345678.md"),
        atomically: true, encoding: .utf8)

    try await sut.rebuildFromDirectory()

    let content = try String(
        contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
    // 截断后应是 149 个 'a' + '…'
    let expected = String(repeating: "a", count: 149) + "…"
    XCTAssertTrue(
        content.contains(expected),
        "超过 150 字符的描述应在 149 处截断并附加 '…'")
}

// MARK: - 200 行截断

func test_200LineTruncation_appendsWarningAndCapsAtLimit() async throws {
    // 写 201 个话题文件
    for i in 1...201 {
        let suffix = String(format: "%08d", i)
        let content = """
        ---
        name: "Topic \(i)"
        description: "Hook \(i)"
        type: project
        created: 2025-01-01T00:00:00Z
        ---
        Body
        """
        try content.write(
            to: tempDir.appendingPathComponent("topic_\(suffix).md"),
            atomically: true, encoding: .utf8)
        // 人为设置不同 mtime，让排序稳定
        let d = Date(timeIntervalSinceNow: Double(i) * -1)
        try FileManager.default.setAttributes(
            [.modificationDate: d],
            ofItemAtPath: tempDir.appendingPathComponent("topic_\(suffix).md").path)
    }

    try await sut.rebuildFromDirectory()

    let content = try String(
        contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
    let lines = content.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }
    XCTAssertLessThanOrEqual(lines.count, 200, "索引行数不应超过 200")
    XCTAssertTrue(content.contains("WARNING"), "超出行数时应追加 WARNING 说明")
}

// MARK: - 无标题回退到文件名

func test_titleFallback_noNameInFrontmatter_usesFilename() async throws {
    // frontmatter 没有 name: 字段
    let topicContent = """
    ---
    description: "Some hook"
    type: project
    created: 2025-01-01T00:00:00Z
    ---
    Body
    """
    let filename = "no_name_abcd1234.md"
    try topicContent.write(
        to: tempDir.appendingPathComponent(filename),
        atomically: true, encoding: .utf8)

    try await sut.rebuildFromDirectory()

    let content = try String(
        contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
    XCTAssertTrue(
        content.contains("- [\(filename)](\(filename))"),
        "无 name: 时应用文件名作为链接文本，实际：\(content)")
}
```

### Step 2: 运行所有 MemoryIndexFileSystem 测试（应全 PASS）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m07-derived \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:|Build succeeded"
```

预期：10 个测试全部 PASS（4 原有 + 2 Task 2 + 4 Task 3）

### Step 3: Commit

```bash
git add agentGuiTests/MemoryIndexFileSystemTests.swift
git commit -m "test(memory): add behavior tests for rebuildFromDirectory sorting, truncation, title fallback"
```

---

## Task 4：最终验证（完成标志）

### Step 1: 运行 Memory 相关测试套件

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m07-final-derived \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  -only-testing:agentGuiTests/MemoryIndexReaderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"
```

预期：16 个测试（10 MemoryIndexFileSystem + 6 MemoryIndexReader）全部 PASS

### Step 2: 验证完成标志清单

- [ ] `agentGui/Services/Memory/MemoryIndexFileSystem.swift` 中无 `rebuild()` 无参方法
- [ ] `agentGui/Services/Memory/MemoryIndexWriter.swift` 注释不再含 "M-07 将…新增"
- [ ] `rebuildFromDirectory()` 在无描述文件时生成 `- [title](filename)`（无尾迹 `— `）
- [ ] `MemoryIndexFileSystemTests` 共 10 个测试全部 PASS
- [ ] 项目中无任何 `MemoryRecord` 编译引用（运行 `grep -r "MemoryRecord" agentGui/ --include="*.swift"` 输出为空）
- [ ] `MEMORY.md` 内容完全由 `MemoryTopicScanner` 从文件系统扫描驱动，无 JSON 中间层

### Step 3: 最终提交（如有未 commit 的变更）

```bash
git add -A
git commit -m "feat(memory/M-07): complete filesystem-driven MEMORY.md index rebuild"
```

---

## 实施顺序

```
Task 1（清理桩方法）→ Task 2（行格式修复 + 测试）→ Task 3（补充行为测试）→ Task 4（验收）
```

Task 1 和 Task 2 存在对同一文件的修改，**按顺序实施**（先 Task 1，再 Task 2）。

---

## 关键实现说明

### 行格式对齐 Claude Code

Claude Code 的 MEMORY.md entry 格式（来自 `prompts.ts`）：
```
- [Title](file.md) — one-line hook
```

agentGui `rebuildFromDirectory()` 已对齐此格式。无 description 时只输出 `- [title](filename)`，避免 agent 看到悬空的 ` — `。

### `rebuild()` 桩方法可安全删除

`grep -r "\.rebuild()" agentGui/` 搜索结果显示无生产代码调用旧的 `rebuild()` 方法，所有调用点均使用 `rebuildFromDirectory()`。

### `MemoryIndexWriter.truncate()` 的角色

`MemoryIndexWriter` 在 M-07 后仅保留 `truncate(lines:)` 一个方法，被 `MemoryIndexFileSystem` 内部调用。`MemoryIndexReader` 复用其 `maxLines`/`maxBytes` 常量。此分工稳定，无需进一步重构。

### `MemoryIndexRebuildFromDirectoryTests` 命名

设计文档提到新增独立测试类 `MemoryIndexRebuildFromDirectoryTests`，但由于 `rebuildFromDirectory()` 是 `MemoryIndexFileSystem` 的主要公共接口，测试统一放在 `MemoryIndexFileSystemTests.swift` 中，无需拆分文件，符合 YAGNI 原则。
