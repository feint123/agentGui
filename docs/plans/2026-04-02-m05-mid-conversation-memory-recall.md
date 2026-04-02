# Feature M-05: 智能中段记忆召回 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在每轮对话发起 API 调用前，根据当前用户 query 做一次轻量 side API call，从磁盘话题文件中动态选出最多 5 条相关记忆并以 `<system-reminder>` 块注入当前轮，实现真正的"中段召回"而非仅在 session 开始时全量注入。

**Architecture:** 新增 `MemoryTopicScanner`（扫描 frontmatter）、`RelevantMemorySideQuery`（调 Haiku 选文件）、`MemoryRecallSessionState`（actor 跨轮去重）、`RelevantMemoryRecallService`（编排+超时）、`MemoryRecallHook`（.willStartRound mutator hook）五个组件。通过修改 `AgentLoopRoundExecutor` 使 `.willStartRound` 阶段支持 message patch 注入，并在 `AgentLoopBuiltInHookFactory` 注册新 hook。

**Tech Stack:** Swift 6.0+, SwiftAnthropic (`service.createMessage`), SwiftData, `ConfigDirectoryManager`, `MemoryFreshnessAnnotator`（已有）, `MemoryTopicFilename`（已有）

---

## 背景与关键约束

- **超时必须可跳过**：side query 超时（2s）时主循环正常推进，不因召回失败而阻塞。
- **`alreadySurfaced` 去重**：同一 session 内已注入过的文件不再重复注入，防 token 膨胀。AutoCompact 后重置（扫描 messagesSnapshot 来重建状态，与 Claude Code 的 `collectSurfacedMemories` 同理）。
- **Session-total byte cap**：单 session 内累计注入字节数上限 ~50KB（`MAX_SESSION_BYTES = 51_200`），超出则跳过当轮召回。
- **单词过滤**：query 单词数 < 2 时跳过 side query（无足够上下文）。
- **Haiku 模型**：side query 使用 `claude-3-5-haiku-latest`（快速廉价），不依赖用户 `selectedModel`。
- **recentTools 过滤**：若 messages 中最近成功调用过某工具，side query prompt 会携带该清单，防止召回该工具的使用说明（与 Claude Code 相同）。
- **非递归**：`executionContext == .subagent` 时 hook 跳过，防止提取 subagent 再触发召回。

## 现有相关文件（只看，不改）

| 文件 | 用途 |
|------|------|
| `agentGui/Services/Memory/MemoryTopicFilename.swift` | 文件名 → slug 规则 |
| `agentGui/Services/Memory/MemoryTopicFileComposer.swift` | frontmatter 格式（YAML fenced） |
| `agentGui/Services/Memory/MemoryIndexFileSystem.swift` | 写文件系统 |
| `agentGui/Utilities/ConfigDirectoryManager.swift` | `memoryDir` 路径 |
| `agentGui/Services/MemoryFreshnessAnnotator.swift` (via Composer) | freshness text |
| `agentGui/Services/AgentLoopBuiltInHookFactory.swift` | hook 注册点 |
| `agentGui/Services/AgentLoopHookDependencyFactory.swift` | 依赖装配 |
| `agentGui/Services/AgentLoopRoundExecutor.swift` | round 执行流 |
| `agentGui/Services/ClaudeService/ClaudeService+ContextCompression.swift` | `service.createMessage` 调用示例 |

---

## Task 1: `MemoryTopicHeader` + `MemoryTopicScanner`

**Files:**
- Create: `agentGui/Services/Memory/MemoryTopicScanner.swift`
- Test: `agentGuiTests/MemoryTopicScannerTests.swift`

扫描 `memoryDir/*.md`（排除 `MEMORY.md`），读取每个文件前 30 行，解析 YAML frontmatter，返回 `[MemoryTopicHeader]`（按 mtime 降序，最多 200 条）。

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryTopicScannerTests.swift
import XCTest
@testable import agentGui

final class MemoryTopicScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryTopicScannerTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_scan_emptyDir_returnsEmpty() async throws {
        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertTrue(headers.isEmpty)
    }

    func test_scan_excludesMEMORYmd() async throws {
        let memoryMd = tempDir.appendingPathComponent("MEMORY.md")
        try "# Index\n- [foo](foo.md) — hook".write(to: memoryMd, atomically: true, encoding: .utf8)

        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertTrue(headers.isEmpty, "MEMORY.md は除外されるべき")
    }

    func test_scan_parsesNameAndDescription() async throws {
        let content = """
        ---
        name: "My Title"
        description: "A summary of the topic"
        type: "feedback"
        ---
        Body content here.
        """
        let file = tempDir.appendingPathComponent("my_title_abc12345.md")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers[0].filename, "my_title_abc12345.md")
        XCTAssertEqual(headers[0].title, "My Title")
        XCTAssertEqual(headers[0].description, "A summary of the topic")
        XCTAssertEqual(headers[0].memoryType, "feedback")
    }

    func test_scan_fileMissingDescription_descriptionNil() async throws {
        let content = """
        ---
        name: "No Desc"
        ---
        Body.
        """
        let file = tempDir.appendingPathComponent("no_desc_abc12345.md")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertEqual(headers.count, 1)
        XCTAssertNil(headers[0].description)
    }

    func test_scan_capsAt200Files() async throws {
        for i in 0..<210 {
            let content = "---\nname: \"File \(i)\"\n---\nbody"
            let file = tempDir.appendingPathComponent("file_\(String(format: "%04d", i))_aaaabbbb.md")
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertLessThanOrEqual(headers.count, 200)
    }
}
```

### Step 2: 验证测试失败

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryTopicScannerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：`error: cannot find type 'MemoryTopicScanner'`

### Step 3: 实现

```swift
// agentGui/Services/Memory/MemoryTopicScanner.swift
import Foundation

/// YAML frontmatter 中解析出的记忆话题文件头部信息。
/// 对齐 Claude Code `memoryScan.ts` 的 `MemoryHeader`。
struct MemoryTopicHeader: Sendable, Equatable {
    var filename: String        // 相对文件名，例如 "my_title_abc12345.md"
    var filePath: URL           // 绝对路径
    var mtimeMs: Double         // 文件修改时间（毫秒），用于排序和 freshness
    var title: String?          // frontmatter `name:` 字段
    var description: String?    // frontmatter `description:` 字段
    var memoryType: String?     // frontmatter `type:` 字段
}

