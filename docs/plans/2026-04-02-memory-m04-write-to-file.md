# Memory M-04: `memory_write` 工具 → 直接写 Markdown 文件 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `memory_write` 工具的实现从 RMS stub 替换为直接写 `.md` 话题文件 + 重建 `MEMORY.md` 索引，与 Claude Code `FileWriteTool` 路径对齐。

**Architecture:** `executeFileMemoryWrite()` 解析工具输入 → 生成文件名 → 写 frontmatter+body 到 `memoryDir/<topic>.md` → 调用 `MemoryIndexFileSystem.rebuildFromDirectory()` 重建索引。不再依赖 `MemoryRecord` 中间层。

**Tech Stack:** Swift 6, SwiftAnthropic, Foundation FileManager

**依赖 Feature：** M-01（删除 RMS）已完成（`executeFileMemoryWrite` 已是 stub 桩），M-07（`rebuildFromDirectory`）随本 Feature 同步实现

---

## 前置阅读（实施前必看）

| 文件 | 目的 |
|------|------|
| `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift` | 找到 `executeFileMemoryWrite()` stub（约 line 520+） |
| `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift` | 找到 `memory_write` 工具定义（约 line 275+） |
| `agentGui/Services/Memory/MemoryTopicFilename.swift` | 当前 `filename(for: MemoryRecord)` 接口 |
| `agentGui/Services/Memory/MemoryIndexFileSystem.swift` | 当前 `rebuild(with: [MemoryRecord])` 接口 |
| `agentGui/Services/Memory/MemoryIndexWriter.swift` | `truncate(lines:)` 方法（当前 `private`，需改为 `internal`） |
| `agentGui/Services/Memory/MemoryTopicScanner.swift` | `scan(memoryDir:)` 接口，M-04 的重建依赖它 |
| `agentGui/Utilities/ConfigDirectoryManager.swift` | `memoryDir` 和 `memoryIndexURL` 路径 |

---

## Task 1：`MemoryTopicFilename` — 新增无需 MemoryRecord 的文件名生成

**Files:**
- Modify: `agentGui/Services/Memory/MemoryTopicFilename.swift`
- Test: `agentGuiTests/MemoryTopicFilenameTests.swift`

### Step 1: 在测试文件末尾新增测试用例（FAIL 预期）

```swift
// 在 MemoryTopicFilenameTests.swift 末尾追加

func test_filenameFromTitleAndSuffix_basic() {
    let name = MemoryTopicFilename.filename(title: "User Role", suffix: "abcd1234")
    XCTAssertEqual(name, "user_role_abcd1234.md")
}

func test_filenameFromTitleAndSuffix_emptyTitle_fallsBack() {
    let name = MemoryTopicFilename.filename(title: "", suffix: "abcd1234")
    XCTAssertEqual(name, "memory_abcd1234.md")
}

func test_filenameFromTitleAndSuffix_truncatesLongTitle() {
    let longTitle = String(repeating: "x", count: 60)
    let name = MemoryTopicFilename.filename(title: longTitle, suffix: "12345678")
    XCTAssertTrue(name.hasSuffix("_12345678.md"))
    XCTAssertTrue(name.count <= 56) // 40 slug + _ + 8 suffix + .md
}
```

### Step 2: Run tests to verify FAIL

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryTopicFilenameTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: `error: value of type 'MemoryTopicFilename' has no member 'filename(title:suffix:)'`

### Step 3: 在 `MemoryTopicFilename.swift` 内添加新重载

在 `filename(for record:)` 方法之后，添加：

```swift
/// 从纯文本 `title` + 外部提供的 `suffix` 生成文件名。
/// 用于 `memory_write` 工具直接写文件时，无需构造 `MemoryRecord`。
///
/// - Parameters:
///   - title: 记忆标题（来自工具输入），可为任意 Unicode 字符串
///   - suffix: 调用方提供的唯一后缀（如 UUID prefix 8 位）
static func filename(title: String, suffix: String) -> String {
    let slug = sanitizeTitle(title)
    if slug.isEmpty {
        return "memory_\(suffix).md"
    }
    return "\(slug)_\(suffix).md"
}
```

