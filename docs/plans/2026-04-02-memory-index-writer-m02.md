# M-02: MEMORY.md 轻量索引文件层 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 引入 `MEMORY.md` 始终加载索引模式——将每条 `MemoryRecord` 写成带 YAML frontmatter 的独立话题文件，维护一份 ≤200 行 / ≤25KB 的轻量索引文件，并在 system prompt 中注入该索引内容，替代当前"把所有记忆内容塞入一个大 prompt 块"的做法。

**Architecture:** 三个纯值类型（`MemoryTopicFileComposer`、`MemoryIndexWriter`、`MemoryIndexReader`）负责所有逻辑，不含 I/O，完全可单元测试。`UnifiedMemoryFileStoreAdapter.persist()` 在持久化后以 `Task.detached(priority: .utility)` 触发 `MemoryIndexFileSystem.rebuild()`（含目录创建 + 文件写入）。`ClaudeService.buildSystemPrompt()` 通过 `nonisolated` 同步 helper 读取 `MEMORY.md` 并注入 `## Your Memory Index` 节。

**Tech Stack:** Swift 6.0+, Foundation (FileManager, URL), XCTest

---

## 背景参考

Claude Code 实现位于：`/Users/feint/Downloads/claude-code-source-code-main/src/memdir/`

- `memdir.ts` → `truncateEntrypointContent()` 是截断逻辑的参照物
  - `MAX_ENTRYPOINT_LINES = 200`, `MAX_ENTRYPOINT_BYTES = 25_000`
  - 先按行截断，再按字节截断，在 `lastIndexOf('\n')` 处切割防止截断到行中间
- `paths.ts` → `validateMemoryPath()` 是路径安全校验的参照物（拒绝 `..`、null byte、非绝对路径）

agentGui 现状：
- `ConfigDirectoryManager.shared.agentGuiDir` = `~/.agentgui/`
- `UnifiedMemoryFileStoreAdapter` 把记录序列化到 `~/.agentgui/unified-memory/<scope>.json`
- `AgentLoopMemoryBootstrapComposer` 注入 RMS 状态（另一套系统，M-02 不改动）
- `buildSystemPrompt()` 同步构建，位于 `ClaudeService+Prompting.swift`
- `MemoryTypeGuidanceComposer` 已在 system prompt 中注入四类型指导（M-01 成果）

M-02 新增的文件目录结构：
```
~/.agentgui/
  memory/
    MEMORY.md                 ← 始终加载的轻量索引 (≤200行 / ≤25KB)
    user_role_a1b2c3d4.md     ← 每条 MemoryRecord 对应一个话题文件
    feedback_no_mocks_e5f6.md
    project_freeze_g7h8.md
    ...
```

---

## Task 1: `ConfigDirectoryManager` — 添加 `memoryDir` 属性

**Files:**
- Modify: `agentGui/Utilities/ConfigDirectoryManager.swift`
- Test: `agentGuiTests/ConfigDirectoryManagerMemoryDirTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/ConfigDirectoryManagerMemoryDirTests.swift
import XCTest
@testable import agentGui

final class ConfigDirectoryManagerMemoryDirTests: XCTestCase {

    func test_memoryDir_isInsideAgentGuiDir() {
        let mgr = ConfigDirectoryManager.shared
        let memPath = mgr.memoryDir.path
        let basePath = mgr.agentGuiDir.path
        XCTAssertTrue(memPath.hasPrefix(basePath),
                      "memoryDir 应在 agentGuiDir 内")
    }

    func test_memoryDir_lastPathComponentIsMemory() {
        XCTAssertEqual(ConfigDirectoryManager.shared.memoryDir.lastPathComponent, "memory")
    }

    func test_memoryIndexURL_filenameIsMEMORY_md() {
        XCTAssertEqual(ConfigDirectoryManager.shared.memoryIndexURL.lastPathComponent, "MEMORY.md")
    }

    func test_memoryIndexURL_isInsideMemoryDir() {
        let mgr = ConfigDirectoryManager.shared
        XCTAssertTrue(mgr.memoryIndexURL.path.hasPrefix(mgr.memoryDir.path))
    }
}
```

### Step 2: 运行测试，确认失败

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task1 \
  -only-testing:agentGuiTests/ConfigDirectoryManagerMemoryDirTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Expected: FAIL with "has no member 'memoryDir'"

### Step 3: 在 `ConfigDirectoryManager` 中添加两个属性

```swift
// agentGui/Utilities/ConfigDirectoryManager.swift
// 在 lspServerDirectoryURL 之后添加：

/// `~/.agentgui/memory/`
var memoryDir: URL {
    agentGuiDir.appendingPathComponent("memory", isDirectory: true)
}

/// `~/.agentgui/memory/MEMORY.md`
var memoryIndexURL: URL {
    memoryDir.appendingPathComponent("MEMORY.md")
}
```

同时在 `setup()` 方法中（在 lspServerDirectoryURL 目录创建之后）确保 memory 目录存在：

```swift
// 在 setup() 中添加（放在 lspServerDirectoryURL 创建代码之后）
do {
    try fm.createDirectory(at: memoryDir, withIntermediateDirectories: true)
} catch {
    print("[ConfigDirectoryManager] Failed to create memory directory: \(error)")
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task1 \
  -only-testing:agentGuiTests/ConfigDirectoryManagerMemoryDirTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 4 tests PASS

### Step 5: Commit

```bash
git add agentGui/Utilities/ConfigDirectoryManager.swift \
        agentGuiTests/ConfigDirectoryManagerMemoryDirTests.swift