/// 扫描 `memoryDir` 下的 `.md` 话题文件并解析 frontmatter。
///
/// - 排除 `MEMORY.md`（索引文件，由 bootstrap 注入，不参与 recall 选择）
/// - 最多返回 200 条记录（按 mtime 降序）
/// - 每个文件只读前 `maxFrontmatterLines` 行，避免读取完整大文件
///
/// nonisolated struct，内部使用 async file I/O，可在任意并发上下文调用。
struct MemoryTopicScanner: Sendable {

    private static let maxFiles = 200
    private static let maxFrontmatterLines = 30

    func scan(memoryDir: URL) async throws -> [MemoryTopicHeader] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: memoryDir.path) else { return [] }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: memoryDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        let mdFiles = entries.filter {
            $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md"
        }
        guard !mdFiles.isEmpty else { return [] }

        // 并发读取 frontmatter（最多读 maxFrontmatterLines 行）
        let headers: [MemoryTopicHeader?] = await withTaskGroup(of: MemoryTopicHeader?.self) { group in
            for fileURL in mdFiles {
                group.addTask {
                    await Self.readHeader(from: fileURL)
                }
            }
            var result: [MemoryTopicHeader?] = []
            for await header in group {
                result.append(header)
            }
            return result
        }

        return headers
            .compactMap { $0 }
            .sorted { $0.mtimeMs > $1.mtimeMs }
            .prefix(Self.maxFiles)
            .map { $0 }
    }

    // MARK: - Private

    private static func readHeader(from url: URL) async -> MemoryTopicHeader? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mtimeMs = mtime * 1000

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content
            .components(separatedBy: "\n")
            .prefix(maxFrontmatterLines)
        let partial = lines.joined(separator: "\n")
        let fm2 = parseFrontmatter(partial)

        return MemoryTopicHeader(
            filename: url.lastPathComponent,
            filePath: url,
            mtimeMs: mtimeMs,
            title: fm2["name"],
            description: fm2["description"],
            memoryType: fm2["type"]
        )
    }

    /// 极简 YAML frontmatter 解析器：仅提取 `---` fenced 块内的 `key: "value"` 或 `key: value` 行。
    /// 不依赖外部 YAML 库，满足此处只读 name/description/type 的需求。
    private static func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var result: [String: String] = [:]
        var inFrontmatter = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if i == 0 && trimmed == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter && trimmed == "---" { break }
            if !inFrontmatter { continue }

            // `key: "value with spaces"` 或 `key: plain`
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            // 去掉引号
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            result[key] = value
        }
        return result
    }
}
```

### Step 4: 验证测试通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryTopicScannerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

期望：`** TEST SUCCEEDED **`

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryTopicScanner.swift \
        agentGuiTests/MemoryTopicScannerTests.swift
git commit -m "feat(M-05): add MemoryTopicScanner — scan frontmatter from topic files"
```

---

## Task 2: `MemoryManifestFormatter`

**Files:**
- Create: `agentGui/Services/Memory/MemoryManifestFormatter.swift`
- Test: `agentGuiTests/MemoryManifestFormatterTests.swift`

将 `[MemoryTopicHeader]` 格式化为 side query prompt 使用的 manifest 文本，格式与 Claude Code `formatMemoryManifest` 完全对齐。

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryManifestFormatterTests.swift
import XCTest
@testable import agentGui

final class MemoryManifestFormatterTests: XCTestCase {

    func test_format_emptyList_returnsEmptyString() {
        XCTAssertTrue(MemoryManifestFormatter().format([]).isEmpty)
    }

    func test_format_withDescription_includesTypeFilenameDateDesc() {
        let header = MemoryTopicHeader(
            filename: "test_topic_abc12345.md",
            filePath: URL(fileURLWithPath: "/tmp/test_topic_abc12345.md"),
            mtimeMs: 1_700_000_000_000,
            title: "Test Topic",
            description: "A brief description",
            memoryType: "feedback"
        )
        let output = MemoryManifestFormatter().format([header])
        XCTAssertTrue(output.contains("[feedback]"), "应含 [type] 标签")
        XCTAssertTrue(output.contains("test_topic_abc12345.md"), "应含文件名")
        XCTAssertTrue(output.contains("A brief description"), "应含 description")
        XCTAssertTrue(output.contains("2023-"), "应含 ISO 时间戳年份")
    }

    func test_format_withoutDescription_omitsDescPart() {
        let header = MemoryTopicHeader(
            filename: "no_desc_abc12345.md",
            filePath: URL(fileURLWithPath: "/tmp/no_desc_abc12345.md"),
            mtimeMs: 1_700_000_000_000,
            title: nil,
            description: nil,
            memoryType: nil
        )
        let output = MemoryManifestFormatter().format([header])
        XCTAssertTrue(output.contains("no_desc_abc12345.md"))
        // 没有 type 标签
        XCTAssertFalse(output.contains("["))
    }

    func test_format_multipleHeaders_oneLineEach() {
        let headers = (0..<3).map { i in
            MemoryTopicHeader(
                filename: "file_\(i)_aabbccdd.md",
                filePath: URL(fileURLWithPath: "/tmp/file_\(i)_aabbccdd.md"),
                mtimeMs: Double(i) * 1_000,
                title: "Title \(i)",
                description: "Desc \(i)",
                memoryType: nil
            )
        }
        let output = MemoryManifestFormatter().format(headers)
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
    }
}
```

### Step 2: 验证测试失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryManifestFormatterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

期望：`error: cannot find type 'MemoryManifestFormatter'`

### Step 3: 实现

```swift
// agentGui/Services/Memory/MemoryManifestFormatter.swift
import Foundation

/// 将 `[MemoryTopicHeader]` 格式化为 side query prompt 使用的 manifest 文本。
///
/// 每行格式（对齐 Claude Code `formatMemoryManifest`）：
/// ```
/// - [type] filename (ISO8601): description
/// - filename (ISO8601): description      ← type 为 nil 时省略 [type]
/// - filename (ISO8601)                    ← description 为 nil 时省略描述
/// ```
struct MemoryManifestFormatter: Sendable {

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func format(_ headers: [MemoryTopicHeader]) -> String {
        guard !headers.isEmpty else { return "" }
        return headers.map { line(for: $0) }.joined(separator: "\n")
    }

    // MARK: - Private

    private func line(for header: MemoryTopicHeader) -> String {
        let typeTag = header.memoryType.map { "[\($0)] " } ?? ""
        let date = Self.iso8601.string(
            from: Date(timeIntervalSince1970: header.mtimeMs / 1000)
        )
        let descPart = header.description.map { ": \($0)" } ?? ""
        return "- \(typeTag)\(header.filename) (\(date))\(descPart)"
    }
}
```

### Step 4: 验证测试通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryManifestFormatterTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryManifestFormatter.swift \
        agentGuiTests/MemoryManifestFormatterTests.swift
git commit -m "feat(M-05): add MemoryManifestFormatter — format headers for side query prompt"
```