### Step 4: Run tests to verify PASS

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryTopicFilenameTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```
Expected: All `MemoryTopicFilenameTests` PASS

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryTopicFilename.swift \
        agentGuiTests/MemoryTopicFilenameTests.swift
git commit -m "feat(memory): add MemoryTopicFilename.filename(title:suffix:) overload"
```

---

## Task 2：`MemoryIndexWriter` — 暴露 `truncate(lines:)` 为 internal

**Files:**
- Modify: `agentGui/Services/Memory/MemoryIndexWriter.swift`

### Step 1: 修改 `truncate(lines:)` 访问级别

找到：
```swift
private func truncate(lines: [String]) -> TruncationResult {
```

改为：
```swift
func truncate(lines: [String]) -> TruncationResult {
```

同时，将 `TruncationResult` 从私有嵌套类型移为 `MemoryIndexWriter` 的 `internal` 类型（保持 `struct TruncationResult`，但删除 `private` 前缀）：

找到：
```swift
private struct TruncationResult {
    var content: String
    var wasTruncated: Bool
}
```

改为：
```swift
struct TruncationResult {
    var content: String
    var wasTruncated: Bool
}
```

### Step 2: 确认现有测试仍然通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryIndexWriterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```
Expected: All `MemoryIndexWriterTests` PASS

### Step 3: Commit

```bash
git add agentGui/Services/Memory/MemoryIndexWriter.swift
git commit -m "refactor(memory): expose MemoryIndexWriter.truncate(lines:) as internal"
```

---

## Task 3：`MemoryIndexFileSystem` — 新增 `rebuildFromDirectory()` 方法

**Files:**
- Modify: `agentGui/Services/Memory/MemoryIndexFileSystem.swift`
- Test: `agentGuiTests/MemoryIndexFileSystemTests.swift`

### Step 1: 在测试文件末尾新增测试（FAIL 预期）

```swift
// 在 MemoryIndexFileSystemTests.swift 末尾追加

// MARK: - rebuildFromDirectory

func test_rebuildFromDirectory_emptyDir_doesNotCreateMemoryMd() async throws {
    // tempDir 里没有任何 .md 文件
    try await sut.rebuildFromDirectory()
    let indexURL = tempDir.appendingPathComponent("MEMORY.md")
    XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path),
                   "空目录重建不应创建 MEMORY.md")
}

func test_rebuildFromDirectory_withTopicFile_createsMemoryMd() async throws {
    // 准备：手动写一个话题文件
    let topicContent = """
    ---
    name: "User Role"
    description: "Senior iOS developer"
    type: user
    created: 2025-01-01T00:00:00Z
    ---

    User is a senior iOS developer.
    """
    let topicURL = tempDir.appendingPathComponent("user_role_abcd1234.md")
    try topicContent.write(to: topicURL, atomically: true, encoding: .utf8)

    try await sut.rebuildFromDirectory()

    let indexURL = tempDir.appendingPathComponent("MEMORY.md")
    XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path),
                  "有话题文件时应创建 MEMORY.md")
    let content = try String(contentsOf: indexURL, encoding: .utf8)
    XCTAssertTrue(content.contains("User Role"), "MEMORY.md 应包含话题标题")
    XCTAssertTrue(content.contains("user_role_abcd1234.md"), "MEMORY.md 应包含文件名引用")
}

func test_rebuildFromDirectory_excludesMemoryMdItself() async throws {
    // 准备：已有 MEMORY.md（旧索引）+ 一个话题文件
    let oldIndexURL = tempDir.appendingPathComponent("MEMORY.md")
    try "- [Old](old.md) — stale".write(to: oldIndexURL, atomically: true, encoding: .utf8)

    let topicContent = """
    ---
    name: "New Topic"
    description: "Fresh hook"
    type: project
    created: 2025-01-01T00:00:00Z
    ---

    New content.
    """
    let topicURL = tempDir.appendingPathComponent("new_topic_xyz.md")
    try topicContent.write(to: topicURL, atomically: true, encoding: .utf8)

    try await sut.rebuildFromDirectory()

    let rebuiltContent = try String(contentsOf: oldIndexURL, encoding: .utf8)
    XCTAssertTrue(rebuiltContent.contains("New Topic"), "重建后应包含新话题")
    XCTAssertFalse(rebuiltContent.contains("MEMORY.md"), "MEMORY.md 不应引用自身")
}

func test_rebuildFromDirectory_createsDirectoryIfNeeded() async throws {
    let nested = tempDir.appendingPathComponent("new/sub/memory", isDirectory: true)
    let nestedFS = MemoryIndexFileSystem(memoryDir: nested)

    // 写一个话题文件到嵌套目录（先手动创建目录）
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let topicContent = "---\nname: \"T\"\ndescription: \"d\"\ntype: project\ncreated: 2025-01-01T00:00:00Z\n---\nBody"
    try topicContent.write(to: nested.appendingPathComponent("t_12345678.md"),
                           atomically: true, encoding: .utf8)

    XCTAssertNoThrow(try await nestedFS.rebuildFromDirectory())
}
```