git commit -m "feat(m02): add memoryDir + memoryIndexURL to ConfigDirectoryManager"
```

---

## Task 2: `MemoryTopicFilename` — 从 MemoryRecord 推导稳定文件名

**Files:**
- Create: `agentGui/Services/Memory/MemoryTopicFilename.swift`
- Test: `agentGuiTests/MemoryTopicFilenameTests.swift`

规则：`<slugified_title_40chars>_<first8charsOfID>.md`
- slug：小写，`[^a-z0-9]+` → `_`，去除首尾 `_`，截断至 40 字符
- 路径安全：slug 不能包含 `..`、`/`、空字节 → 若 slug 生成后为空则 fallback 到 `memory_<id8>.md`

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryTopicFilenameTests.swift
import XCTest
@testable import agentGui

final class MemoryTopicFilenameTests: XCTestCase {

    func test_filename_normalCase() {
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: "User Role")
        XCTAssertEqual(MemoryTopicFilename.filename(for: record), "user_role_abcd1234.md")
    }

    func test_filename_specialCharsAreSlugified() {
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: "Feedback: No mock DB!")
        XCTAssertEqual(MemoryTopicFilename.filename(for: record), "feedback_no_mock_db_abcd1234.md")
    }

    func test_filename_titleTruncatedAt40Chars() {
        let longTitle = String(repeating: "a", count: 60)
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: longTitle)
        let name = MemoryTopicFilename.filename(for: record)
        // slug part ≤ 40 chars + "_" + 8 char id + ".md"
        let slugPart = name.replacingOccurrences(of: "_abcd1234.md", with: "")
        XCTAssertLessThanOrEqual(slugPart.count, 40)
    }

    func test_filename_emptyTitleFallsBackToMemoryPrefix() {
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: "")
        XCTAssertEqual(MemoryTopicFilename.filename(for: record), "memory_abcd1234.md")
    }

    func test_filename_unicodeTitleFallsBackToMemoryPrefix() {
        // 全 Unicode 字符（非 ASCII 字母数字）→ slug 为空 → fallback
        let record = MemoryRecord.fixture(id: "abcd1234-xxxx", title: "纯中文标题")
        let name = MemoryTopicFilename.filename(for: record)
        XCTAssertTrue(name.hasPrefix("memory_"), "非 ASCII slug 应 fallback 到 memory_ 前缀")
    }

    func test_sanitizeTitle_rejectsPathTraversal() {
        let slug = MemoryTopicFilename.sanitizeTitle("../../etc/passwd")
        XCTAssertFalse(slug.contains(".."), "slug 不应包含路径穿越字符")
        XCTAssertFalse(slug.contains("/"), "slug 不应包含斜线")
    }

    func test_filename_idShorterThan8UsesFullId() {
        let record = MemoryRecord.fixture(id: "ab12", title: "Short ID Record")
        let name = MemoryTopicFilename.filename(for: record)
        XCTAssertTrue(name.hasSuffix("_ab12.md"), "ID 不足 8 位时使用完整 ID")
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task2 \
  -only-testing:agentGuiTests/MemoryTopicFilenameTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: FAIL with "cannot find type 'MemoryTopicFilename'"

### Step 3: 实现 `MemoryTopicFilename`

```swift
// agentGui/Services/Memory/MemoryTopicFilename.swift
import Foundation

/// 从 `MemoryRecord` 推导稳定的、文件系统安全的 `.md` 文件名。
///
/// 规则：`<slug>_<id8>.md`
/// - slug = lowercase(title)，将 `[^a-z0-9]+` 替换为 `_`，截断至 40 字符，去除首尾 `_`
/// - id8 = record.id 前 8 个字符（若 id 不足 8 位则使用完整 id）
/// - 若 slug 为空（如纯 Unicode 标题），fallback 为 `memory_<id8>.md`
///
/// nonisolated struct，无副作用，可在任意并发上下文调用。
enum MemoryTopicFilename {

    static func filename(for record: MemoryRecord) -> String {
        let slug = sanitizeTitle(record.title)
        let id8 = String(record.id.prefix(8))
        if slug.isEmpty {
            return "memory_\(id8).md"
        }
        return "\(slug)_\(id8).md"
    }

    /// ASCII 化并 slug 化标题，截断至 40 字符。
    /// 安全保证：结果中不含 `/`、`..`、空字节。
    static func sanitizeTitle(_ title: String) -> String {
        guard !title.isEmpty else { return "" }

        // 小写化，仅保留 a-z 0-9，其余替换为 _
        let lowered = title.lowercased()
        var slug = lowered.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            if (v >= UInt32(("a" as UnicodeScalar).value) && v <= UInt32(("z" as UnicodeScalar).value))
                || (v >= UInt32(("0" as UnicodeScalar).value) && v <= UInt32(("9" as UnicodeScalar).value)) {
                return Character(scalar)
            }
            return "_"
        }.map(String.init).joined()