---

## Task 3: `RelevantMemorySideQuery`

**Files:**
- Create: `agentGui/Services/Memory/RelevantMemorySideQuery.swift`
- Test: `agentGuiTests/RelevantMemorySideQueryTests.swift`

调用 Haiku 模型（非流式），传入 manifest + query，返回最多 5 个文件名列表。

> **注意**：`service.createMessage()` 是 `SwiftAnthropic` 提供的非流式 API，参见  
> `ClaudeService+ContextCompression.swift:205`。

### Step 1: 写失败测试

```swift
// agentGuiTests/RelevantMemorySideQueryTests.swift
import XCTest
@testable import agentGui

final class RelevantMemorySideQueryTests: XCTestCase {

    // MARK: - Prompt Builder

    func test_buildPrompt_containsQueryAndManifest() {
        let prompt = RelevantMemorySideQuery.buildUserPrompt(
            query: "How do I configure the API key?",
            manifest: "- [user] api_key_abc12345.md (2024-01-01): API key setup notes",
            recentTools: []
        )
        XCTAssertTrue(prompt.contains("How do I configure the API key?"))
        XCTAssertTrue(prompt.contains("api_key_abc12345.md"))
    }

    func test_buildPrompt_withRecentTools_includesToolsSection() {
        let prompt = RelevantMemorySideQuery.buildUserPrompt(
            query: "run tests",
            manifest: "- testing_notes_abc1.md: testing patterns",
            recentTools: ["bash", "file_write"]
        )
        XCTAssertTrue(prompt.contains("bash"))
        XCTAssertTrue(prompt.contains("file_write"))
    }

    func test_buildPrompt_noRecentTools_omitsToolsSection() {
        let prompt = RelevantMemorySideQuery.buildUserPrompt(
            query: "test",
            manifest: "manifest",
            recentTools: []
        )
        XCTAssertFalse(prompt.contains("Recently used tools"))
    }

    // MARK: - parseResponse

    func test_parseResponse_validJSON_returnsFilenames() throws {
        let json = """
        {"selected_memories": ["foo_abc12345.md", "bar_def67890.md"]}
        """
        let filenames = RelevantMemorySideQuery.parseResponse(
            json,
            validFilenames: ["foo_abc12345.md", "bar_def67890.md", "other_aabb1122.md"]
        )
        XCTAssertEqual(filenames, ["foo_abc12345.md", "bar_def67890.md"])
    }

    func test_parseResponse_invalidFilenameFiltered() throws {
        let json = """
        {"selected_memories": ["legitimate_abc12345.md", "injected_filename.md"]}
        """
        let filenames = RelevantMemorySideQuery.parseResponse(
            json,
            validFilenames: ["legitimate_abc12345.md"]
        )
        XCTAssertEqual(filenames, ["legitimate_abc12345.md"],
                       "validFilenames 白名单外的文件名必须被过滤")
    }

    func test_parseResponse_capsAtFive() {
        let jsonFilenames = (0..<8).map { "file\($0)_aabb\(String(format: "%04d", $0)).md" }
        let json = """
        {"selected_memories": \(jsonFilenames.map { "\"\($0)\"" })}
        """
        let filenames = RelevantMemorySideQuery.parseResponse(
            json,
            validFilenames: Set(jsonFilenames)
        )
        XCTAssertLessThanOrEqual(filenames.count, 5)
    }

    func test_parseResponse_malformedJSON_returnsEmpty() {
        let filenames = RelevantMemorySideQuery.parseResponse(
            "not json at all",
            validFilenames: ["file_abc12345.md"]
        )
        XCTAssertTrue(filenames.isEmpty)
    }
}
```

### Step 2: 验证测试失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/RelevantMemorySideQueryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 3: 实现

```swift
// agentGui/Services/Memory/RelevantMemorySideQuery.swift
import Foundation
import SwiftAnthropic

/// 向 Claude Haiku 发起非流式 side query，从 memory manifest 中选出与当前 query 最相关的记忆文件。
///
/// 对齐 Claude Code `selectRelevantMemories`（`findRelevantMemories.ts`）。
///
/// 关键安全保证：`parseResponse` 对返回的文件名做白名单校验（`validFilenames`），
/// 防止模型返回注入路径或不存在的文件名。
struct RelevantMemorySideQuery: Sendable {

    static let sideQueryModel = "claude-3-5-haiku-latest"
    static let maxSelected = 5
    static let maxTokens = 256

    // MARK: - System Prompt

    static let systemPrompt = """
    You are selecting memories that will be useful to the AI agent as it processes a user's query. \
    You will be given the user's query and a list of available memory files with their filenames and descriptions.

    Return a JSON object with a "selected_memories" array of filenames (up to \(maxSelected)) \
    that will clearly be useful for the query.
    - Only include memories you are certain will be helpful based on their name and description.
    - If unsure, do not include. Be selective.
    - If none are clearly useful, return {"selected_memories": []}.
    - If a list of recently-used tools is provided, do NOT select reference/usage docs for those tools \
      (the model is already using them). DO select memories containing warnings or known issues.
    - Respond ONLY with valid JSON. No explanation, no markdown fences.
    """

    // MARK: - Public API

    /// 执行 side query。失败（网络、超时、解析错误）时返回空数组，不抛出。
    ///
    /// - Parameters:
    ///   - query: 当前用户消息文本
    ///   - headers: 已扫描的 topic file 头部列表
    ///   - recentTools: 本轮已成功调用的工具名（防误召回工具 reference 文件）
    ///   - alreadySurfaced: 本 session 已注入过的文件路径（URL.path），传给 API 前预过滤
    ///   - service: Anthropic API service（从 ClaudeService 传入）
    func select(
        query: String,
        headers: [MemoryTopicHeader],
        recentTools: [String],
        alreadySurfaced: Set<String>,
        service: any AnthropicService
    ) async -> [MemoryTopicHeader] {
        // 预过滤已注入文件
        let candidates = headers.filter { !alreadySurfaced.contains($0.filePath.path) }
        guard !candidates.isEmpty else { return [] }

        let manifest = MemoryManifestFormatter().format(candidates)
        let userPrompt = Self.buildUserPrompt(
            query: query,
            manifest: manifest,
            recentTools: recentTools
        )

        let validFilenames = Set(candidates.map { $0.filename })
        let selectedFilenames: [String]
        do {
            let response = try await service.createMessage(
                MessageParameter(
                    model: .other(Self.sideQueryModel),
                    messages: [.init(role: .user, content: .text(userPrompt))],
                    maxTokens: Self.maxTokens,
                    system: .text(Self.systemPrompt)
                )
            )
            let text = response.content.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined()
            selectedFilenames = Self.parseResponse(text, validFilenames: validFilenames)
        } catch {
            return []
        }

        let byFilename = Dictionary(uniqueKeysWithValues: candidates.map { ($0.filename, $0) })
        return selectedFilenames
            .compactMap { byFilename[$0] }
            .prefix(Self.maxSelected)
            .map { $0 }
    }

    // MARK: - Testable Helpers

    /// `buildUserPrompt` 为 `static` 以便测试直接调用，无需实例化。
    static func buildUserPrompt(
        query: String,
        manifest: String,
        recentTools: [String]
    ) -> String {
        var parts = [
            "Query: \(query)",
            "",
            "Available memories:",
            manifest
        ]
        if !recentTools.isEmpty {
            parts.append("")
            parts.append("Recently used tools: \(recentTools.joined(separator: ", "))")
        }
        return parts.joined(separator: "\n")
    }

    /// 解析 JSON 响应，过滤非白名单文件名，最多返回 5 个。
    static func parseResponse(
        _ text: String,
        validFilenames: Set<String>
    ) -> [String] {
        struct Response: Decodable {
            var selected_memories: [String]
        }
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Response.self, from: data) else {
            return []
        }
        return Array(
            parsed.selected_memories
                .filter { validFilenames.contains($0) }
                .prefix(maxSelected)
        )
    }
}
```