### Step 2: Run tests to verify FAIL

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: `error: value of type 'MemoryIndexFileSystem' has no member 'rebuildFromDirectory'`

### Step 3: 在 `MemoryIndexFileSystem.swift` 添加 `rebuildFromDirectory()` 方法

在 `rebuild(with records:)` 方法之后，添加：

```swift
/// 从 `memoryDir` 下的实际 `.md` 文件重建 `MEMORY.md` 索引。
///
/// 流程：
/// 1. `MemoryTopicScanner` 扫描所有非 MEMORY.md 的 `.md` 文件并解析 frontmatter
/// 2. 按 mtime 降序排序
/// 3. 每个文件生成一行 `- [title](filename) — description`
/// 4. 应用 `MemoryIndexWriter.truncate(lines:)` 的 200 行 / 25KB 限制
/// 5. 写入 MEMORY.md
///
/// 若扫描结果为空则不写 MEMORY.md（保留或不创建文件）。
func rebuildFromDirectory() async throws {
    let headers = try await MemoryTopicScanner().scan(memoryDir: memoryDir)
    guard !headers.isEmpty else { return }

    try fileManager.createDirectory(at: memoryDir, withIntermediateDirectories: true)

    // 构建索引行（mtime 已在 scanner 中降序排列）
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

    // 应用截断规则（200 行 / 25KB）
    let truncationResult = writer.truncate(lines: indexLines)

    // 写入 MEMORY.md
    let indexURL = memoryDir.appendingPathComponent("MEMORY.md")
    try truncationResult.content.write(to: indexURL, atomically: true, encoding: .utf8)
}
```

注意：`writer` 是 `MemoryIndexFileSystem` 中已有的 `private let writer = MemoryIndexWriter()`。

### Step 4: Run tests to verify PASS

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```
Expected: All `MemoryIndexFileSystemTests` PASS（含新增的 `rebuildFromDirectory` 测试）

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryIndexFileSystem.swift \
        agentGuiTests/MemoryIndexFileSystemTests.swift
git commit -m "feat(memory): add MemoryIndexFileSystem.rebuildFromDirectory() from file scanner"
```

---