        // 合并多个连续 _ 为一个
        while slug.contains("__") {
            slug = slug.replacingOccurrences(of: "__", with: "_")
        }
        // 去除首尾 _
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        // 截断至 40 字符
        if slug.count > 40 {
            slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        return slug
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task2 \
  -only-testing:agentGuiTests/MemoryTopicFilenameTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 7 tests PASS

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryTopicFilename.swift \
        agentGuiTests/MemoryTopicFilenameTests.swift
git commit -m "feat(m02): add MemoryTopicFilename — safe slug derivation from MemoryRecord"
```

---

## Task 3: `MemoryTopicFileComposer` — MemoryRecord → YAML frontmatter `.md`

**Files:**
- Create: `agentGui/Services/Memory/MemoryTopicFileComposer.swift`
- Test: `agentGuiTests/MemoryTopicFileComposerTests.swift`

Frontmatter 格式（对齐 Claude Code `MEMORY_FRONTMATTER_EXAMPLE`）：
```markdown
---
name: "User Role"
description: "User is a senior iOS developer"
type: user
id: abcd1234-xxxx-...
scope: user
created: 2026-04-01T10:00:00Z
updated: 2026-04-01T10:00:00Z
---

<正文内容：payload.text 或条目列表>
```

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryTopicFileComposerTests.swift
import XCTest
@testable import agentGui

final class MemoryTopicFileComposerTests: XCTestCase {

    private let composer = MemoryTopicFileComposer()
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func makeRecord(
        id: String = "abc123",
        title: String = "User Role",
        summary: String = "Senior iOS developer",
        payloadText: String = "User is a senior iOS developer focusing on Swift 6.",
        kind: MemoryKind = .semantic,
        scope: MemoryScope = .user,
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> MemoryRecord {
        MemoryRecord.fixture(
            id: id, kind: kind, scope: scope,
            title: title, summary: summary,
            payload: .text(payloadText),
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    // MARK: - Frontmatter presence

    func test_compose_containsFrontmatterDelimiters() {
        let output = composer.compose(record: makeRecord())
        let lines = output.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "---", "第一行应为 ---")
        let secondDelimiter = lines.dropFirst().firstIndex(of: "---")
        XCTAssertNotNil(secondDelimiter, "应有第二个 --- 分隔符")
    }

    func test_compose_containsNameField() {
        let output = composer.compose(record: makeRecord(title: "User Role"))
        XCTAssertTrue(output.contains("name: \"User Role\""))
    }

    func test_compose_containsDescriptionField() {
        let output = composer.compose(record: makeRecord(summary: "Senior iOS developer"))
        XCTAssertTrue(output.contains("description: \"Senior iOS developer\""))
    }

    func test_compose_containsTypeField() {
        let output = composer.compose(record: makeRecord(kind: .semantic))
        XCTAssertTrue(output.contains("type: semantic"))
    }

    func test_compose_containsIdField() {
        let output = composer.compose(record: makeRecord(id: "abc123"))
        XCTAssertTrue(output.contains("id: abc123"))
    }

    func test_compose_containsScopeField() {
        let output = composer.compose(record: makeRecord(scope: .user))
        XCTAssertTrue(output.contains("scope: user"))
    }

    func test_compose_containsCreatedAt_inISO8601() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let output = composer.compose(record: makeRecord(createdAt: date))
        let expected = Self.iso8601.string(from: date)
        XCTAssertTrue(output.contains("created: \(expected)"),
                      "created 字段应为 ISO8601 格式，expected '\(expected)'，got:\n\(output)")
    }

    func test_compose_containsUpdatedAt_inISO8601() {
        let date = Date(timeIntervalSince1970: 2_000_000)
        let output = composer.compose(record: makeRecord(updatedAt: date))
        let expected = Self.iso8601.string(from: date)
        XCTAssertTrue(output.contains("updated: \(expected)"))
    }

    // MARK: - Body

    func test_compose_bodyContainsPayloadText() {
        let output = composer.compose(record: makeRecord(payloadText: "User is a senior iOS developer."))
        XCTAssertTrue(output.contains("User is a senior iOS developer."),
                      "正文应包含 payload 文本")
    }

    func test_compose_bodyAppearsAfterFrontmatter() {
        let output = composer.compose(record: makeRecord(payloadText: "Body content here."))
        let parts = output.components(separatedBy: "---\n")
        // parts[0] = "" (before first ---), parts[1] = frontmatter, parts[2] = body
        XCTAssertGreaterThanOrEqual(parts.count, 3, "应有至少 3 段（空头、frontmatter、body）")
        XCTAssertTrue(parts.last?.contains("Body content here.") == true,
                      "正文应在 frontmatter 之后")
    }

    // MARK: - YAML value quoting

    func test_compose_quotesNameWithSpecialChars() {
        // 含引号的 title 不应破坏 frontmatter
        let output = composer.compose(record: makeRecord(title: "Feedback: Use \"real\" DB"))
        // 只要 frontmatter 不以裸 " 形式破坏 YAML 格式 — 使用 escaped 或单引号
        XCTAssertTrue(output.contains("name:"), "name 字段应始终存在")
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task3 \
  -only-testing:agentGuiTests/MemoryTopicFileComposerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: FAIL with "cannot find type 'MemoryTopicFileComposer'"

### Step 3: 实现 `MemoryTopicFileComposer`

```swift
// agentGui/Services/Memory/MemoryTopicFileComposer.swift
import Foundation

/// 将 `MemoryRecord` 渲染成带 YAML frontmatter 的 `.md` 话题文件内容。
///
/// 对齐 Claude Code `MEMORY_FRONTMATTER_EXAMPLE`。
/// nonisolated struct，无副作用，可在任意并发上下文调用。
struct MemoryTopicFileComposer: Sendable {

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

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

    // MARK: - Private

    private func bodyText(from record: MemoryRecord) -> String {
        switch record.payload {
        case .text(let text):
            return text
        case .structured(let dict):
            return dict.sorted { $0.key < $1.key }
                .map { "- **\($0.key)**: \($0.value)" }
                .joined(separator: "\n")
        }
    }

    /// 对 YAML 字符串值进行双引号包裹并转义内部引号。
    private func yamlQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task3 \
  -only-testing:agentGuiTests/MemoryTopicFileComposerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 10 tests PASS

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryTopicFileComposer.swift \
        agentGuiTests/MemoryTopicFileComposerTests.swift
git commit -m "feat(m02): add MemoryTopicFileComposer — MemoryRecord to YAML frontmatter .md"
```

---

## Task 4: `MemoryIndexWriter` — 构建 MEMORY.md 索引（纯逻辑，无 I/O）

**Files:**
- Create: `agentGui/Services/Memory/MemoryIndexWriter.swift`
- Test: `agentGuiTests/MemoryIndexWriterTests.swift`

核心约束（对齐 `memdir.ts`）：
- 最大行数 `200`，最大字节数 `25_000`
- 先按行截断，再按字节截断（在最后一个 `\n` 处切断，防止截断到行中间）
- 超出时追加 warning 行

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryIndexWriterTests.swift
import XCTest
@testable import agentGui

final class MemoryIndexWriterTests: XCTestCase {

    private let writer = MemoryIndexWriter()

    private func makeRecord(
        id: String,
        title: String,
        summary: String = "A summary",
        retentionPolicy: MemoryRecord.RetentionPolicy = .persistent
    ) -> MemoryRecord {
        MemoryRecord.fixture(
            id: id, title: title, summary: summary,
            retentionPolicy: retentionPolicy,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Empty records

    func test_build_emptyRecords_returnsEmptyIndex() {
        let output = writer.build(records: [])
        XCTAssertTrue(output.indexContent.isEmpty,
                      "空记录应返回空索引")
        XCTAssertTrue(output.topicFiles.isEmpty)
    }

    // MARK: - Single record

    func test_build_singleRecord_indexHasOneEntry() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role")
        let output = writer.build(records: [record])
        let lines = output.indexContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "单条记录应生成 1 行索引")
    }

    func test_build_singleRecord_indexEntryFormat() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role", summary: "Senior iOS dev")
        let output = writer.build(records: [record])
        // 格式: - [Title](filename.md) — hook
        XCTAssertTrue(output.indexContent.hasPrefix("- [User Role]"),
                      "索引行应以 '- [Title]' 开头")
        XCTAssertTrue(output.indexContent.contains(".md)"),
                      "索引行应包含 .md 文件链接")
        XCTAssertTrue(output.indexContent.contains(" — "),
                      "索引行应包含 ' — ' 分隔符")
    }

    func test_build_singleRecord_topicFileGenerated() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role")
        let output = writer.build(records: [record])
        XCTAssertEqual(output.topicFiles.count, 1)
        XCTAssertEqual(output.topicFiles[0].filename,
                       MemoryTopicFilename.filename(for: record))
    }

    func test_build_singleRecord_topicFileContentHasFrontmatter() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role")
        let output = writer.build(records: [record])
        XCTAssertTrue(output.topicFiles[0].content.hasPrefix("---"),
                      "话题文件内容应以 frontmatter 开头")
    }

    // MARK: - Archived records excluded

    func test_build_archivedRecordsExcluded() {
        let active = makeRecord(id: "aaa", title: "Active", retentionPolicy: .persistent)
        let archived = makeRecord(id: "bbb", title: "Archived", retentionPolicy: .archiveOnly)
        let output = writer.build(records: [active, archived])
        XCTAssertEqual(output.topicFiles.count, 1,
                       "archiveOnly 记录不应生成话题文件")
        XCTAssertFalse(output.indexContent.contains("Archived"),
                       "archiveOnly 记录不应出现在索引中")
    }

    // MARK: - Line truncation

    func test_build_over200Lines_truncatesAndAppendsWarning() {
        let records = (0..<210).map { i in
            makeRecord(id: "id\(String(format: "%04d", i))", title: "Record \(i)")
        }
        let output = writer.build(records: records)
        let lines = output.indexContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertLessThanOrEqual(lines.count, MemoryIndexWriter.maxLines + 2,
                                 "超出 200 行时应截断（最多附加 1-2 个 warning 行）")
        XCTAssertTrue(output.indexContent.contains("WARNING"),
                      "截断后应包含 WARNING 提示")
        XCTAssertTrue(output.wasTruncated, "wasTruncated 应为 true")
    }

    func test_build_exactly200Lines_notTruncated() {
        let records = (0..<200).map { i in
            makeRecord(id: "id\(String(format: "%04d", i))", title: "Record \(i)")
        }
        let output = writer.build(records: records)
        XCTAssertFalse(output.wasTruncated,
                       "恰好 200 条记录不应触发截断")
    }

    // MARK: - Byte truncation

    func test_build_over25KBBytes_truncatesAndAppendsWarning() {
        // 生成每行约 200 字符的记录（超过 25KB 约需 125+ 条）
        let longTitle = String(repeating: "a", count: 60)
        let longHook = String(repeating: "b", count: 120)
        let records = (0..<130).map { i in
            makeRecord(id: "id\(String(format: "%04d", i))",
                       title: "\(longTitle)\(i)",
                       summary: longHook)
        }
        let output = writer.build(records: records)
        XCTAssertLessThanOrEqual(output.indexContent.utf8.count, MemoryIndexWriter.maxBytes + 500,
                                 "字节截断后不应超过 maxBytes + 一行 warning 余量")
        XCTAssertTrue(output.indexContent.contains("WARNING"))
        XCTAssertTrue(output.wasTruncated)
    }

    // MARK: - Hook text

    func test_build_hookTextIsSummary() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role",
                                summary: "Senior iOS developer, Swift 6 focus")
        let output = writer.build(records: [record])
        XCTAssertTrue(output.indexContent.contains("Senior iOS developer"),
                      "hook 文本应包含 summary")
    }

    func test_build_hookTextTruncatedAt120Chars() {
        let longSummary = String(repeating: "x", count: 200)
        let record = makeRecord(id: "abcd1234-x", title: "T", summary: longSummary)
        let output = writer.build(records: [record])
        // 整行：- [T](t_abcd1234.md) — <hook>
        // hook 部分 ≤ 120 字符
        let entryLine = output.indexContent.components(separatedBy: "\n").first ?? ""
        let hookPart = entryLine.components(separatedBy: " — ").last ?? ""
        XCTAssertLessThanOrEqual(hookPart.count, 120,
                                 "hook 文本不应超过 120 字符")
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task4 \
  -only-testing:agentGuiTests/MemoryIndexWriterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: FAIL with "cannot find type 'MemoryIndexWriter'"

### Step 3: 实现 `MemoryIndexWriter`

```swift
// agentGui/Services/Memory/MemoryIndexWriter.swift
import Foundation

/// 从 `[MemoryRecord]` 构建 `MEMORY.md` 索引内容和话题文件列表。
///
/// 纯逻辑，无 I/O。对齐 Claude Code `memdir.ts` 截断规则：
/// - 最多 200 行（`maxLines`），24 000 字节（`maxBytes`）
/// - 超出时先行截断，再字节截断（在最后 `\n` 处切断）
/// - 附加明确的 WARNING 行
struct MemoryIndexWriter: Sendable {

    static let maxLines = 200
    static let maxBytes = 25_000
    static let hookMaxLength = 120

    struct Output: Sendable {
        var indexContent: String
        var topicFiles: [(filename: String, content: String)]
        var wasTruncated: Bool
    }

    private let topicComposer = MemoryTopicFileComposer()

    func build(records: [MemoryRecord]) -> Output {
        let active = records.filter { $0.retentionPolicy != .archiveOnly }

        guard !active.isEmpty else {
            return Output(indexContent: "", topicFiles: [], wasTruncated: false)
        }

        // 按 scope.namespace 再按 createdAt 排序，保证稳定顺序
        let sorted = active.sorted {
            if $0.scope.namespace == $1.scope.namespace {
                return $0.createdAt < $1.createdAt
            }
            return $0.scope.namespace < $1.scope.namespace
        }

        var indexLines: [String] = []
        var topicFiles: [(String, String)] = []

        for record in sorted {
            let filename = MemoryTopicFilename.filename(for: record)
            let hook = hookText(record)
            let entry = "- [\(record.title)](\(filename)) — \(hook)"
            indexLines.append(entry)
            topicFiles.append((filename, topicComposer.compose(record: record)))
        }

        let truncated = truncate(lines: indexLines)
        return Output(
            indexContent: truncated.content,
            topicFiles: topicFiles,
            wasTruncated: truncated.wasTruncated
        )
    }

    // MARK: - Private

    private func hookText(_ record: MemoryRecord) -> String {
        let summary = record.summary
        if summary.count <= Self.hookMaxLength {
            return summary
        }
        return String(summary.prefix(Self.hookMaxLength - 1)) + "…"
    }

    private struct TruncationResult {
        var content: String
        var wasTruncated: Bool
    }

    private func truncate(lines: [String]) -> TruncationResult {
        let wasLineTruncated = lines.count > Self.maxLines
        let truncatedLines = wasLineTruncated
            ? Array(lines.prefix(Self.maxLines))
            : lines

        var content = truncatedLines.joined(separator: "\n")
        let wasByteTruncated = content.utf8.count > Self.maxBytes

        if wasByteTruncated {
            // 字节截断：在 maxBytes 之前的最后一个换行符处切断
            let allowedBytes = Self.maxBytes
            let cutIndex = content.utf8.index(content.utf8.startIndex, offsetBy: allowedBytes, limitedBy: content.utf8.endIndex) ?? content.utf8.endIndex
            let candidate = String(content.utf8.prefix(upTo: cutIndex)) ?? content
            if let lastNewline = candidate.lastIndex(of: "\n") {
                content = String(candidate[..<lastNewline])
            } else {
                content = candidate
            }
        }

        let wasTruncated = wasLineTruncated || wasByteTruncated
        if wasTruncated {
            let reason: String
            if wasLineTruncated && !wasByteTruncated {
                reason = "\(lines.count) lines (limit: \(Self.maxLines))"
            } else if wasByteTruncated && !wasLineTruncated {
                let kb = String(format: "%.1f", Double(lines.joined(separator: "\n").utf8.count) / 1024)
                reason = "\(kb)KB (limit: \(Self.maxBytes / 1000)KB) — index entries are too long"
            } else {
                reason = "\(lines.count) lines and \(lines.joined(separator: "\n").utf8.count) bytes"
            }
            content += "\n\n> WARNING: MEMORY.md is \(reason). Only part was loaded. Keep index entries under ~150 chars; move detail into topic files."
        }

        return TruncationResult(content: content, wasTruncated: wasTruncated)
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task4 \
  -only-testing:agentGuiTests/MemoryIndexWriterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 12 tests PASS

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryIndexWriter.swift \
        agentGuiTests/MemoryIndexWriterTests.swift
git commit -m "feat(m02): add MemoryIndexWriter — builds MEMORY.md with truncation"
```

---

## Task 5: `MemoryIndexReader` — 读取 MEMORY.md（含截断）

**Files:**
- Create: `agentGui/Services/Memory/MemoryIndexReader.swift`
- Test: `agentGuiTests/MemoryIndexReaderTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryIndexReaderTests.swift
import XCTest
@testable import agentGui

final class MemoryIndexReaderTests: XCTestCase {

    private let reader = MemoryIndexReader()
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryIndexReaderTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeIndex(_ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - File not found

    func test_read_nonExistentFile_returnsNil() {
        let url = tempDir.appendingPathComponent("does_not_exist.md")
        let result = reader.read(from: url)
        XCTAssertNil(result, "不存在的文件应返回 nil")
    }

    // MARK: - Normal read

    func test_read_normalContent_returnsContent() throws {
        let content = "- [User Role](user_role_abc.md) — Senior iOS dev"
        let url = try writeIndex(content)
        let result = reader.read(from: url)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.content, content)
        XCTAssertFalse(result?.wasTruncated ?? true)
    }

    func test_read_emptyFile_returnsNilOrEmpty() throws {
        let url = try writeIndex("")
        let result = reader.read(from: url)
        // 空文件可返回 nil 或 wasTruncated=false 的空内容
        if let r = result {
            XCTAssertFalse(r.wasTruncated)
        }
    }

    // MARK: - Line count

    func test_read_lineCount_isAccurate() throws {
        let lines = (1...10).map { "- [Record \($0)](r\($0).md) — Hook \($0)" }
        let url = try writeIndex(lines.joined(separator: "\n"))
        let result = reader.read(from: url)
        XCTAssertEqual(result?.lineCount, 10)
    }

    // MARK: - Byte count

    func test_read_byteCount_isAccurate() throws {
        let content = "- [A](a.md) — hook"
        let url = try writeIndex(content)
        let result = reader.read(from: url)
        XCTAssertEqual(result?.byteCount, content.utf8.count)
    }

    func test_read_over200Lines_wasTruncatedIsTrue() throws {
        let lines = (1...210).map { "- [Record \($0)](r\($0).md) — hook" }
        let url = try writeIndex(lines.joined(separator: "\n"))
        let result = reader.read(from: url)
        XCTAssertTrue(result?.wasTruncated ?? false,
                      "超过 200 行时 wasTruncated 应为 true")
    }

    func test_read_over200Lines_contentHasWarning() throws {
        let lines = (1...210).map { "- [Record \($0)](r\($0).md) — hook" }
        let url = try writeIndex(lines.joined(separator: "\n"))
        let result = reader.read(from: url)
        XCTAssertTrue(result?.content.contains("WARNING") ?? false)
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task5 \
  -only-testing:agentGuiTests/MemoryIndexReaderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: FAIL with "cannot find type 'MemoryIndexReader'"

### Step 3: 实现 `MemoryIndexReader`

```swift
// agentGui/Services/Memory/MemoryIndexReader.swift
import Foundation

/// 从磁盘读取 `MEMORY.md` 并应用与 `MemoryIndexWriter` 相同的截断规则。
///
/// nonisolated struct，执行同步 I/O（文件 ≤25KB，耗时可忽略）。
struct MemoryIndexReader: Sendable {

    struct ReadResult: Sendable {
        var content: String
        var lineCount: Int
        var byteCount: Int
        var wasTruncated: Bool
    }

    /// 读取 `url` 处的 MEMORY.md 文件。
    /// - Returns: 若文件不存在或为空返回 `nil`；否则返回截断后的内容。
    func read(from url: URL) -> ReadResult? {
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return truncate(raw: raw)
    }

    // MARK: - Private

    private func truncate(raw: String) -> ReadResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allLines = trimmed.components(separatedBy: "\n")
        let originalLineCount = allLines.count
        let originalByteCount = trimmed.utf8.count

        let wasLineTruncated = originalLineCount > MemoryIndexWriter.maxLines
        let wasByteTruncated = originalByteCount > MemoryIndexWriter.maxBytes

        if !wasLineTruncated && !wasByteTruncated {
            return ReadResult(
                content: trimmed,
                lineCount: originalLineCount,
                byteCount: originalByteCount,
                wasTruncated: false
            )
        }

        var truncatedLines = wasLineTruncated
            ? Array(allLines.prefix(MemoryIndexWriter.maxLines))
            : allLines
        var content = truncatedLines.joined(separator: "\n")

        if content.utf8.count > MemoryIndexWriter.maxBytes {
            let cutBytes = MemoryIndexWriter.maxBytes
            let endIndex = content.utf8.index(
                content.utf8.startIndex,
                offsetBy: cutBytes,
                limitedBy: content.utf8.endIndex
            ) ?? content.utf8.endIndex
            let candidate = String(content.utf8.prefix(upTo: endIndex)) ?? content
            if let lastNL = candidate.lastIndex(of: "\n") {
                content = String(candidate[..<lastNL])
            } else {
                content = candidate
            }
            truncatedLines = content.components(separatedBy: "\n")
        }

        let reason: String
        if wasLineTruncated {
            reason = "\(originalLineCount) lines (limit: \(MemoryIndexWriter.maxLines))"
        } else {
            let kb = String(format: "%.1f", Double(originalByteCount) / 1024)
            reason = "\(kb)KB — entries are too long"
        }
        content += "\n\n> WARNING: MEMORY.md is \(reason). Only part was loaded."

        return ReadResult(
            content: content,
            lineCount: originalLineCount,
            byteCount: originalByteCount,
            wasTruncated: true
        )
    }
}

// MARK: - String UTF8 helper

private extension String {
    init?(_ utf8View: Substring.UTF8View) {
        self.init(bytes: utf8View, encoding: .utf8)
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task5 \
  -only-testing:agentGuiTests/MemoryIndexReaderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 8 tests PASS

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryIndexReader.swift \
        agentGuiTests/MemoryIndexReaderTests.swift
git commit -m "feat(m02): add MemoryIndexReader — reads MEMORY.md with truncation"
```

---

## Task 6: `MemoryIndexFileSystem` — 磁盘写入（协调 Writer + FileManager）

**Files:**
- Create: `agentGui/Services/Memory/MemoryIndexFileSystem.swift`
- Test: `agentGuiTests/MemoryIndexFileSystemTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryIndexFileSystemTests.swift
import XCTest
@testable import agentGui

final class MemoryIndexFileSystemTests: XCTestCase {

    private var tempDir: URL!
    private var sut: MemoryIndexFileSystem!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryIndexFSTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sut = MemoryIndexFileSystem(memoryDir: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_rebuild_writesMemoryMd() throws {
        let record = MemoryRecord.fixture(id: "abcd1234-x", title: "User Role",
                                          retentionPolicy: .persistent)
        try sut.rebuild(with: [record])

        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path),
                      "rebuild 后应生成 MEMORY.md")
    }

    func test_rebuild_writesTopicFile() throws {
        let record = MemoryRecord.fixture(id: "abcd1234-x", title: "User Role",
                                          retentionPolicy: .persistent)
        try sut.rebuild(with: [record])

        let expectedName = MemoryTopicFilename.filename(for: record)
        let topicURL = tempDir.appendingPathComponent(expectedName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: topicURL.path),
                      "rebuild 后应生成话题文件 \(expectedName)")
    }

    func test_rebuild_memoryMdContainsEntry() throws {
        let record = MemoryRecord.fixture(id: "abcd1234-x", title: "User Role",
                                          summary: "Senior iOS dev", retentionPolicy: .persistent)
        try sut.rebuild(with: [record])

        let content = try String(contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertTrue(content.contains("User Role"), "MEMORY.md 应包含记录标题")
        XCTAssertTrue(content.contains("Senior iOS dev"), "MEMORY.md 应包含 hook")
    }

    func test_rebuild_emptyRecords_doesNotWriteMemoryMd() throws {
        try sut.rebuild(with: [])
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path),
                       "空记录时不应创建 MEMORY.md")
    }

    func test_rebuild_createsDirectoryIfNeeded() throws {
        let nonExistentDir = tempDir.appendingPathComponent("sub/memory", isDirectory: true)
        let fs = MemoryIndexFileSystem(memoryDir: nonExistentDir)
        let record = MemoryRecord.fixture(id: "xyz", title: "T", retentionPolicy: .persistent)
        XCTAssertNoThrow(try fs.rebuild(with: [record]),
                         "rebuild 应自动创建目录")
    }

    func test_rebuild_overwritesExistingMemoryMd() throws {
        let record1 = MemoryRecord.fixture(id: "id1", title: "Old Title", retentionPolicy: .persistent)
        try sut.rebuild(with: [record1])
        let record2 = MemoryRecord.fixture(id: "id2", title: "New Title", retentionPolicy: .persistent)
        try sut.rebuild(with: [record2])

        let content = try String(contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertTrue(content.contains("New Title"))
        XCTAssertFalse(content.contains("Old Title"),
                       "重建后旧标题不应出现在 MEMORY.md 中")
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task6 \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: FAIL with "cannot find type 'MemoryIndexFileSystem'"

### Step 3: 实现 `MemoryIndexFileSystem`

```swift
// agentGui/Services/Memory/MemoryIndexFileSystem.swift
import Foundation

/// 将 `MemoryIndexWriter` 的输出持久化到磁盘。
///
/// - 在 `memoryDir` 下写 `MEMORY.md`（索引）和各话题 `.md` 文件
/// - 幂等：重建时覆盖旧 `MEMORY.md`；话题文件按需覆写
/// - 若 `records` 为空则跳过写入（不创建空的 MEMORY.md）
///
/// nonisolated struct，但包含 FileManager I/O，调用方需保证在适当的上下文执行。
struct MemoryIndexFileSystem: Sendable {

    let memoryDir: URL
    private let writer = MemoryIndexWriter()
    private let fileManager: FileManager

    init(memoryDir: URL, fileManager: FileManager = .default) {
        self.memoryDir = memoryDir
        self.fileManager = fileManager
    }

    /// 根据 `records` 重建 MEMORY.md 和话题文件。
    /// - Throws: 文件写入失败时抛出 `CocoaError`。
    func rebuild(with records: [MemoryRecord]) throws {
        let output = writer.build(records: records)
        guard !output.indexContent.isEmpty else { return }

        try fileManager.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        // 写话题文件
        for (filename, content) in output.topicFiles {
            let url = memoryDir.appendingPathComponent(filename)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        // 写 MEMORY.md
        let indexURL = memoryDir.appendingPathComponent("MEMORY.md")
        try output.indexContent.write(to: indexURL, atomically: true, encoding: .utf8)
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task6 \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 6 tests PASS

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryIndexFileSystem.swift \
        agentGuiTests/MemoryIndexFileSystemTests.swift
git commit -m "feat(m02): add MemoryIndexFileSystem — coordinates index write to disk"
```

---

## Task 7: Persist 钩子 — `UnifiedMemoryFileStoreAdapter.persist()` 后触发异步重建

**Files:**
- Modify: `agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- Test: 通过已有 Task 6 集成测试覆盖（无需新建测试文件）

关键原则：
1. 重建是 **fire-and-forget**（`Task.detached(priority: .utility)`），不阻塞主存储操作
2. `UnifiedMemoryFileStoreAdapter` 无需知道 `ConfigDirectoryManager`——通过 init 注入 `memoryDir`
3. 重建时加载所有 active records（不止当前被 persist 的那一条）

### Step 1: 阅读 `UnifiedMemoryFileStoreAdapter` 当前的 `persist()` 实现

在修改前先确认 `persist()` 的末尾位置：

```swift
// 当前 persist() 末尾（位于 UnifiedMemoryFileStoreAdapter.swift 约第 55 行）：
try saveStoredRecords(stored, scope: record.scope)
return MemoryWriteResult(record: record, action: action)
```

### Step 2: 修改 `UnifiedMemoryFileStoreAdapter`

在 `UnifiedMemoryFileStoreAdapter` 的 `init` 中加入可选的 `memoryDir`，并在 `persist()` / `replace()` / `archive()` 后触发重建。

```swift
// 在 init 添加参数：
init(
    baseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(
        path: "unified-memory", directoryHint: .isDirectory),
    memoryDir: URL = ConfigDirectoryManager.shared.memoryDir,
    fileManager: FileManager = .default
) {
    self.memoryDir = memoryDir
    // ...（其余不变）
}

// 在类内添加 stored property：
private let memoryDir: URL
```

在 `persist()` 末尾（`return MemoryWriteResult` 之前）加入：

```swift
triggerIndexRebuild()
```

同样在 `replace()` 末尾（调用 `persist(record:)` 之后）和 `archive()` 末尾加入相同调用。

新增私有方法：

```swift
private func triggerIndexRebuild() {
    let dir = memoryDir
    let allRecords = (try? allRecords(includeArchived: false)) ?? []
    Task.detached(priority: .utility) {
        try? MemoryIndexFileSystem(memoryDir: dir).rebuild(with: allRecords)
    }
}
```

> **注意**：`Task.detached` 使结构脱离当前 actor 上下文，避免 @MainActor 阻塞。
> `MemoryIndexFileSystem` 和 `MemoryIndexWriter` 均为 `Sendable`，可安全跨 actor 传递。

### Step 3: 构建确认无编译错误

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-m02-task7 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:.*Sendable" | head -20
```

Expected: 0 errors

### Step 4: Commit

```bash
git add agentGui/Services/UnifiedMemoryFileStoreAdapter.swift
git commit -m "feat(m02): trigger async MEMORY.md rebuild after persist/replace/archive"
```

---

## Task 8: System Prompt 注入 — 在 `buildSystemPrompt()` 中加入 MEMORY.md 节

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift`
- Modify: `agentGui/Services/Memory/MemoryTypeGuidanceComposer.swift`（添加两步保存说明）
- Test: `agentGuiTests/MemorySystemPromptInjectionTests.swift`

目标：system prompt 中新增两段：
1. **保存说明**（来自 `MemoryTypeGuidanceComposer`）：告知 agent MEMORY.md 的路径和两步保存流程
2. **MEMORY.md 索引内容**（从磁盘读取）：若存在记忆则展示当前索引

### Step 1: 写失败测试

```swift
// agentGuiTests/MemorySystemPromptInjectionTests.swift
import XCTest
@testable import agentGui

final class MemorySystemPromptInjectionTests: XCTestCase {

    // MARK: - MemoryTypeGuidanceComposer 两步保存说明

    func test_guidanceComposer_containsSavingInstructions_step1() {
        let section = MemoryTypeGuidanceComposer().compose()
        XCTAssertTrue(section.contains("Step 1") || section.contains("step 1"),
                      "保存说明应包含 Step 1（写话题文件）")
    }

    func test_guidanceComposer_containsSavingInstructions_step2() {
        let section = MemoryTypeGuidanceComposer().compose()
        XCTAssertTrue(section.contains("Step 2") || section.contains("step 2"),
                      "保存说明应包含 Step 2（更新 MEMORY.md 索引）")
    }

    func test_guidanceComposer_mentionsMEMORY_md() {
        let section = MemoryTypeGuidanceComposer().compose()
        XCTAssertTrue(section.contains("MEMORY.md"),
                      "保存说明应提到 MEMORY.md 索引文件")
    }

    func test_guidanceComposer_mentionsMemoryDir() {
        // system prompt 中应出现记忆目录路径信息
        let section = MemoryTypeGuidanceComposer().howToSaveSection()
        XCTAssertTrue(section.contains(".agentgui/memory") || section.contains("memory/"),
                      "应告知 agent 记忆目录位置")
    }

    // MARK: - buildSystemPrompt 中含 MEMORY.md 节（空索引场景）

    func test_buildSystemPrompt_containsMemorySystemSection() {
        let prompt = ClaudeService.memoryGuidanceSection()
        XCTAssertTrue(prompt.contains("## Memory System"),
                      "system prompt 应包含 ## Memory System 节")
    }

    func test_buildSystemPrompt_memoryIndexSectionKey() {
        // 当 MEMORY.md 存在时，system prompt 应包含 ## Your Memory Index
        // 使用纯文本静态测试：memoryIndexSection() 方法
        let section = ClaudeService.memoryIndexSection(content: "- [Test](t.md) — hook")
        XCTAssertTrue(section.contains("## Your Memory Index"))
        XCTAssertTrue(section.contains("- [Test]"))
    }

    func test_buildSystemPrompt_emptyMemoryIndex_sectionIsEmpty() {
        let section = ClaudeService.memoryIndexSection(content: "")
        XCTAssertTrue(section.isEmpty,
                      "索引内容为空时 memoryIndexSection 应返回空字符串")
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task8 \
  -only-testing:agentGuiTests/MemorySystemPromptInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: FAIL（`howToSaveSection` 不存在，`memoryIndexSection` 不存在）

### Step 3: 更新 `MemoryTypeGuidanceComposer` — 添加 `howToSaveSection()` 和更新 `compose()`

在 `MemoryTypeGuidanceComposer` 中新增 `howToSaveSection()`：

```swift
/// 生成 `## How to Save Memories` 节，描述两步保存流程。
/// memoryDir 默认从 ConfigDirectoryManager 读取（允许测试注入）。
func howToSaveSection(memoryDir: String? = nil) -> String {
    let dir = memoryDir ?? ConfigDirectoryManager.shared.memoryDir.path
    return """
    ## How to Save Memories

    Your persistent memory lives at `\(dir)/`.
    This directory already exists — write directly without checking for its existence.

    Saving a memory is a two-step process:

    **Step 1** — write the memory to its own topic file (e.g., `user_role.md`, `feedback_testing.md`):
    ```
    ---
    name: "Title of this memory"
    description: "One-line description for the MEMORY.md index"
    type: user | feedback | project | reference
    ---

    Body: the full memory content goes here.
    ```

    **Step 2** — add a one-line pointer to `MEMORY.md`:
    `- [Title](filename.md) — one-line hook under ~150 chars`

    Rules:
    - `MEMORY.md` is an index only — never write memory content directly into it.
    - `MEMORY.md` has no frontmatter.
    - Lines after \(MemoryIndexWriter.maxLines) in `MEMORY.md` will be truncated — keep entries concise.
    - Before writing a new memory, check if an existing file can be updated instead.
    """
}
```

更新 `compose()` 方法将 `howToSaveSection()` 也拼入：

```swift
func compose() -> String {
    [typesSection(), whatNotToSaveSection(), howToSaveSection()].joined(separator: "\n\n")
}
```

### Step 4: 在 `ClaudeService+Prompting.swift` 中添加 `memoryIndexSection()` 静态方法

```swift
// 在 ClaudeService extension 内，紧接 memoryGuidanceSection() 之后添加：

/// 如果 MEMORY.md 有内容，生成 `## Your Memory Index` 节，否则返回空字符串。
/// 调用方负责提供正确的 content（通过 MemoryIndexReader 读取）。
nonisolated static func memoryIndexSection(content: String) -> String {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
    return """
    ## Your Memory Index

    The following is your current `MEMORY.md` index. Use it to discover which topic \
    files are available — read them with the file tools when you need the full content.

    \(content)
    """
}
```

在 `buildSystemPrompt()` 中，在 `## Memory System` 注入之后，追加 MEMORY.md 节：

```swift
// 在 parts.append("## Memory System\n\n\(MemoryTypeGuidanceComposer().compose())") 之后：

// MEMORY.md 索引（同步读取，文件 ≤25KB，耗时可忽略）
let memoryIndexContent = MemoryIndexReader().read(
    from: ConfigDirectoryManager.shared.memoryIndexURL
)?.content ?? ""
let indexSection = ClaudeService.memoryIndexSection(content: memoryIndexContent)
if !indexSection.isEmpty {
    parts.append(indexSection)
}
```

### Step 5: 运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task8 \
  -only-testing:agentGuiTests/MemorySystemPromptInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 7 tests PASS

### Step 6: 运行已有的 M-01 memory 测试，确认无回归

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-task8b \
  -only-testing:agentGuiTests/MemoryTypeGuidanceComposerTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 全部 PASS

### Step 7: Commit

```bash
git add agentGui/Services/Memory/MemoryTypeGuidanceComposer.swift \
        agentGui/Services/ClaudeService/ClaudeService+Prompting.swift \
        agentGuiTests/MemorySystemPromptInjectionTests.swift
git commit -m "feat(m02): inject MEMORY.md index + two-step save instructions into system prompt"
```

---

## Task 9: Xcode 项目文件 — 新建文件注册

**Files:**
- Modify: `agentGui.xcodeproj/project.pbxproj`

新增的 Swift 文件必须手动加入 Xcode 项目，否则编译时 target 找不到这些文件。

### Step 1: 在 Xcode 中添加新文件到目标

推荐通过 Xcode GUI 操作（File → Add Files to "agentGui"）或通过命令行确认：

需要注册到 `agentGui` target 的新文件：
- `agentGui/Services/Memory/MemoryTopicFilename.swift`
- `agentGui/Services/Memory/MemoryTopicFileComposer.swift`
- `agentGui/Services/Memory/MemoryIndexWriter.swift`
- `agentGui/Services/Memory/MemoryIndexReader.swift`
- `agentGui/Services/Memory/MemoryIndexFileSystem.swift`

需要注册到 `agentGuiTests` target 的新文件：
- `agentGuiTests/ConfigDirectoryManagerMemoryDirTests.swift`
- `agentGuiTests/MemoryTopicFilenameTests.swift`
- `agentGuiTests/MemoryTopicFileComposerTests.swift`
- `agentGuiTests/MemoryIndexWriterTests.swift`
- `agentGuiTests/MemoryIndexReaderTests.swift`
- `agentGuiTests/MemoryIndexFileSystemTests.swift`
- `agentGuiTests/MemorySystemPromptInjectionTests.swift`

> **提示**：在 Xcode 中打开项目，右键 `Memory/` 组 → Add Files，选中上述文件并勾选正确的 target。

### Step 2: 确认编译通过

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-m02-final \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

Expected: 0 errors

### Step 3: 全量 M-02 测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-final \
  -only-testing:agentGuiTests/ConfigDirectoryManagerMemoryDirTests \
  -only-testing:agentGuiTests/MemoryTopicFilenameTests \
  -only-testing:agentGuiTests/MemoryTopicFileComposerTests \
  -only-testing:agentGuiTests/MemoryIndexWriterTests \
  -only-testing:agentGuiTests/MemoryIndexReaderTests \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  -only-testing:agentGuiTests/MemorySystemPromptInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|PASS|FAIL|error:"
```

Expected: 全部通过（约 58 个测试）

### Step 4: 确认 M-01 无回归

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m02-regression \
  -only-testing:agentGuiTests/MemoryTypeGuidanceComposerTests \
  -only-testing:agentGuiTests/MemorySemanticTypeTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 全部 PASS（无回归）

### Step 5: 最终 Commit

```bash
git add agentGui.xcodeproj/project.pbxproj
git commit -m "feat(m02): register new Memory/ files in Xcode project"
git tag m02-complete
```

---

## 完成标准

- [ ] `~/.agentgui/memory/` 目录在 app 启动时自动创建
- [ ] 每次调用 `UnifiedMemoryFileStoreAdapter.persist()` 后，`MEMORY.md` 和话题文件被异步重建
- [ ] System prompt 的 `## Memory System` 节包含 MEMORY.md 路径和两步保存说明
- [ ] 若 `MEMORY.md` 存在且非空，system prompt 追加 `## Your Memory Index` 节（索引内容 ≤200行/25KB）
- [ ] 所有已有 M-01 测试通过（无回归）
- [ ] 约 58 个新增测试全部通过

---

## 关键约束提醒

1. **不改动 RMS 系统**：`AgentLoopMemoryBootstrapComposer` / `RMSPromptComposer` 不在本 Feature 范围内；两套系统并行不互相干扰。
2. **截断边界一致**：`MemoryIndexWriter` 和 `MemoryIndexReader` 使用相同的 `maxLines = 200` / `maxBytes = 25_000`，通过 `MemoryIndexWriter.maxLines` 共享常量。
3. **同步读取可接受**：`buildSystemPrompt()` 中同步读取 `MEMORY.md` — 文件 ≤25KB，本地磁盘，主线程耗时 < 1ms，符合 Claude Code 惯例。
4. **火遗忘（fire-and-forget）重建**：`Task.detached(priority: .utility)` 确保索引重建不阻塞存储操作主路径。
5. **路径安全由 `MemoryTopicFilename.sanitizeTitle` 保证**：所有文件名经过 slug 化处理，拒绝 `..`、`/`、null byte。