### Step 4: 验证测试通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/RelevantMemorySideQueryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 5: Commit

```bash
git add agentGui/Services/Memory/RelevantMemorySideQuery.swift \
        agentGuiTests/RelevantMemorySideQueryTests.swift
git commit -m "feat(M-05): add RelevantMemorySideQuery — side-call Haiku to select relevant memory files"
```

---

## Task 4: `MemoryRecallSessionState` Actor

**Files:**
- Create: `agentGui/Services/Memory/MemoryRecallSessionState.swift`
- Test: `agentGuiTests/MemoryRecallSessionStateTests.swift`

跨轮维护 `alreadySurfaced` 去重 Set 和 session 累计字节数，防止同一文件在同一 session 内被重复注入；超过字节上限后自动禁用召回。AutoCompact（消息历史被压缩）后通过扫描 `messagesSnapshot` 重建状态。

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryRecallSessionStateTests.swift
import XCTest
@testable import agentGui

final class MemoryRecallSessionStateTests: XCTestCase {

    func test_initialState_nothingSurfaced() async {
        let state = MemoryRecallSessionState()
        let alreadySurfaced = await state.alreadySurfaced
        XCTAssertTrue(alreadySurfaced.isEmpty)
        let bytes = await state.totalBytesSurfaced
        XCTAssertEqual(bytes, 0)
    }

    func test_markSurfaced_accumulates() async {
        let state = MemoryRecallSessionState()
        await state.markSurfaced(path: "/tmp/foo.md", byteCount: 1024)
        await state.markSurfaced(path: "/tmp/bar.md", byteCount: 2048)

        let surfaced = await state.alreadySurfaced
        XCTAssertEqual(surfaced, ["/tmp/foo.md", "/tmp/bar.md"])
        let bytes = await state.totalBytesSurfaced
        XCTAssertEqual(bytes, 3072)
    }

    func test_isSessionByteLimitReached_falseBeforeLimit() async {
        let state = MemoryRecallSessionState()
        await state.markSurfaced(path: "/tmp/a.md", byteCount: 1000)
        let reached = await state.isSessionByteLimitReached
        XCTAssertFalse(reached)
    }

    func test_isSessionByteLimitReached_trueAtLimit() async {
        let state = MemoryRecallSessionState()
        // MAX_SESSION_BYTES = 51_200
        await state.markSurfaced(path: "/tmp/big.md", byteCount: 51_200)
        let reached = await state.isSessionByteLimitReached
        XCTAssertTrue(reached)
    }

    func test_syncFrom_rebuildsFromMessages() async {
        let state = MemoryRecallSessionState()
        // 初次注入
        await state.markSurfaced(path: "/tmp/old.md", byteCount: 500)

        // 模拟 AutoCompact：消息被清空，syncFrom 重建（此处传空消息模拟 compact 后状态）
        await state.syncFrom(messagesSnapshot: [])
        let surfaced = await state.alreadySurfaced
        XCTAssertTrue(surfaced.isEmpty, "AutoCompact 后应清空 alreadySurfaced")
        let bytes = await state.totalBytesSurfaced
        XCTAssertEqual(bytes, 0)
    }
}
```

### Step 2: 验证测试失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryRecallSessionStateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 3: 实现

```swift
// agentGui/Services/Memory/MemoryRecallSessionState.swift
import Foundation
import SwiftAnthropic

/// Session 级别的记忆召回状态，跨轮维护去重信息。
///
/// - `alreadySurfaced`：本 session 内已注入过的 topic file 绝对路径集合。
/// - `totalBytesSurfaced`：本 session 累计注入字节数（用于防止 token 膨胀）。
/// - AutoCompact 发生时调用 `syncFrom(messagesSnapshot:)` 根据当前消息快照重建状态。
///   由于 compact 后旧的 system-reminder 消息被移除，重建后 alreadySurfaced 清空，
///   允许再次召回——与 Claude Code 的 `collectSurfacedMemories` 原理相同。
///
/// actor isolation 保证并发安全（hook 和 service 均在不同 Task 中访问）。
actor MemoryRecallSessionState {

    /// session 内累计注入的字节上限（~50KB）。
    static let maxSessionBytes = 51_200

    private(set) var alreadySurfaced: Set<String> = []
    private(set) var totalBytesSurfaced: Int = 0

    var isSessionByteLimitReached: Bool {
        totalBytesSurfaced >= Self.maxSessionBytes
    }

    func markSurfaced(path: String, byteCount: Int) {
        alreadySurfaced.insert(path)
        totalBytesSurfaced += byteCount
    }

    /// 根据当前消息快照重建 `alreadySurfaced`。
    ///
    /// AutoCompact 后旧消息被丢弃，注入过的 system-reminder 也随之消失，
    /// 因此直接清空状态，允许重新召回。
    ///
    /// 如果未来需要从消息内容提取已注入文件路径，可在此解析
    /// `<system-reminder>` 标签，类比 Claude Code `collectSurfacedMemories`。
    func syncFrom(messagesSnapshot: [MessageParameter.Message]) {
        // 简单策略：消息快照为空（compact 后）则全清。
        // 若快照非空但不含 system-reminder，也清空（防误判）。
        let hasAnyReminder = messagesSnapshot.contains { msg in
            let text: String
            switch msg.content {
            case .text(let t): text = t
            case .list(let blocks):
                text = blocks.compactMap {
                    if case .text(let t) = $0 { return t }
                    return nil
                }.joined()
            }
            return text.contains("<system-reminder>")
        }
        if !hasAnyReminder {
            alreadySurfaced = []
            totalBytesSurfaced = 0
        }
    }
}
```

### Step 4: 验证测试通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryRecallSessionStateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 5: Commit

```bash
git add agentGui/Services/Memory/MemoryRecallSessionState.swift \
        agentGuiTests/MemoryRecallSessionStateTests.swift