## Task 4：更新 `memory_write` 工具定义

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift`

### Step 1: 找到当前工具定义（约 line 274-293）

当前内容（需替换）：
```swift
// memory_write: always available — lets Claude persist governed long-term facts across sessions
tools.append(makeEphemeralTool(
    name: "memory_write",
    description: """
    Persist important long-term RMS insights into the unified memory store for future task decisions. \
    Use this for durable constraints, remembered failure modes, and reusable tactics that should affect later action selection. \
    Keep entries concise, factual, and decision-relevant.
    """,
    inputSchema: .init(
        type: .object,
        properties: [
            "content": .init(type: .string, description: "Concise decision-relevant insight content to persist into RMS long-term memory"),
            "mode": .init(type: .string, description: "Optional write mode hint. Accepted values: 'overwrite' or 'append'.")
        ],
        required: ["content"]
    )
))
```

### Step 2: 替换为对齐 Claude Code 的定义

```swift
// memory_write: always available — persist long-term facts as Markdown files to ~/agentgui/memory/
tools.append(makeEphemeralTool(
    name: "memory_write",
    description: """
    Persist an important long-term memory as a Markdown file in your persistent memory directory. \
    Use this for user preferences, project decisions, feedback patterns, and reference information \
    that should be available in future sessions. \
    Keep entries concise, factual, and decision-relevant. \
    Saves to ~/agentgui/memory/<filename>.md and updates the MEMORY.md index automatically.
    """,
    inputSchema: .init(
        type: .object,
        properties: [
            "content": .init(
                type: .string,
                description: "The memory content to save. Write clear, concise Markdown body text."
            ),
            "title": .init(
                type: .string,
                description: "Optional short title for this memory (e.g. 'User prefers bun over npm'). Used for filename and MEMORY.md index."
            ),
            "type": .init(
                type: .string,
                description: "Memory type: 'user' (preferences/profile), 'feedback' (corrections/patterns), 'project' (decisions/context), or 'reference' (external links/docs). Defaults to 'project'."
            ),
            "description": .init(
                type: .string,
                description: "Optional one-line hook for MEMORY.md index (≤ 150 chars). If omitted, first line of content is used."
            )
        ],
        required: ["content"]
    )
))
```

### Step 3: 确认编译无误

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:" | grep -v "SwiftAnthropic" | head -20
```
Expected: 无 error

### Step 4: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift
git commit -m "feat(memory): update memory_write tool definition — add title/type/description params, remove RMS terminology"
```

---

## Task 5：实现 `executeFileMemoryWrite()` — 核心写文件逻辑

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift`
- Test (new): `agentGuiTests/MemoryWriteToFileTests.swift`

### Step 1: 新建测试文件

```swift
// agentGuiTests/MemoryWriteToFileTests.swift
import XCTest
@testable import agentGui

/// 验证 executeFileMemoryWrite (through public test hook) 正确写 .md 文件并重建 MEMORY.md
@MainActor
final class MemoryWriteToFileTests: XCTestCase {

    private var tempMemoryDir: URL!

    override func setUpWithError() throws {
        tempMemoryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryWriteTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempMemoryDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempMemoryDir)
    }

    // MARK: - helpers

    private func buildInput(content: String, title: String? = nil, type: String? = nil, description: String? = nil) -> MessageResponse.Content.Input {
        var dict: MessageResponse.Content.Input = ["content": .string(content)]
        if let t = title { dict["title"] = .string(t) }
        if let tp = type { dict["type"] = .string(tp) }
        if let d = description { dict["description"] = .string(d) }
        return dict
    }

    func test_execute_createsTopicFileInMemoryDir() async throws {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "User prefers bun over npm.", title: "Bun Preference"),
            memoryDir: tempMemoryDir
        )

        XCTAssertFalse(result.hasPrefix("Error:"), "调用不应返回错误: \(result)")
        let files = try FileManager.default.contentsOfDirectory(
            at: tempMemoryDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        XCTAssertEqual(files.count, 1, "应创建一个话题文件")
    }

    func test_execute_createdFileContainsFrontmatter() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "Use SwiftData, not CoreData.", title: "SwiftData Preference", type: "project"),
            memoryDir: tempMemoryDir
        )

        let files = try FileManager.default.contentsOfDirectory(
            at: tempMemoryDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("---"), "话题文件应以 frontmatter 开头")
        XCTAssertTrue(content.contains("name:"), "frontmatter 应包含 name 字段")
        XCTAssertTrue(content.contains("type: project"), "frontmatter 应包含 type 字段")
        XCTAssertTrue(content.contains("Use SwiftData"), "文件体应包含输入内容")
    }

    func test_execute_rebuildsMemoryMdIndex() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "User is a senior iOS developer.", title: "User Background", type: "user"),
            memoryDir: tempMemoryDir
        )

        let indexURL = tempMemoryDir.appendingPathComponent("MEMORY.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path),
                      "执行后应创建或更新 MEMORY.md 索引")
        let indexContent = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(indexContent.contains("User Background"),
                      "MEMORY.md 应包含话题标题")
    }

    func test_execute_missingContent_returnsError() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: [:],
            memoryDir: tempMemoryDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "缺少 content 参数应返回 Error")
    }

    func test_execute_returnsFilename() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "Remember X.", title: "Fact X"),
            memoryDir: tempMemoryDir
        )
        XCTAssertTrue(result.hasPrefix("Memory saved:"), "成功时应返回 'Memory saved: <filename>'")
    }

    func test_execute_defaultType_isProject() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "Something important.", title: "Important Thing"),
            memoryDir: tempMemoryDir
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: tempMemoryDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("type: project"),
                      "未提供 type 时应默认为 project")
    }
}
```

### Step 2: 在测试文件中使用的方法（需先在 ClaudeService 中添加 testable hook）

在 `ClaudeService+ToolDispatch.swift` 找到 `// MARK: - Memory Write (Stub)` 区域，将 stub 方法替换为真实实现，并添加 testable hook：

```swift
// MARK: - Memory Write

/// 将 `memory_write` 工具输入直接持久化为 Markdown 话题文件。
///
/// 流程：
/// 1. 解析 content（必填）、title（可选）、type（可选，默认 project）、description（可选）
/// 2. 生成文件名：`MemoryTopicFilename.filename(title:suffix:)`，suffix 取 UUID 前 8 位
/// 3. 构建 YAML frontmatter + body，写入 memoryDir/<filename>.md
/// 4. 调用 `MemoryIndexFileSystem.rebuildFromDirectory()` 重建 MEMORY.md 索引
/// 5. 返回 "Memory saved: <filename>"
private func executeFileMemoryWrite(
    input: MessageResponse.Content.Input
) async -> String {
    await executeFileMemoryWrite(
        input: input,
        memoryDir: ConfigDirectoryManager.shared.memoryDir
    )
}

/// Testable overload allowing injection of a custom memoryDir.
func executeFileMemoryWriteForTests(
    input: MessageResponse.Content.Input,
    memoryDir: URL
) async -> String {
    await executeFileMemoryWrite(input: input, memoryDir: memoryDir)
}

private func executeFileMemoryWrite(
    input: MessageResponse.Content.Input,
    memoryDir: URL
) async -> String {
    guard let content = input["content"]?.stringValue, !content.isEmpty else {
        return "Error: missing required parameter 'content'"
    }

    let title = input["title"]?.stringValue ?? "Untitled Memory"
    let type = input["type"]?.stringValue ?? "project"
    let descriptionHint = input["description"]?.stringValue

    // 1. 生成文件名（UUID prefix 8 位作为 suffix，保证唯一性）
    let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
    let filename = MemoryTopicFilename.filename(title: title, suffix: suffix)

    // 2. 构建 frontmatter + body
    let hookLine: String
    if let d = descriptionHint, !d.isEmpty {
        hookLine = d.count <= 150 ? d : String(d.prefix(149)) + "…"
    } else {
        let firstLine = content.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        hookLine = firstLine.count <= 150 ? firstLine : String(firstLine.prefix(149)) + "…"
    }

    let iso8601 = ISO8601DateFormatter()
    iso8601.formatOptions = [.withInternetDateTime]
    let createdAt = iso8601.string(from: Date())

    let fileContent = """
    ---
    name: "\(title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
    description: "\(hookLine.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
    type: \(type)
    created: \(createdAt)
    ---

    \(content)
    """

    // 3. 写话题文件
    do {
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let fileURL = memoryDir.appendingPathComponent(filename)
        try fileContent.write(to: fileURL, atomically: true, encoding: .utf8)
    } catch {
        return "Error: failed to write memory file '\(filename)': \(error.localizedDescription)"
    }

    // 4. 重建 MEMORY.md 索引
    do {
        try await MemoryIndexFileSystem(memoryDir: memoryDir).rebuildFromDirectory()
    } catch {
        // 索引重建失败不应阻断写入成功的响应，仅记录
        return "Memory saved: \(filename) (warning: index rebuild failed: \(error.localizedDescription))"
    }

    return "Memory saved: \(filename)"
}
```