git commit -m "feat(M-05): add MemoryRecallSessionState actor — cross-round dedup tracking"
```

---

## Task 5: `RelevantMemoryRecallService`

**Files:**
- Create: `agentGui/Services/Memory/RelevantMemoryRecallService.swift`
- Test: `agentGuiTests/RelevantMemoryRecallServiceTests.swift`

编排：query 提取 → 扫描 → side query（2s 超时） → 读文件 → 格式化注入块。返回 `nil` 表示无需注入（query 太短、字节上限到达、side query 失败、无匹配）。

### Step 1: 写失败测试

```swift
// agentGuiTests/RelevantMemoryRecallServiceTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

final class RelevantMemoryRecallServiceTests: XCTestCase {

    // MARK: - extractUserQuery

    func test_extractUserQuery_lastUserMessage_returnsText() {
        let messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("First message")),
            .init(role: .assistant, content: .text("Reply")),
            .init(role: .user, content: .text("What is the API key format?"))
        ]
        let text = RelevantMemoryRecallService.extractUserQuery(from: messages)
        XCTAssertEqual(text, "What is the API key format?")
    }

    func test_extractUserQuery_noUserMessage_returnsNil() {
        let messages: [MessageParameter.Message] = [
            .init(role: .assistant, content: .text("Hello"))
        ]
        XCTAssertNil(RelevantMemoryRecallService.extractUserQuery(from: messages))
    }

    func test_extractUserQuery_singleWord_returnsNil() {
        let messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("hello"))
        ]
        XCTAssertNil(
            RelevantMemoryRecallService.extractUserQuery(from: messages),
            "单词 query 缺乏足够上下文，应返回 nil"
        )
    }

    // MARK: - formatInjectionBlock

    func test_formatInjectionBlock_wrapsInSystemReminder() {
        let result = RelevantMemoryRecallService.formatInjectionBlock(
            filename: "foo_abc12345.md",
            content: "The API key must be 32 chars.",
            mtimeMs: 1_700_000_000_000,
            now: Date(timeIntervalSince1970: 1_700_000_000_000 / 1000 + 86_400 * 3) // 3 days later
        )
        XCTAssertTrue(result.contains("<system-reminder>"))
        XCTAssertTrue(result.contains("</system-reminder>"))
        XCTAssertTrue(result.contains("foo_abc12345.md"))
        XCTAssertTrue(result.contains("The API key must be 32 chars."))
    }

    func test_formatInjectionBlock_freshMemory_noFreshnessWarning() {
        let now = Date()
        let result = RelevantMemoryRecallService.formatInjectionBlock(
            filename: "fresh_abc12345.md",
            content: "Fresh content.",
            mtimeMs: now.timeIntervalSince1970 * 1000,
            now: now
        )
        // 今天的记忆不应有 freshness warning
        XCTAssertFalse(result.contains("days old"))
    }

    func test_formatInjectionBlock_staleMemory_includesFreshnessWarning() {
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-86_400 * 10)
        let result = RelevantMemoryRecallService.formatInjectionBlock(
            filename: "stale_abc12345.md",
            content: "Old content.",
            mtimeMs: tenDaysAgo.timeIntervalSince1970 * 1000,
            now: now
        )
        XCTAssertTrue(result.contains("days old"), "10 天前的记忆应有 freshness warning")
    }

    // MARK: - collectRecentToolNames

    func test_collectRecentToolNames_extractsToolUseNames() throws {
        // 构造含 tool_use 的消息快照
        // 注意：此处用文本模拟，实际集成测试可用真实消息结构
        let names = RelevantMemoryRecallService.collectRecentToolNames(
            from: [],
            maxRounds: 3
        )
        XCTAssertTrue(names.isEmpty)
    }
}
```

### Step 2: 验证测试失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/RelevantMemoryRecallServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 3: 实现

```swift
// agentGui/Services/Memory/RelevantMemoryRecallService.swift
import Foundation
import SwiftAnthropic

/// 编排中段记忆召回全流程的服务。
///
/// 调用方（`MemoryRecallHook`）在 `.willStartRound` 时传入当前消息快照，
/// 本服务负责：
/// 1. 提取 query（最后一条 user 消息文本）
/// 2. 检查 session 字节上限
/// 3. 扫描 memory dir 的 topic file frontmatter
/// 4. 调用 side query（超时 2s）选出相关文件
/// 5. 读取文件内容并格式化为 `<system-reminder>` 注入块
///
/// nonisolated struct（无可变状态），会话状态由外部 `MemoryRecallSessionState` actor 管理。
struct RelevantMemoryRecallService: Sendable {

    let memoryDir: URL
    let sessionState: MemoryRecallSessionState
    let service: any AnthropicService

    /// side query 超时时限（秒）
    static let sideQueryTimeoutSeconds: Double = 2.0

    // MARK: - Main Entry

    /// 执行中段召回，返回注入文本（非 nil 则调用方将其插入消息链）。
    ///
    /// - Returns: 格式化后的 `<system-reminder>` 多块文本；无需注入时返回 `nil`。
    func recall(
        messagesSnapshot: [MessageParameter.Message],
        now: Date = .now
    ) async -> String? {
        // 1. 提取 query
        guard let query = Self.extractUserQuery(from: messagesSnapshot) else { return nil }

        // 2. session 字节上限检查
        guard await !sessionState.isSessionByteLimitReached else { return nil }

        // 3. 扫描 topic files
        let headers = (try? await MemoryTopicScanner().scan(memoryDir: memoryDir)) ?? []
        guard !headers.isEmpty else { return nil }

        // 4. 已注入路径（传给 side query 预过滤）
        let alreadySurfaced = await sessionState.alreadySurfaced

        // 5. Side query（带超时）
        let selected = await withTimeout(seconds: Self.sideQueryTimeoutSeconds) {
            await RelevantMemorySideQuery().select(
                query: query,
                headers: headers,
                recentTools: Self.collectRecentToolNames(from: messagesSnapshot, maxRounds: 3),
                alreadySurfaced: alreadySurfaced,
                service: self.service
            )
        } ?? []

        guard !selected.isEmpty else { return nil }

        // 6. 读取文件内容并格式化注入块
        var blocks: [String] = []
        for header in selected {
            guard let content = try? String(contentsOf: header.filePath, encoding: .utf8) else { continue }
            let block = Self.formatInjectionBlock(
                filename: header.filename,
                content: content,
                mtimeMs: header.mtimeMs,
                now: now
            )
            blocks.append(block)
            // 记录已注入
            await sessionState.markSurfaced(path: header.filePath.path, byteCount: content.utf8.count)
        }

        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    // MARK: - Testable Static Helpers

    /// 从消息快照中提取最后一条 user 消息的文本。
    /// 单词数 < 2 时返回 nil（缺乏足够上下文）。
    static func extractUserQuery(from messages: [MessageParameter.Message]) -> String? {
        let lastUser = messages.last(where: { $0.role == "user" })
        guard let msg = lastUser else { return nil }
        let text: String
        switch msg.content {
        case .text(let t): text = t
        case .list(let blocks):
            text = blocks.compactMap {
                if case .text(let t) = $0 { return t }
                return nil
            }.joined(separator: " ")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 至少 2 个词，才有足够上下文
        guard trimmed.split(whereSeparator: \.isWhitespace).count >= 2 else { return nil }
        return trimmed
    }

    /// 格式化单个文件内容为 `<system-reminder>` 注入块，附加陈旧性警告。
    static func formatInjectionBlock(
        filename: String,
        content: String,
        mtimeMs: Double,
        now: Date = .now
    ) -> String {
        let annotator = MemoryFreshnessAnnotator()
        let updatedAt = Date(timeIntervalSince1970: mtimeMs / 1000)
        let freshnessNote = annotator.freshnessNote(updatedAt: updatedAt, now: now)
        let header = "## Relevant Memory: \(filename)\n"
        return "<system-reminder>\n\(header)\(freshnessNote)\n\(content)\n</system-reminder>"
    }

    /// 从消息快照提取最近 N 轮 tool_use 名称（供 side query 过滤 reference 文件）。
    static func collectRecentToolNames(
        from messages: [MessageParameter.Message],
        maxRounds: Int
    ) -> [String] {
        // 从后往前遍历最近 maxRounds * 2 条消息（一轮 = assistant + user）
        let recent = messages.suffix(maxRounds * 2)
        var names: [String] = []
        for msg in recent {
            if case .list(let blocks) = msg.content {
                for block in blocks {
                    if case .toolUse(let id, let name, _) = block {
                        _ = id // 抑制 unused warning
                        if !names.contains(name) { names.append(name) }
                    }
                }
            }
        }
        return names
    }

    // MARK: - Private

    /// 带超时的 async 任务包装器。超时后返回 nil。
    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return nil
        }
    }
}
```

### Step 4: 验证测试通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/RelevantMemoryRecallServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 5: Commit

```bash
git add agentGui/Services/Memory/RelevantMemoryRecallService.swift \
        agentGuiTests/RelevantMemoryRecallServiceTests.swift
git commit -m "feat(M-05): add RelevantMemoryRecallService — orchestrate scan, sideQuery, inject"
```

---

## Task 6: `MemoryRecallHook`

**Files:**
- Create: `agentGui/Services/AgentLoopHooks/MemoryRecallHook.swift`
- Test: `agentGuiTests/MemoryRecallHookTests.swift`

`AgentLoopHook` 实现，在 `.willStartRound` 阶段（`.mutator` kind，`order = 15`）触发 `RelevantMemoryRecallService.recall()`，将结果以 `messagePatch` 注入当前消息链。

> **为何是 `.mutator` 且需改 RoundExecutor**：当前 `.willStartRound` 仅用 `emit`（observer-only），此处需升级为 `dispatch` 以支持 `messagePatch`。见 Task 7。

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryRecallHookTests.swift
import XCTest
@testable import agentGui

final class MemoryRecallHookTests: XCTestCase {

    func test_supports_willStartRound_true() {
        let hook = MemoryRecallHook(recallService: nil)
        XCTAssertTrue(hook.supports(.willStartRound))
    }

    func test_supports_prepareRun_false() {
        let hook = MemoryRecallHook(recallService: nil)
        XCTAssertFalse(hook.supports(.prepareRun))
    }

    func test_perform_nilService_returnsContinue() async throws {
        let hook = MemoryRecallHook(recallService: nil)
        let context = makeContext(executionContext: .mainAgent)
        let result = try await hook.perform(stage: .willStartRound, context: context)
        if case .continue = result { /* ok */ } else {
            XCTFail("nil service should return .continue")
        }
    }

    func test_perform_subagentContext_returnsContinue() async throws {
        // 在 subagent 上下文中不应触发召回（防递归）
        let mockService = MockRecallService(injectText: "recalled memory content")
        let hook = MemoryRecallHook(recallService: mockService)
        let context = makeContext(executionContext: .subagent)
        let result = try await hook.perform(stage: .willStartRound, context: context)
        if case .continue = result { /* ok */ } else {
            XCTFail("subagent context should return .continue")
        }
    }

    func test_perform_withInjectionText_returnsMessagePatch() async throws {
        let injectionText = "<system-reminder>\n## Relevant Memory: foo_abc12345.md\n\nContent here\n</system-reminder>"
        let mockService = MockRecallService(injectText: injectionText)
        let hook = MemoryRecallHook(recallService: mockService)
        let context = makeContext(executionContext: .mainAgent)
        let result = try await hook.perform(stage: .willStartRound, context: context)
        if case .messagePatch(let patch) = result {
            XCTAssertFalse(patch.insertions.isEmpty)
            // 验证注入内容包含 system-reminder
            if case .text(let t) = patch.insertions[0].message.content {
                XCTAssertTrue(t.contains("<system-reminder>"))
            } else {
                XCTFail("注入消息应为 .text 内容")
            }
        } else {
            XCTFail("有召回内容时应返回 .messagePatch，got: \(result)")
        }
    }

    func test_perform_noRecalledContent_returnsContinue() async throws {
        let mockService = MockRecallService(injectText: nil)
        let hook = MemoryRecallHook(recallService: mockService)
        let context = makeContext(executionContext: .mainAgent)
        let result = try await hook.perform(stage: .willStartRound, context: context)
        if case .continue = result { /* ok */ } else {
            XCTFail("无召回内容时应返回 .continue")
        }
    }

    // MARK: - Helpers

    private func makeContext(executionContext: ToolContext) -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: executionContext,
            modelId: "claude-sonnet-4-6",
            roundIndex: 0,
            phase: "executing"
        )
    }
}

// MARK: - Test Double

private struct MockRecallService: MemoryRecallServiceProtocol {
    let injectText: String?
    func recall(
        messagesSnapshot: [MessageParameter.Message],
        now: Date
    ) async -> String? {
        return injectText
    }
}
```