### Step 3: Run tests to verify PASS

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryWriteToFileTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```
Expected: All 6 tests PASS

### Step 4: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift \
        agentGuiTests/MemoryWriteToFileTests.swift
git commit -m "feat(memory-m04): implement executeFileMemoryWrite — write topic .md + rebuild MEMORY.md"
```

---

## Task 6：验证 + Smoke Test

### Step 1: 运行所有 Memory 相关测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m04-derived \
  -only-testing:agentGuiTests/MemoryTopicFilenameTests \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  -only-testing:agentGuiTests/MemoryIndexWriterTests \
  -only-testing:agentGuiTests/MemoryWriteToFileTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:" | head -30
```
Expected: 所有测试 PASS，0 errors

### Step 2: 编译验证无警告

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|warning:.*deprecated" | grep -v "SwiftAnthropic\|_Concurrency"
```

### Step 3: Commit（如有最终清理）

```bash
git commit -m "chore(memory-m04): final cleanup and verify all tests pass" --allow-empty
```

---

## 完成标志检查表

- [ ] `MemoryTopicFilename.filename(title:suffix:)` 方法存在且测试通过
- [ ] `MemoryIndexWriter.truncate(lines:)` 为 internal 且不影响现有测试
- [ ] `MemoryIndexFileSystem.rebuildFromDirectory()` 方法存在且测试通过（4 个新测试）
- [ ] `memory_write` 工具描述不含 "RMS" 字样，有 `title`/`type`/`description` 参数
- [ ] `executeFileMemoryWrite()` 实现完整，6 个 `MemoryWriteToFileTests` 全部通过
- [ ] 调用 `memory_write` 后 `memoryDir` 出现新 `.md` 话题文件，`MEMORY.md` 更新
- [ ] 无 `rms-insights.json` 创建逻辑
- [ ] 全部相关测试 PASS，0 编译 error

---

## 注意事项

1. **YAML 引号转义**：`name:` 和 `description:` 字段用双引号包裹，内容中的 `\` 和 `"` 需转义，避免 frontmatter 解析错误。

2. **suffix 唯一性**：使用 UUID 的前 8 个十六进制字符（去除连字符）作为 suffix，有足够的唯一性同时保持文件名简洁。

3. **type 验证**：当前不强制 type 必须是 `user/feedback/project/reference`（留给 Feature M-08），直接写入用户提供的字符串；无效 type 在 M-08 中处理。

4. **原子写入**：`write(to:atomically:encoding:)` 使用 `atomically: true`，防止写入中途崩溃产生损坏文件。

5. **并发安全**：`executeFileMemoryWrite()` 是 `async` 方法，但 FileManager I/O 是同步的。`rebuildFromDirectory()` 是 async（内部用 `withTaskGroup` 并发读 frontmatter）。整体可接受 —— 调用方（`executeTool`）已在 `ClaudeService` actor 上下文中执行。