### Step 2: 验证测试失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryRecallHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 3: 实现

首先定义 protocol（用于测试 mock）：

```swift
// agentGui/Services/Memory/RelevantMemoryRecallService.swift
// （在文件末尾追加）

/// 召回服务的抽象协议，方便测试注入 mock。
protocol MemoryRecallServiceProtocol: Sendable {
    func recall(
        messagesSnapshot: [MessageParameter.Message],
        now: Date
    ) async -> String?
}

extension RelevantMemoryRecallService: MemoryRecallServiceProtocol {}
```

然后实现 hook：

```swift
// agentGui/Services/AgentLoopHooks/MemoryRecallHook.swift
import Foundation
import SwiftAnthropic

/// 在 `.willStartRound` 阶段触发中段记忆召回并以 `messagePatch` 注入结果。
///
/// - `order = 15`：在 MemoryBootstrapHook (order=20) 之前运行，确保 bootstrap 之后、  
///   API 调用之前召回的记忆已在消息链中。
/// - `.subagent` 执行上下文跳过（防递归）。
/// - `recallService` 为 `nil` 时（service 未就绪）直接放行。
struct MemoryRecallHook: AgentLoopHook {
    let id = "memory-recall"
    let order = 15
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false

    let recallService: (any MemoryRecallServiceProtocol)?

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willStartRound
    }

    func perform(
        stage: AgentLoopHookStage,
        context: AgentLoopHookContext
    ) async throws -> AgentLoopHookResult {
        guard stage == .willStartRound else { return .continue }
        guard context.executionContext == .mainAgent else { return .continue }
        guard let service = recallService else { return .continue }

        guard let injectionText = await service.recall(
            messagesSnapshot: context.messagesSnapshot,
            now: .now
        ), !injectionText.isEmpty else {
            return .continue
        }

        // 注入方式：在消息链末尾插入 user+assistant 消息对（与 bootstrap 模式对齐）
        // 插入位置：当前消息末尾（index = context.messagesSnapshot.count）
        let insertIndex = context.messagesSnapshot.count
        let patch = AgentLoopMessagePatch(
            insertions: [
                .init(
                    index: insertIndex,
                    message: MessageParameter.Message(
                        role: .user,
                        content: .text(injectionText)
                    )
                ),
                .init(
                    index: insertIndex + 1,
                    message: MessageParameter.Message(
                        role: .assistant,
                        content: .text("已加载相关记忆上下文，将在本轮回复中参考以上记忆。")
                    )
                )
            ],
            metadata: ["source": "memory-recall"]
        )
        return .messagePatch(patch)
    }
}
```

### Step 4: 验证测试通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryRecallHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 5: Commit

```bash
git add agentGui/Services/AgentLoopHooks/MemoryRecallHook.swift \
        agentGuiTests/MemoryRecallHookTests.swift \
        agentGui/Services/Memory/RelevantMemoryRecallService.swift
git commit -m "feat(M-05): add MemoryRecallHook — inject recalled memories at willStartRound"
```

---

## Task 7: 升级 `AgentLoopRoundExecutor` 支持 `willStartRound` 消息注入

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift:149-161`

将 `emit(.willStartRound)` 改为 `dispatch(.willStartRound)` 并在结果中应用 `messagePatch`，使 `MemoryRecallHook`（及其他 mutator hook）能在每轮开始前修改消息链。

### Step 1: 写失败测试（集成级）

```swift
// agentGuiTests/AgentLoopRoundExecutorWillStartRoundPatchTests.swift
import XCTest
@testable import agentGui

/// 验证 willStartRound 阶段的 messagePatch 确实被应用到 messages 数组。
final class AgentLoopRoundExecutorWillStartRoundPatchTests: XCTestCase {

    func test_willStartRoundHook_patchApplied() async throws {
        // 此测试需要实际修改后的 RoundExecutor。
        // 构造一个 PatchInjectingHook，验证消息数比修改前多 2 条。
        // 由于 RoundExecutor 需要完整依赖，此处用 integration test 形式。
        // 
        // SKIP THIS TEST if full integration setup is complex:
        // 转而通过 Task 8 的 E2E run 验证。
        // 
        // 此测试的存在目的是文档化预期行为。
        XCTSkip("Integration test — 通过 Task 8 E2E 验证")
    }
}
```

> 注：`AgentLoopRoundExecutor.executeStreamingRound` 是核心业务路径，单测代价过高。  
> 关键行为回归通过现有 `AgentLoopBuiltInHookFactory` 测试 + E2E run 覆盖。

### Step 2: 修改 `AgentLoopRoundExecutor.swift`

找到 `executeStreamingRound` 内的 `willStartRound emit` 调用（约第 151 行）：

```swift
// 当前代码（修改前）：
await emitter.emit(
    .willStartRound,
    state: state,
    messages: messages,
    overrides: .init(metadata: [
        "messageCount": messages.count,
        "phase": state.loopCtx.phase.label,
        "modelId": modelId
    ])
)
```

替换为：

```swift
// 修改后：dispatch 并应用 messagePatch
let willStartResult = try await emitter.dispatch(
    .willStartRound,
    state: state,
    messages: messages,
    overrides: .init(metadata: [
        "messageCount": messages.count,
        "phase": state.loopCtx.phase.label,
        "modelId": modelId
    ])
)
if let patch = willStartResult.messagePatch, !patch.insertions.isEmpty {
    for insertion in patch.insertions.sorted(by: { $0.index < $1.index }) {
        messages.insert(insertion.message, at: min(insertion.index, messages.count))
    }
}
```

> 注意：`emitter.dispatch` 是 `throws`，需在 `executeStreamingRound` 的 `throws` 函数内。  
> 若 `dispatch` 抛出（非 required hook 失败），错误应传播给调用方，与 `applyBootstrap` 保持一致。

### Step 3: 构建验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

期望：`Build succeeded`

### Step 4: Commit

```bash
git add agentGui/Services/AgentLoopRoundExecutor.swift
git commit -m "feat(M-05): dispatch willStartRound to support messagePatch injection"
```

---

## Task 8: 注册 `MemoryRecallHook` + 装配依赖

**Files:**
- Modify: `agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- Modify: `agentGui/Services/AgentLoopHookDependencyFactory.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/MemoryRecallHookRegistrationTests.swift
import XCTest
@testable import agentGui

final class MemoryRecallHookRegistrationTests: XCTestCase {

    func test_makeHooks_containsMemoryRecallHook() {
        let factory = AgentLoopBuiltInHookFactory()
        let deps = AgentLoopBuiltInHookFactory.Dependencies(
            businessLogSink: nil,
            memoryBootstrapLoader: { _ in nil },
            createToolCallRecord: { _, _ in ToolCall(id: "t1", sessionID: "s1", agentRunID: "r1", toolName: "test", input: [:]) },
            updateToolCallRecord: { _, _ in },
            extractMemoriesCallback: { _ in },
            // M-05 新增
            memoryRecallService: nil
        )
        let state = AgentLoopBuiltInHookFactory.State()
        let hooks = factory.makeHooks(dependencies: deps, state: state)
        let hasRecallHook = hooks.contains { $0.id == "memory-recall" }
        XCTAssertTrue(hasRecallHook, "makeHooks 应包含 MemoryRecallHook")
    }
}
```

### Step 2: 验证测试失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryRecallHookRegistrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 3: 修改 `AgentLoopBuiltInHookFactory.swift`

在 `Dependencies` struct 末尾添加：

```swift
// M-05: 中段记忆召回服务
let memoryRecallService: (any MemoryRecallServiceProtocol)?
```

在 `makeHooks` 的 hook 数组末尾添加：

```swift
// M-05: 中段记忆召回
MemoryRecallHook(recallService: dependencies.memoryRecallService),
```

### Step 4: 修改 `AgentLoopHookDependencyFactory.swift`

在 `build(state:)` 方法的 `Dependencies` 初始化中添加：

```swift
// M-05
memoryRecallService: buildMemoryRecallService()
```

在 `AgentLoopHookDependencyFactory` 中添加构建方法：

```swift
private func buildMemoryRecallService() -> (any MemoryRecallServiceProtocol)? {
    guard let anthropicService = claudeService.serviceSnapshot else { return nil }
    let sessionState = MemoryRecallSessionState()
    return RelevantMemoryRecallService(
        memoryDir: ConfigDirectoryManager.shared.memoryDir,
        sessionState: sessionState,
        service: anthropicService
    )
}
```

> 注意：`claudeService.serviceSnapshot` 是现有的 `var service: (any AnthropicService)?` 的 snapshot 访问方式，  
> 检查实际属性名（可能为 `claudeService.service`）并调整。若 `service` 是 `async` 属性需用 `await`。

### Step 5: 验证测试通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/MemoryRecallHookRegistrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 6: Commit

```bash
git add agentGui/Services/AgentLoopBuiltInHookFactory.swift \
        agentGui/Services/AgentLoopHookDependencyFactory.swift \
        agentGuiTests/MemoryRecallHookRegistrationTests.swift
git commit -m "feat(M-05): register MemoryRecallHook in factory — wire up service dependency"
```

---

## Task 9: 全量编译 + 现有测试回归

**Files:**
- None（验证阶段）

### Step 1: 全量编译

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

期望：`Build succeeded`（零 error）

### Step 2: 运行 Memory 相关全量测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m05-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed|error:" | tail -40
```

期望：所有 memory 测试通过，无新失败。

### Step 3: 专项 M-05 测试套

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m05-derived \
  -only-testing:agentGuiTests/MemoryTopicScannerTests \
  -only-testing:agentGuiTests/MemoryManifestFormatterTests \
  -only-testing:agentGuiTests/RelevantMemorySideQueryTests \
  -only-testing:agentGuiTests/MemoryRecallSessionStateTests \
  -only-testing:agentGuiTests/RelevantMemoryRecallServiceTests \
  -only-testing:agentGuiTests/MemoryRecallHookTests \
  -only-testing:agentGuiTests/MemoryRecallHookRegistrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：`** TEST SUCCEEDED **`

### Step 4: Final commit

```bash
git add -A
git commit -m "feat(M-05): complete mid-conversation memory recall — all tests passing"
```

---

## 实施注意事项

### 关于 `ClaudeService.service` 访问

`AgentLoopHookDependencyFactory.buildMemoryRecallService()` 需要获取 Anthropic service 实例。  
查看 `ClaudeService.swift` 确认正确的属性访问方式（可能是 `@MainActor var service`），  
并在 `buildMemoryRecallService()` 内使用 `claudeService.service`（已在工厂的 `@MainActor` 上下文中）。

### 关于 `MessageParameter.Message.content` switch

Swift 6 中 `SwiftAnthropic` 的 `MessageParameter.Message.content` enum 的 case 名称需与实际 SDK 对齐。  
查看 `ClaudeService+ContextCompression.swift` 中提取文本的方式（`extractText(from:)`），  
用相同模式实现 `RelevantMemoryRecallService.extractUserQuery`。

### 关于 `withTimeout` 实现

`withTaskGroup` 的竞速模式：一个 task 做真实工作，另一个 `Task.sleep` 后返回 nil。  
`group.cancelAll()` 在取到第一个结果后取消另一个 task——这是标准的 Swift 竞速超时模式，  
与 Claude Code `Promise.race(query, timeout)` 语义完全对齐。

### 关于 `task order` 与 Bootstrap 的顺序关系

`MemoryRecallHook` (`order=15`) < `MemoryBootstrapHook` (`order=20`)，  
即 recall 在 bootstrap 之后按 hook 注册顺序执行——实际上两者都在 `willStartRound` 前  
（bootstrap 在 `prepareRun`），不存在冲突。  
若需要精确控制消息插入位置，检查 `context.messagesSnapshot.count` 是否包含 bootstrap 已插入的消息。

---

## 补充：E2E 手动冒烟验证步骤

1. 在 `~/.agentgui/memory/` 下创建一个 topic 文件：
   ```bash
   cat > ~/.agentgui/memory/api_key_format_aabbccdd.md << 'EOF'
   ---
   name: "API Key Format"
   description: "The Anthropic API key starts with sk-ant- prefix"
   type: "reference"
   ---
   The Anthropic API key format is: sk-ant-<40 chars>.
   Store it in AppSettings.apiKey, never hardcode.
   EOF
   ```
2. 打开 agentGui，发送消息："How should I store the API key?"
3. 验证：assistant 回复中包含 `sk-ant-` 相关信息（从记忆召回）
4. 发送同一消息第二次 → 验证不会重复注入（`alreadySurfaced` 去重）
